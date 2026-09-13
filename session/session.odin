package session

// Append-only session log, pi-style: one JSONL entry per finalized message,
// linked by id/parent_id so branches can exist later without a format change.
// v1 replays entries linearly; fork/branch reads land with the milestone that
// needs them. Writes go straight to the fd on every entry — a crash loses at
// most the in-flight generation, never committed history.

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

import "../agent"

Entry_Kind :: enum {
	Message,
	Compaction,
	// Branch_Summary — reserved; written by a later milestone.
}

// Flat shape: core json can't marshal pointer fields, so compaction data
// lives as tagged-omitempty fields rather than a nested *Compaction.
Entry :: struct {
	id:        string,
	parent_id: string,
	seq:       int,
	kind:      Entry_Kind,
	message:   agent.Agent_Message,

	// kind == .Compaction
	summary:        string `json:"summary,omitempty"`,
	tokens_before:  int `json:"tokens_before,omitempty"`,
	files_read:     []string `json:"files_read,omitempty"`,
	files_modified: []string `json:"files_modified,omitempty"`,
	tail:           []agent.Agent_Message `json:"tail,omitempty"`,
}

Session :: struct {
	path:      string,
	file:      ^os.File,
	next_seq:  int,
	tip_id:    string,
	allocator: mem.Allocator,
}

// Open (or create) the log at path and replay it into a message slice.
// Caller puts the returned messages into agent.Context to resume.
open :: proc(path: string, allocator: mem.Allocator) -> (^Session, []agent.Agent_Message, os.Error) {
	assert(len(path) > 0)
	s := new(Session, allocator)
	s.path = strings.clone(path, allocator)
	s.allocator = allocator

	messages := make([dynamic]agent.Agent_Message, 0, 64, allocator)
	if os.exists(path) {
		data, rerr := os.read_entire_file(path, allocator)
		if rerr != nil {
			return nil, nil, rerr
		}
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if len(strings.trim_space(line)) == 0 {
				continue
			}
			entry: Entry
			if uerr := json.unmarshal(transmute([]u8)line, &entry, .JSON, allocator); uerr != nil {
				return nil, nil, os.General_Error.Invalid_File // malformed entry — refuse to resume over corruption
			}
			#partial switch entry.kind {
			case .Message:
				append(&messages, entry.message)
			case .Compaction:
				// Self-contained: reset replay to summary + retained tail.
				// Later entries append on top; earlier ones are dropped.
				clear(&messages)
				append(&messages, agent.Agent_Message {
					role = .Compaction_Summary,
					text = entry.summary,
				})
				for m in entry.tail {
					append(&messages, m)
				}
			}
			s.tip_id = entry.id
			s.next_seq = entry.seq + 1
		}
	}

	file, oerr := os.open(path, {.Write, .Create, .Append}, os.perm(0o600))
	if oerr != nil {
		return nil, nil, oerr
	}
	s.file = file
	return s, messages[:], nil
}

close :: proc(s: ^Session) {
	if s.file != nil {
		os.close(s.file)
	}
}

// Commit one message. Called from the emit hook as messages finalize.
append_message :: proc(s: ^Session, msg: agent.Agent_Message) -> os.Error {
	assert(s.file != nil)
	entry := Entry {
		id        = fmt.aprintf("e%d", s.next_seq, allocator = s.allocator),
		parent_id = s.tip_id,
		seq       = s.next_seq,
		kind      = .Message,
		message   = msg,
	}
	line, merr := json.marshal(entry, {}, s.allocator)
	if merr != nil {
		return os.General_Error.Invalid_File
	}
	buf := make([dynamic]u8, 0, len(line) + 1, s.allocator)
	append(&buf, ..line)
	append(&buf, '\n')
	if _, werr := os.write(s.file, buf[:]); werr != nil {
		return werr
	}
	s.tip_id = entry.id
	s.next_seq += 1
	return nil
}

// Commit a compaction record (self-contained: summary + retained tail).
append_compaction :: proc(s: ^Session, data: ^agent.Compaction) -> os.Error {
	assert(s.file != nil)
	assert(data != nil)
	entry := Entry {
		id             = fmt.aprintf("e%d", s.next_seq, allocator = s.allocator),
		parent_id      = s.tip_id,
		seq            = s.next_seq,
		kind           = .Compaction,
		summary        = data.summary,
		tokens_before  = data.tokens_before,
		files_read     = data.files_read,
		files_modified = data.files_modified,
		tail           = data.tail,
	}
	line, merr := json.marshal(entry, {}, s.allocator)
	if merr != nil {
		return os.General_Error.Invalid_File
	}
	buf := make([dynamic]u8, 0, len(line) + 1, s.allocator)
	append(&buf, ..line)
	append(&buf, '\n')
	if _, werr := os.write(s.file, buf[:]); werr != nil {
		return werr
	}
	s.tip_id = entry.id
	s.next_seq += 1
	return nil
}

// Emit decorator: persist messages as they finalize, forward to inner sink.
Emit_Session :: struct {
	session:        ^Session,
	inner:          agent.Emit,
	inner_userdata: rawptr,
}

emit :: proc(event: agent.Event, userdata: rawptr) {
	w := cast(^Emit_Session)userdata
	#partial switch e in event {
	case agent.Event_Message_End:
		_ = append_message(w.session, e.message^)
	case agent.Event_Compaction:
		_ = append_compaction(w.session, e.data)
	case agent.Event_Tool_End:
		_ = append_message(w.session, agent.Agent_Message {
			role        = .Tool_Result,
			tool_call_id = e.id,
			text        = e.text,
			is_error    = e.is_error,
			timestamp   = time.to_unix_seconds(time.now()),
		})
	}
	if w.inner != nil {
		w.inner(event, w.inner_userdata)
	}
}
