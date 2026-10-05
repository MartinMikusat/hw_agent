package compact

// pi-style compaction: summarize the head, keep a verbatim tail, chain prior
// summaries by serializing them into the head. The retained tail is copied
// into the Compaction record so a session log entry is self-contained.
// Cut safety: the tail may never start on a tool result — that would orphan
// the tool call it answers.

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import devlog "devlog:."
import "core:time"

import "../agent"
import "../ai"
import "../textutil"

RESERVE_TOKENS :: 16_000  // headroom below the context window
KEEP_CHARS     :: 80_000  // ~20k tokens of verbatim tail at chars/4
SNIP_CHARS     :: 2_000   // tool output cap inside the summarizer input
THINK_SNIP     :: 1_000

SUMMARY_SYSTEM :: `You are a context summarization assistant. Produce a structured handoff summary so work can continue without the original conversation.`

SUMMARY_TEMPLATE :: `Summarize this conversation history for continuation:

%s

Structure the summary as:
- Goal: what the user is trying to accomplish
- Constraints & Preferences
- Progress: Done / In Progress / Blocked
- Key Decisions
- Next Steps: concrete remaining work
- Critical Context: paths, identifiers, and values that must not be lost

If the history contains a prior summary, merge it — do not repeat it verbatim.`

// Estimated context size: real provider usage from the last assistant
// message when reported, plus chars/4 for anything after it.
estimate_tokens :: proc(messages: []agent.Agent_Message) -> int {
	base := 0
	last := -1
	for i := len(messages) - 1; i >= 0; i -= 1 {
		if messages[i].role == .Assistant && messages[i].usage.total > 0 {
			base = messages[i].usage.input + messages[i].usage.output
			last = i
			break
		}
	}
	for i in last + 1 ..< len(messages) {
		base += msg_chars(messages[i]) / 4
	}
	return base
}

msg_chars :: proc(m: agent.Agent_Message) -> int {
	n := len(m.text) + len(m.thinking) + len(m.reasoning_details_json)
	for c in m.tool_calls {
		n += len(c.name) + len(c.arguments)
	}
	return n
}

needs :: proc(ctx: ^agent.Context, model: ai.Model) -> bool {
	return estimate_tokens(ctx.messages[:]) > model.context_window - RESERVE_TOKENS
}

// First index of the retained tail; -1 when nothing worth cutting.
find_cut :: proc(messages: []agent.Agent_Message, keep_chars: int) -> int {
	acc := 0
	cut := len(messages)
	for i := len(messages) - 1; i >= 0; i -= 1 {
		acc += msg_chars(messages[i])
		if acc > keep_chars {
			break
		}
		cut = i
	}
	// Snap forward: the tail may not begin on a tool result — the call it
	// answers would be summarized away, leaving an orphan.
	for cut < len(messages) && messages[cut].role == .Tool_Result {
		cut += 1
	}
	if cut <= 0 || cut >= len(messages) {
		return -1
	}
	return cut
}

serialize_head :: proc(messages: []agent.Agent_Message, allocator: mem.Allocator) -> string {
	out := strings.builder_make(allocator)
	for m in messages {
		switch m.role {
		case .User:
			fmt.sbprintf(&out, "[User]: %s\n", m.text)
		case .Assistant:
			if len(m.text) > 0 {
				fmt.sbprintf(&out, "[Assistant]: %s\n", m.text)
			}
			if len(m.thinking) > 0 {
				text, more := snip(m.thinking, THINK_SNIP)
				fmt.sbprintf(&out, "[Assistant thinking]: %s%s\n", text, more)
			}
			for c in m.tool_calls {
				args, more := snip(c.arguments, SNIP_CHARS)
				fmt.sbprintf(&out, "[Assistant tool call]: %s(%s%s)\n", c.name, args, more)
			}
		case .Tool_Result:
			label := m.is_error ? "[Tool error]" : "[Tool result]"
			text, more := snip(m.text, SNIP_CHARS)
			fmt.sbprintf(&out, "%s: %s%s\n", label, text, more)
		case .Compaction_Summary:
			fmt.sbprintf(&out, "[Prior summary]: %s\n", m.text)
		case .Bash_Execution, .Custom, .Branch_Summary:
			text, more := snip(m.text, SNIP_CHARS)
			fmt.sbprintf(&out, "[Context]: %s%s\n", text, more)
		}
	}
	return strings.to_string(out)
}

// snip cuts text to limit bytes on a character boundary and says whether it did.
snip :: proc(text: string, limit: int) -> (kept: string, ellipsis: string) {
	if len(text) <= limit { return text, "" }
	return textutil.cut(text, limit), "…"
}

// Deterministic file-op extraction — survives successive compactions without
// depending on the summarizer's memory. Results are allocated with allocator,
// parsing scratch with scratch.
file_ops :: proc(messages: []agent.Agent_Message, allocator, scratch: mem.Allocator) -> (read, modified: [dynamic]string) {
	read = make([dynamic]string, 0, 8, allocator)
	modified = make([dynamic]string, 0, 8, allocator)
	seen_r := make(map[string]bool, allocator = scratch)
	seen_m := make(map[string]bool, allocator = scratch)
	for m in messages {
		if m.role != .Assistant {
			continue
		}
		for c in m.tool_calls {
			list: ^[dynamic]string
			seen: ^map[string]bool
			switch c.name {
			case "read":
				list, seen = &read, &seen_r
			case "write", "edit":
				list, seen = &modified, &seen_m
			case:
				continue
			}
			v, perr := json.parse_string(c.arguments, .JSON, false, scratch)
			if perr != nil {
				continue
			}
			if obj, ok := v.(json.Object); ok {
				if p, has := obj["path"].(json.String); has && len(p) > 0 && !seen[string(p)] {
					seen[string(p)] = true
					append(list, strings.clone(string(p), allocator))
				}
			}
		}
	}
	return read, modified
}

