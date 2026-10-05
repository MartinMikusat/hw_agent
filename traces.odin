package main

// Raw provider traces: dev profile only (HW_DEVLOG_PROFILE=dev), one directory
// per daemon session (cli runs share "cli"), files pruned after TRACE_MAX_AGE.

import "core:fmt"
import "core:os"
import "core:thread"
import "core:time"

import devlog "devlog:."

TRACE_MAX_AGE :: 30 * 24 * time.Hour
TRACE_PRUNE_INTERVAL :: 24 * time.Hour

tracing_enabled :: proc() -> bool {
	return devlog.profile_from_env() == .Dev
}

// prune_traces removes trace files older than TRACE_MAX_AGE and the directories
// they leave empty.
prune_traces :: proc(root: string) {
	dirs, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil { return }
	cutoff := time.time_add(time.now(), -TRACE_MAX_AGE)
	removed := 0
	for dir in dirs {
		if dir.type != .Directory { continue }
		files, ferr := os.read_all_directory_by_path(dir.fullpath, context.temp_allocator)
		if ferr != nil { continue }
		kept := 0
		for f in files {
			if time.diff(f.modification_time, cutoff) > 0 && os.remove(f.fullpath) == nil {
				removed += 1
			} else {
				kept += 1
			}
		}
		if kept == 0 { os.remove(dir.fullpath) }
	}
	if removed > 0 {
		devlog.succeeded(devlog.global(), {feature = "traces", operation = "prune"}, metrics = {rows = i64(removed)})
	}
}

// start_trace_pruning prunes now and, for the long-running daemon, daily.
start_trace_pruning :: proc(root: string, daily: bool) {
	prune_traces(root)
	if !daily { return }
	owned := new(string)
	owned^ = root
	thread.create_and_start_with_data(owned, proc(data: rawptr) {
		root := (cast(^string)data)^
		for {
			time.sleep(TRACE_PRUNE_INTERVAL)
			prune_traces(root)
			free_all(context.temp_allocator)
		}
	}, self_cleanup = true)
}

cli_trace_dir :: proc() -> string {
	return fmt.aprintf("%s/cli", traces_dir())
}
