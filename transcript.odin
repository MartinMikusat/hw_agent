package main

// sessions | show | export | rm: read and manage the daemon's session logs.
// A session is named by its id or by a path to any session log.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "agent"
import "serve"
import "session"

SHOW_TOOL_OUTPUT_CHARS :: 2000

sessions_dir :: proc() -> string {
	return fmt.aprintf("%s/sessions", support_dir())
}

traces_dir :: proc() -> string {
	return fmt.aprintf("%s/traces", support_dir())
}

resolve_session :: proc(arg: string) -> (path, id: string, ok: bool) {
	if strings.contains_rune(arg, '/') || strings.has_suffix(arg, ".jsonl") {
		name := arg[strings.last_index_byte(arg, '/') + 1:]
		return arg, strings.trim_suffix(name, ".jsonl"), os.exists(arg)
	}
	if !serve.valid_id(arg) { return "", "", false }
	path = fmt.aprintf("%s/%s.jsonl", sessions_dir(), arg)
	return path, arg, os.exists(path)
}

Totals :: struct {
	replies:     int,
	input:       int,
	output:      int,
	cost_usd:    f64,
	cost_known:  bool, // every reply reported its cost
	model_ms:    i64,
	tool_ms:     i64,
	tool_calls:  int,
	errors:      int,
}

totals :: proc(messages: []agent.Agent_Message) -> Totals {
	t := Totals{cost_known = true}
	for m in messages {
		#partial switch m.role {
		case .Assistant:
			t.replies += 1
			t.input += m.usage.input
			t.output += m.usage.output
			t.cost_usd += m.usage.cost_usd
			t.cost_known &&= m.usage.cost_reported
			t.model_ms += m.duration_ms
			t.tool_calls += len(m.tool_calls)
			if m.stop_reason == .Error || m.stop_reason == .Aborted { t.errors += 1 }
		case .Tool_Result:
			t.tool_ms += m.duration_ms
		}
	}
	return t
}

cost_text :: proc(t: Totals) -> string {
	return fmt.tprintf("%s$%.4f", t.cost_known ? "" : "≥", t.cost_usd)
}

utc_text :: proc(unix_seconds: i64) -> string {
	if unix_seconds <= 0 { return "-" }
	y, mon, d := time.date(time.unix(unix_seconds, 0))
	h, mi, _ := time.clock(time.unix(unix_seconds, 0))
	return fmt.tprintf("%04d-%02d-%02d %02d:%02dZ", y, int(mon), d, h, mi)
}

first_prompt :: proc(messages: []agent.Agent_Message, width: int) -> string {
	for m in messages {
		if m.role != .User { continue }
		line, _ := strings.replace_all(strings.trim_space(m.text), "\n", " ", context.temp_allocator)
		return len(line) > width ? fmt.tprintf("%s…", line[:width]) : line
	}
	return ""
}

cmd_sessions :: proc() -> int {
	files, err := os.read_all_directory_by_path(sessions_dir(), context.allocator)
	if err != nil {
		fmt.println("no sessions yet")
		return 0
	}
	Row :: struct {
		id, model, prompt: string,
		updated:           i64,
		messages:          int,
		totals:            Totals,
	}
	rows := make([dynamic]Row)
	for f in files {
		id := strings.trim_suffix(f.name, ".jsonl")
		if id == f.name || !serve.valid_id(id) { continue }
		messages, model, rerr := session.replay(f.fullpath, context.allocator)
		if rerr != nil {
			fmt.eprintfln("%s: unreadable (%v)", id, rerr)
			continue
		}
		append(&rows, Row{id, model, first_prompt(messages, 60), f.modification_time._nsec / 1e9, len(messages), totals(messages)})
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.updated > b.updated })
	for r in rows {
		fmt.printfln("%s  %s  %-30s % 4d msgs  % 9s  %s", r.id, utc_text(r.updated), r.model, r.messages, cost_text(r.totals), r.prompt)
	}
	return 0
}

load_session :: proc(arg: string) -> (messages: []agent.Agent_Message, model, id: string, ok: bool) {
	path, sid, found := resolve_session(arg)
	if !found {
		fmt.eprintfln("no such session: %s", arg)
		return nil, "", "", false
	}
	msgs, m, err := session.replay(path, context.allocator)
	if err != nil {
		fmt.eprintfln("%s: unreadable (%v)", arg, err)
		return nil, "", "", false
	}
	return msgs, m, sid, true
}

cmd_show :: proc(arg: string) -> int {
	messages, model, id, ok := load_session(arg)
	if !ok { return 1 }
	b := strings.builder_make()
	write_transcript(&b, messages, model, id, false)
	fmt.print(strings.to_string(b))
	return 0
}

cmd_export :: proc(arg: string, as_json: bool) -> int {
	messages, model, id, ok := load_session(arg)
	if !ok { return 1 }
	if as_json {
		Export :: struct {
			session:  string,
			model:    string,
			totals:   Totals,
			messages: []agent.Agent_Message,
		}
		data, err := json.marshal(Export{id, model, totals(messages), messages}, {pretty = true})
		if err != nil {
			fmt.eprintfln("export failed: %v", err)
			return 1
		}
		fmt.println(string(data))
		return 0
	}
	b := strings.builder_make()
	write_transcript(&b, messages, model, id, true)
	fmt.print(strings.to_string(b))
	return 0
}

