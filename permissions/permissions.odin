package permissions

// Tool permission rules. A rule is {action, tool, match}: action allow|ask|deny,
// tool a name or glob ("*" for all), match an optional glob over the call's
// target — the command for bash, the absolute path for read/write/edit. Tools
// without a target (find_files, grep, multi_grep) only match rules without match.
//
// Decision: any matching deny wins; otherwise the last matching rule decides
// (global file first, then the project's); a session grant overrides ask; no
// match means allow. Project files (<root>/.hw_agent/permissions.json) may only
// add ask and deny rules: a repository must not be able to grant itself access.
//
// Globs: '*' matches any run of characters (including '/'), '?' one character.
// bash: ask/deny patterns are tried on the whole command and on each piece when
// it is split at ; & | ( ) ` and newlines, so "rm -rf*" catches "make && rm -rf x".
// An allow pattern matches only a plain single command (none of ; & | < > ( ) ` $
// \ or a newline), so "allow git status*" cannot be used to smuggle a second
// command. Patterns are a guardrail against mistakes, not a sandbox: "bash -c ..."
// can hide anything, and symlinks are not resolved.

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import devlog "devlog:."

import "../instructions"

Action :: enum {
	Allow,
	Ask,
	Deny,
}

Source :: enum {
	Global,
	Project,
}

Rule :: struct {
	action: Action,
	tool:   string,
	match:  string,
	source: Source,
}

Grant :: struct {
	tool:   string,
	target: string,
}

// Gate holds one session's rules and its in-memory grants. Not thread-safe: it
// is used from the loop thread only.
Gate :: struct {
	rules:        []Rule,
	cwd:          string,
	grants:       [dynamic]Grant,
	auto_approve: bool, // answer every ask with allow (-yes)
	allocator:    mem.Allocator,
}

Decision :: struct {
	action: Action,
	target: string, // what the rules were matched against
	rule:   string, // the deciding rule, readable; "" when none matched
}

File_Rule :: struct {
	action: string,
	tool:   string,
	match:  string,
}

File :: struct {
	rules: []File_Rule,
}

// parse_file is strict: unknown keys and wrong types are errors, because a typo
// in a security file must not silently drop a rule. Strings live in the temp
// allocator.
parse_file :: proc(data: []u8) -> (file: File, valid: bool) {
	value, err := json.parse(data, allocator = context.temp_allocator)
	if err != nil { return }
	root, is_object := value.(json.Object)
	if !is_object || len(root) != 1 { return }
	list, is_array := root["rules"].(json.Array)
	if !is_array { return }
	rules := make([]File_Rule, len(list), context.temp_allocator)
	for item, i in list {
		obj, ok := item.(json.Object)
		if !ok { return }
		for key, field in obj {
			text, is_string := field.(json.String)
			if !is_string { return }
			switch key {
			case "action": rules[i].action = string(text)
			case "tool":   rules[i].tool = string(text)
			case "match":  rules[i].match = string(text)
			case: return
			}
		}
	}
	return File{rules}, true
}

// load builds the gate for a session in cwd from the global file and the
// project's. A missing file is normal; a file that cannot be read or is invalid
// is an error, never silently permissive.
load :: proc(cwd, global_path: string, allocator := context.allocator) -> (gate: ^Gate, err: string) {
	rules := make([dynamic]Rule, 0, 8, allocator)
	if len(global_path) > 0 {
		list, ferr := load_file(global_path, .Global, allocator)
		if ferr != "" { return nil, ferr }
		append(&rules, ..list)
	}
	project_path := fmt.tprintf("%s/.hw_agent/permissions.json", instructions.find_root(cwd))
	list, ferr := load_file(project_path, .Project, allocator)
	if ferr != "" { return nil, ferr }
	append(&rules, ..list)

	gate = new(Gate, allocator)
	gate.rules = rules[:]
	gate.cwd = strings.clone(cwd, allocator)
	gate.allocator = allocator
	gate.grants = make([dynamic]Grant, 0, 4, allocator)
	return gate, ""
}

load_file :: proc(path: string, source: Source, allocator := context.allocator) -> (rules: []Rule, err: string) {
	if !os.is_file(path) { return nil, "" }
	site := devlog.Site{feature = "permissions", operation = "load"}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		devlog.failed(devlog.global(), site, {reason = "permissions file could not be read", detail = basename(path)})
		return nil, fmt.aprintf("permissions file %s could not be read", basename(path), allocator = allocator)
	}
	file, valid := parse_file(data)
	if !valid {
		devlog.failed(devlog.global(), site, {reason = "permissions file is not valid", detail = basename(path)})
		return nil, fmt.aprintf("permissions file %s must be {{\"rules\":[{{\"action\":\"allow|ask|deny\",\"tool\":\"…\",\"match\":\"…\"}}]}} with no other keys", basename(path), allocator = allocator)
	}
	out := make([dynamic]Rule, 0, len(file.rules), allocator)
	for r, i in file.rules {
		action: Action
		switch r.action {
		case "allow": action = .Allow
		case "ask":   action = .Ask
		case "deny":  action = .Deny
		case:
			devlog.failed(devlog.global(), site, {reason = "permissions rule has an unknown action", detail = basename(path)})
			return nil, fmt.aprintf("permissions file %s: rule %d has action %q (use allow, ask or deny)", basename(path), i + 1, r.action, allocator = allocator)
		}
		if len(r.tool) == 0 {
			devlog.failed(devlog.global(), site, {reason = "permissions rule has no tool", detail = basename(path)})
			return nil, fmt.aprintf("permissions file %s: rule %d has no tool", basename(path), i + 1, allocator = allocator)
		}
		if source == .Project && action == .Allow {
			devlog.failed(devlog.global(), site, {reason = "project permissions file has allow rules, which are ignored", severity = .Warning, detail = basename(path)})
			continue
		}
		append(&out, Rule{action, strings.clone(r.tool, allocator), strings.clone(r.match, allocator), source})
	}
	return out[:], ""
}

