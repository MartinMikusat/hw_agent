package main

// The daemon updates itself from GitHub releases. A release build compiles in the
// version and feed; dev builds leave them empty and never update. Only the
// installed copy (an executable named hw_agent) updates: the worker stages a
// verified release, waits until no session is running, swaps the executable in
// place and exits, and launchd's KeepAlive restarts it on the new version.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"

import native_update "native_update:."
import "serve"

UPDATE_VERSION :: #config(HW_UPDATE_VERSION, "")
UPDATE_FEED_URL :: #config(HW_UPDATE_FEED_URL, "")
UPDATE_TEAM_ID :: #config(HW_UPDATE_TEAM_ID, "")
UPDATE_BUNDLE_ID :: "com.halwayland.hw_agent"
UPDATE_EXECUTABLE :: "hw_agent"
UPDATE_INTERVAL :: time.Hour
UPDATE_IDLE_POLL :: 5 * time.Second

when UPDATE_VERSION != "" {
	APP_VERSION :: UPDATE_VERSION
} else {
	APP_VERSION :: "dev"
}

update_config :: proc() -> native_update.Config {
	return {feed_url = UPDATE_FEED_URL, bundle_id = UPDATE_BUNDLE_ID, team_id = UPDATE_TEAM_ID, bundle_name = UPDATE_EXECUTABLE}
}

@(private = "file")
Update_Worker :: struct {
	daemon:     ^serve.Daemon,
	executable: string,
}

update_start :: proc(d: ^serve.Daemon) {
	when UPDATE_VERSION == "" || UPDATE_FEED_URL == "" || UPDATE_TEAM_ID == "" { return }
	executable, err := os.get_executable_path(context.allocator)
	if err != nil || !strings.has_suffix(executable, "/" + UPDATE_EXECUTABLE) { return }
	worker := new(Update_Worker)
	worker^ = {daemon = d, executable = executable}
	thread.create_and_start_with_data(worker, update_worker, self_cleanup = true)
}

@(private = "file")
update_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := cast(^Update_Worker)data
	for {
		prepared := update_attempt()
		switch prepared.status {
		case .Ready:
			for !serve.close_if_idle(worker.daemon) { time.sleep(UPDATE_IDLE_POLL) }
			message := native_update.apply(update_config(), &prepared, worker.executable)
			native_update.discard(&prepared)
			if message == "" {
				fmt.eprintfln("hw_agent: updated %s → %s; restarting", APP_VERSION, prepared.manifest.version)
				os.exit(0)
			}
			serve.reopen(worker.daemon)
			fmt.eprintfln("hw_agent: update failed: %s", message)
		case .Error:
			fmt.eprintfln("hw_agent: update check failed: %s", prepared.error)
			native_update.discard(&prepared)
		case .Up_To_Date, .Idle, .Checking:
			native_update.discard(&prepared)
		}
		time.sleep(UPDATE_INTERVAL)
	}
}

// update_attempt runs one check with scratch memory and keeps only what a staged
// update needs.
@(private = "file")
update_attempt :: proc() -> native_update.Prepared {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	heap := runtime.default_allocator()
	prepared: native_update.Prepared
	{
		context.allocator = context.temp_allocator
		prepared = native_update.prepare(update_config(), UPDATE_VERSION)
	}
	kept := native_update.Prepared{status = prepared.status}
	kept.root = strings.clone(prepared.root, heap)
	if prepared.status == .Ready {
		kept.app_path = strings.clone(prepared.app_path, heap)
		kept.manifest.version = strings.clone(prepared.manifest.version, heap)
	} else {
		kept.error = strings.clone(prepared.error, heap)
	}
	return kept
}
