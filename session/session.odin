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
import devlog "devlog:."

import "../agent"

Entry_Kind :: enum {
	Message,
	Compaction,
	Header, // first entry of daemon-created sessions
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

	// kind == .Header
	model:   string `json:"model,omitempty"`,
	created: i64 `json:"created,omitempty"`,
}

Session :: struct {
	path:      string,
	file:      ^os.File,
	next_seq:  int,
	tip_id:    string,
	model:     string, // from the header entry; "" when absent
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
		if err := replay_into(s, path, &messages); err != nil {
			devlog.failed(devlog.global(), {feature = "session", operation = "open"}, {
				reason = err == os.General_Error.Invalid_File ? "session log is corrupt" : "session log could not be read",
				detail = basename(path),
			})
			return nil, nil, err
		}
	}

	file, oerr := os.open(path, {.Write, .Create, .Append}, os.perm(0o600))
	if oerr != nil {
		devlog.failed(devlog.global(), {feature = "session", operation = "open"}, {reason = "session log could not be opened for append", detail = basename(path)})
		return nil, nil, oerr
	}
	s.file = file
	return s, messages[:], nil
}

// Read-only replay of the log at path, for observers of a live session.
replay :: proc(path: string, allocator: mem.Allocator) -> ([]agent.Agent_Message, os.Error) {
	s := Session{allocator = allocator}
	messages := make([dynamic]agent.Agent_Message, 0, 64, allocator)
	err := replay_into(&s, path, &messages)
	return messages[:], err
}

@(private)
replay_into :: proc(s: ^Session, path: string, messages: ^[dynamic]agent.Agent_Message) -> os.Error {
	allocator := s.allocator
	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return rerr
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if len(strings.trim_space(line)) == 0 {
			continue
		}
		entry: Entry
		if uerr := json.unmarshal(transmute([]u8)line, &entry, .JSON, allocator); uerr != nil {
			return os.General_Error.Invalid_File // malformed entry — refuse to resume over corruption
		}
		#partial switch entry.kind {
		case .Message:
			append(messages, entry.message)
		case .Compaction:
			// Self-contained: reset replay to summary + retained tail.
			// Later entries append on top; earlier ones are dropped.
			clear(messages)
			append(messages, agent.Agent_Message {
				role = .Compaction_Summary,
				text = entry.summary,
			})
			for m in entry.tail {
				append(messages, m)
			}
		case .Header:
			s.model = entry.model
		}
		s.tip_id = entry.id
		s.next_seq = entry.seq + 1
	}
	return nil
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
	return write_entry(s, entry)
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
	return write_entry(s, entry)
}

// First entry of a new session: the model it runs on.
append_header :: proc(s: ^Session, model: string) -> os.Error {
	assert(s.file != nil)
	assert(s.next_seq == 0)
	entry := Entry {
		id      = fmt.aprintf("e%d", s.next_seq, allocator = s.allocator),
		seq     = s.next_seq,
		kind    = .Header,
		model   = model,
		created = time.to_unix_seconds(time.now()),
	}
	if err := write_entry(s, entry); err != nil { return err }
	s.model = strings.clone(model, s.allocator)
	return nil
}

@(private)
write_entry :: proc(s: ^Session, entry: Entry) -> os.Error {
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
	err: os.Error
	#partial switch e in event {
	case agent.Event_Message_End:
		err = append_message(w.session, e.message^)
	case agent.Event_Compaction:
		err = append_compaction(w.session, e.data)
	case agent.Event_Tool_End:
		err = append_message(w.session, agent.Agent_Message {
			role        = .Tool_Result,
			tool_call_id = e.id,
			text        = e.text,
			is_error    = e.is_error,
			timestamp   = time.to_unix_seconds(time.now()),
		})
	}
	if err != nil {
		// The run continues in memory; this transcript entry is lost on disk.
		devlog.failed(devlog.global(), {feature = "session", operation = "append"}, {reason = "session entry could not be written", detail = basename(w.session.path)})
	}
	if w.inner != nil {
		w.inner(event, w.inner_userdata)
	}
}

@(private)
basename :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return path[i + 1:]
}