// evaluate decides one tool call.
evaluate :: proc(g: ^Gate, tool, arguments_json: string) -> Decision {
	target := target_of(g, tool, arguments_json)
	last: ^Rule
	for &r in g.rules {
		if !rule_matches(r, tool, target) { continue }
		if r.action == .Deny { return {.Deny, target, describe(r)} }
		last = &r
	}
	if last == nil { return {.Allow, target, ""} }
	if last.action == .Ask && len(target) > 0 {
		for grant in g.grants {
			if grant.tool == tool && grant.target == target { return {.Allow, target, "granted for this session"} }
		}
	}
	return {last.action, target, describe(last^)}
}

// grant allows this exact tool and target for the rest of the session.
grant :: proc(g: ^Gate, tool, target: string) {
	if len(target) == 0 { return }
	append(&g.grants, Grant{strings.clone(tool, g.allocator), strings.clone(target, g.allocator)})
}

describe :: proc(r: Rule) -> string {
	action := r.action == .Deny ? "deny" : r.action == .Ask ? "ask" : "allow"
	where_ := r.source == .Project ? "project" : "global"
	if len(r.match) == 0 { return fmt.tprintf("%s %s (%s)", action, r.tool, where_) }
	return fmt.tprintf("%s %s %q (%s)", action, r.tool, r.match, where_)
}

// target_of is what patterns see: the command for bash, the absolute cleaned
// path for read/write/edit, "" for tools without one.
target_of :: proc(g: ^Gate, tool, arguments_json: string) -> string {
	key: string
	switch tool {
	case "bash":                  key = "command"
	case "read", "write", "edit": key = "path"
	case: return ""
	}
	value, err := json.parse_string(arguments_json, allocator = context.temp_allocator)
	if err != nil { return "" }
	obj, _ := value.(json.Object)
	text, _ := obj[key].(json.String)
	if key == "command" { return strings.trim_space(string(text)) }
	return absolute(g.cwd, string(text))
}

rule_matches :: proc(r: Rule, tool, target: string) -> bool {
	if !glob(r.tool, tool) { return false }
	if len(r.match) == 0 { return true }
	if len(target) == 0 { return false }
	if tool != "bash" { return glob(r.match, target) }
	if r.action == .Allow { return plain_command(target) && glob(r.match, target) }
	if glob(r.match, target) { return true }
	rest := target
	for len(rest) > 0 {
		cut := strings.index_any(rest, ";&|()`\n")
		piece := cut < 0 ? rest : rest[:cut]
		if piece = strings.trim_space(piece); len(piece) > 0 && glob(r.match, piece) { return true }
		if cut < 0 { break }
		rest = rest[cut + 1:]
	}
	return false
}

// plain_command: no way to chain, redirect, substitute or escape.
plain_command :: proc(command: string) -> bool {
	return strings.index_any(command, ";&|<>()`$\\\n") < 0
}

// glob matches '*' (any run, including none) and '?' (any one byte) against text.
glob :: proc(pattern, text: string) -> bool {
	p, t := 0, 0
	star, mark := -1, 0
	for t < len(text) {
		switch {
		case p < len(pattern) && (pattern[p] == '?' || pattern[p] == text[t]) && pattern[p] != '*':
			p += 1
			t += 1
		case p < len(pattern) && pattern[p] == '*':
			star = p
			mark = t
			p += 1
		case star >= 0:
			p = star + 1
			mark += 1
			t = mark
		case:
			return false
		}
	}
	for p < len(pattern) && pattern[p] == '*' { p += 1 }
	return p == len(pattern)
}

// absolute resolves path against cwd and removes "." and ".." segments.
absolute :: proc(cwd, path: string) -> string {
	if len(path) == 0 { return "" }
	full := strings.has_prefix(path, "/") ? path : fmt.tprintf("%s/%s", cwd, path)
	parts := make([dynamic]string, context.temp_allocator)
	for segment in strings.split(full, "/", context.temp_allocator) {
		switch segment {
		case "", ".":
		case "..": if len(parts) > 0 { pop(&parts) }
		case: append(&parts, segment)
		}
	}
	return fmt.tprintf("/%s", strings.join(parts[:], "/", context.temp_allocator))
}

@(private)
basename :: proc(path: string) -> string {
	return path[strings.last_index_byte(path, '/') + 1:]
}