PRUNE_PROTECT_CHARS :: 40_000  // most recent tool output kept verbatim (~10k tokens)
PRUNE_MIN_RECLAIM  :: 20_000   // don't bother projecting for less than this

PRUNED_MARKER :: "[Old tool result content cleared]"

// Read-side projection for Loop_Config.transform_context: tool results older
// than the protected horizon render as a marker. Stored messages are never
// mutated — the log stays truthful, the wire stays small. Postpones the
// expensive LLM summary by reclaiming dead weight first.
prune :: proc(messages: []agent.Agent_Message, userdata: rawptr) -> []agent.Agent_Message {
	protected := 0
	reclaimable := 0
	for i := len(messages) - 1; i >= 0; i -= 1 {
		m := messages[i]
		if m.role != .Tool_Result {
			continue
		}
		protected += len(m.text)
		if protected > PRUNE_PROTECT_CHARS {
			reclaimable += len(m.text)
		}
	}
	if reclaimable < PRUNE_MIN_RECLAIM {
		return messages
	}
	out := make([]agent.Agent_Message, len(messages), context.allocator)
	protected = 0
	for i := len(messages) - 1; i >= 0; i -= 1 {
		out[i] = messages[i]
		if out[i].role != .Tool_Result {
			continue
		}
		protected += len(out[i].text)
		if protected > PRUNE_PROTECT_CHARS {
			out[i].text = PRUNED_MARKER
		}
	}
	return out
}

// The Loop_Config.compact hook. Checks the threshold, summarizes the head,
// splices [Compaction_Summary] + tail into ctx.messages, and returns the
// record for the session log. nil = nothing to do, no safe cut, a failed
// summary, or an abort (which also stops the summary request).
//
// ponytail: the messages cut away are not freed (the loop cannot tell heap
// strings from literals); that is bounded by one conversation per compaction.
maybe_compact :: proc(
	ctx: ^agent.Context,
	cfg: ^agent.Loop_Config,
	cancel: ^ai.Cancellation,
	userdata: rawptr,
) -> ^agent.Compaction {
	allocator := context.allocator
	if !needs(ctx, cfg.model) {
		return nil
	}
	site := devlog.Site{feature = "compaction", operation = "summarize"}
	cut := find_cut(ctx.messages[:], KEEP_CHARS)
	if cut < 0 {
		devlog.failed(devlog.global(), site, {reason = "context over threshold but no safe cut", severity = .Warning})
		return nil
	}
	started := time.tick_now()
	devlog.started(devlog.global(), site)

	// The summarizer's input, request and stream live in this arena; only the
	// summary text and the record are kept.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	scratch := mem.dynamic_arena_allocator(&arena)

	head_text := serialize_head(ctx.messages[:cut], scratch)
	prompt := fmt.aprintf(SUMMARY_TEMPLATE, head_text, allocator = scratch)

	sum_ctx := ai.Context {
		system_prompt = SUMMARY_SYSTEM,
		messages = []ai.Message{{role = .User, text = prompt}},
	}
	stream, serr := cfg.stream(cfg.model, sum_ctx, cfg.api_key, cancel, scratch)
	if serr != nil {
		if serr != .Aborted {
			devlog.failed(devlog.global(), site, {reason = "summary request failed; context kept", severity = .Warning, code = i32(serr)})
		}
		return nil
	}
	defer stream.close(&stream)
	failed := false
	for {
		ev, ok := stream.next(&stream)
		if !ok {
			break
		}
		if ev.kind == .Error {
			failed = true
		}
	}
	if ai.is_cancelled(cancel) {
		return nil
	}
	if failed {
		devlog.failed(devlog.global(), site, {reason = "summary request failed; context kept", severity = .Warning})
		return nil
	}
	final := stream.result(&stream)
	if len(final.text) == 0 {
		devlog.failed(devlog.global(), site, {reason = "summary was empty; context kept", severity = .Warning})
		return nil
	}
	devlog.succeeded(devlog.global(), site, metrics = {duration_ms = i64(time.duration_milliseconds(time.tick_since(started)))})

	read, modified := file_ops(ctx.messages[:cut], allocator, scratch)
	summary := strings.builder_make(allocator)
	strings.write_string(&summary, final.text)
	if len(read) > 0 || len(modified) > 0 {
		strings.write_string(&summary, "\n\n## File operations\n")
		if len(read) > 0 {
			fmt.sbprintf(&summary, "Files read: %s\n", strings.join(read[:], ", ", scratch))
		}
		if len(modified) > 0 {
			fmt.sbprintf(&summary, "Files modified: %s\n", strings.join(modified[:], ", ", scratch))
		}
	}
	summary_text := strings.to_string(summary)

	tokens_before := estimate_tokens(ctx.messages[:])
	tail := make([]agent.Agent_Message, len(ctx.messages) - cut, allocator)
	for m, i in ctx.messages[cut:] {
		tail[i] = m
	}

	compaction := new(agent.Compaction, allocator)
	compaction.summary = summary_text
	compaction.tokens_before = tokens_before
	compaction.files_read = read[:]
	compaction.files_modified = modified[:]
	compaction.tail = tail

	clear(&ctx.messages)
	append(&ctx.messages, agent.Agent_Message {
		role = .Compaction_Summary,
		text = summary_text,
		timestamp = time.to_unix_seconds(time.now()),
	})
	for m in tail {
		append(&ctx.messages, m)
	}
	return compaction
}
