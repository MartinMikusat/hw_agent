package agent

import "core:fmt"
import "core:mem"
import "core:strings"

import "../ai"

COMPACTION_SUMMARY_PREFIX :: "Another language model started to solve this problem and produced a summary of its thinking process. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model:\n\n"
BRANCH_SUMMARY_PREFIX :: "The following is a summary of work from a parallel branch of this session:\n\n"

// Agent_Message[] -> provider wire messages. Harness-only roles are folded
// into user-role text so the provider sees a valid conversation.
convert_to_llm :: proc(messages: []Agent_Message, allocator: mem.Allocator) -> []ai.Message {
	out := make([dynamic]ai.Message, 0, len(messages), allocator)
	for msg in messages {
		switch msg.role {
		case .User:
			append(&out, ai.Message{role = .User, text = msg.text})
		case .Assistant:
			append(&out, ai.Message {
				role = .Assistant,
				text = msg.text,
				thinking = msg.thinking,
				reasoning_details_json = msg.reasoning_details_json,
				tool_calls = msg.tool_calls,
			})
		case .Tool_Result:
			append(&out, ai.Message {
				role = .Tool,
				tool_call_id = msg.tool_call_id,
				text = msg.text,
			})
		case .Bash_Execution:
			append(&out, ai.Message{role = .User, text = msg.text})
		case .Custom:
			append(&out, ai.Message{role = .User, text = msg.text})
		case .Branch_Summary:
			append(&out, ai.Message {
				role = .User,
				text = fmt.aprintf("%s%s", BRANCH_SUMMARY_PREFIX, msg.text, allocator = allocator),
			})
		case .Compaction_Summary:
			append(&out, ai.Message {
				role = .User,
				text = fmt.aprintf("%s%s", COMPACTION_SUMMARY_PREFIX, msg.text, allocator = allocator),
			})
		}
	}
	return out[:]
}

// own_message copies the strings and slices an assistant message references into
// allocator, so it can outlive the arena its stream was allocated in.
own_message :: proc(msg: ^Agent_Message, allocator: mem.Allocator) {
	msg.text = strings.clone(msg.text, allocator)
	msg.thinking = strings.clone(msg.thinking, allocator)
	msg.reasoning_details_json = strings.clone(msg.reasoning_details_json, allocator)
	if len(msg.tool_calls) > 0 {
		calls := make([]ai.Tool_Call, len(msg.tool_calls), allocator)
		for call, i in msg.tool_calls {
			calls[i] = {
				id        = strings.clone(call.id, allocator),
				name      = strings.clone(call.name, allocator),
				arguments = strings.clone(call.arguments, allocator),
			}
		}
		msg.tool_calls = calls
	}
}

assistant_from_wire :: proc(msg: ai.Message, timestamp: i64) -> Agent_Message {
	return Agent_Message {
		role = .Assistant,
		text = msg.text,
		thinking = msg.thinking,
		reasoning_details_json = msg.reasoning_details_json,
		tool_calls = msg.tool_calls,
		usage = msg.usage,
		stop_reason = msg.stop_reason,
		timestamp = timestamp,
	}
}