// write_transcript renders a session as Markdown. full keeps whole tool
// output and reasoning; show trims them for the terminal.
write_transcript :: proc(b: ^strings.Builder, messages: []agent.Agent_Message, model, id: string, full: bool) {
	t := totals(messages)
	started: i64 = len(messages) > 0 ? messages[0].timestamp : 0
	fmt.sbprintfln(b, "# Session %s\n", id)
	fmt.sbprintfln(b, "%s · started %s · %d replies · %d tool calls · in %d / out %d tokens · %s · model %.1fs · tools %.1fs\n",
		len(model) > 0 ? model : "unknown model", utc_text(started), t.replies, t.tool_calls, t.input, t.output, cost_text(t),
		f64(t.model_ms) / 1000, f64(t.tool_ms) / 1000)
	names := make(map[string]string, context.temp_allocator)
	for m in messages {
		switch m.role {
		case .User:
			label := "User"
			switch m.delivery {
			case .Prompt:
			case .Steer:     label = "User (steer)"
			case .Follow_Up: label = "User (follow-up)"
			}
			fmt.sbprintfln(b, "## %s · %s\n\n%s\n", label, utc_text(m.timestamp), m.text)
		case .Assistant:
			fmt.sbprintfln(b, "## Assistant · %s · %.1fs · in %d / out %d · $%.4f\n", m.model, f64(m.duration_ms) / 1000, m.usage.input, m.usage.output, m.usage.cost_usd)
			if len(m.thinking) > 0 {
				if full {
					fmt.sbprintfln(b, "<details><summary>Reasoning</summary>\n\n%s\n\n</details>\n", m.thinking)
				} else {
					fmt.sbprintfln(b, "_(reasoning: %d chars)_\n", len(m.thinking))
				}
			}
			if m.stop_reason == .Error || m.stop_reason == .Aborted {
				fmt.sbprintfln(b, "**%s:** %s\n", m.stop_reason == .Aborted ? "Aborted" : "Error", m.text)
			} else if len(m.text) > 0 {
				fmt.sbprintfln(b, "%s\n", m.text)
			}
			for call in m.tool_calls {
				names[call.id] = call.name
				fmt.sbprintfln(b, "→ `%s` `%s`\n", call.name, call.arguments)
			}
		case .Tool_Result:
			text := m.text
			if !full && len(text) > SHOW_TOOL_OUTPUT_CHARS {
				text = fmt.tprintf("%s\n… (%d more chars; export for all)", text[:SHOW_TOOL_OUTPUT_CHARS], len(text) - SHOW_TOOL_OUTPUT_CHARS)
			}
			fmt.sbprintfln(b, "← `%s`%s · %.2fs\n\n```\n%s\n```\n", names[m.tool_call_id], m.is_error ? " (error)" : "", f64(m.duration_ms) / 1000, strings.trim_right(text, "\n"))
		case .Compaction_Summary:
			fmt.sbprintfln(b, "## Compacted history\n\n%s\n", m.text)
		case .Bash_Execution, .Custom, .Branch_Summary:
			fmt.sbprintfln(b, "## %v\n\n%s\n", m.role, m.text)
		}
	}
}

// cmd_rm deletes through the running daemon, which owns live sessions; with
// no daemon it removes the files itself.
cmd_rm :: proc(arg: string) -> int {
	path, id, found := resolve_session(arg)
	if !found {
		fmt.eprintfln("no such session: %s", arg)
		return 1
	}
	if serve.valid_id(id) && path == fmt.tprintf("%s/%s.jsonl", sessions_dir(), id) {
		if reply, reached := daemon_request(fmt.tprintf(`{{"cmd":"delete","session":"%s"}}`, id)); reached {
			obj, _ := reply.(json.Object)
			if t, _ := obj["type"].(json.String); t == "deleted" {
				fmt.printfln("deleted %s", id)
				return 0
			}
			text, _ := obj["text"].(json.String)
			fmt.eprintfln("not deleted: %s", text)
			return 1
		}
	}
	if err := os.remove(path); err != nil {
		fmt.eprintfln("cannot remove %s: %v", path, err)
		return 1
	}
	os.remove_all(fmt.tprintf("%s/%s", traces_dir(), id))
	fmt.printfln("deleted %s", id)
	return 0
}

// daemon_request sends one command and returns its reply; reached is false
// when no daemon is listening.
daemon_request :: proc(line: string) -> (reply: json.Value, reached: bool) {
	addr: posix.sockaddr_un
	sock := fmt.tprintf("%s/agent.sock", support_dir())
	if len(sock) >= len(addr.sun_path) { return nil, false }
	addr.sun_family = .UNIX
	addr.sun_len = size_of(addr)
	copy(addr.sun_path[:], sock)
	fd := posix.socket(.UNIX, .STREAM)
	defer posix.close(fd)
	if posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK { return nil, false }
	out := fmt.tprintf("%s\n", line)
	if posix.send(fd, raw_data(out), len(out), {}) != len(out) { return nil, false }
	buf := make([dynamic]u8, context.temp_allocator)
	chunk: [4096]u8
	for {
		n := posix.recv(fd, &chunk, len(chunk), {})
		if n <= 0 { return nil, false }
		append(&buf, ..chunk[:n])
		if idx, found := slice.linear_search(buf[:], '\n'); found {
			v, err := json.parse(buf[:idx], allocator = context.temp_allocator)
			return v, err == nil
		}
	}
}
