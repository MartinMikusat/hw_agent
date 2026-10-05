//! C API over fff-mcp's search tools for hw_agent. One `Index` per project
//! root; every index shares one frecency database. Strings returned to C are
//! owned by the caller and freed with `hwfff_free_string`.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::OnceLock;

use fff::file_picker::FilePicker;
use fff::frecency::FrecencyTracker;
use fff::{FFFMode, SharedFilePicker, SharedFrecency};
use git2::Repository;

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

include!(concat!(env!("OUT_DIR"), "/instructions.rs"));
include!(concat!(env!("OUT_DIR"), "/modules.rs"));

mod update_check {
    // hw_agent updates itself; fff-mcp's own update notice does not apply.
    pub fn get_update_notice() -> String {
        String::new()
    }
}

pub struct Index {
    server: server::FffServer,
    root: CString,
}

// LMDB allows one environment per path per process, so all indexes share it.
static FRECENCY: OnceLock<SharedFrecency> = OnceLock::new();

fn frecency(db_path: &str) -> SharedFrecency {
    FRECENCY
        .get_or_init(|| {
            let shared = SharedFrecency::default();
            if !db_path.is_empty() {
                if let Some(parent) = std::path::Path::new(db_path).parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                if let Ok(tracker) = FrecencyTracker::open(db_path) {
                    let _ = shared.init(tracker);
                }
            }
            shared
        })
        .clone()
}

fn to_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', " ")).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

unsafe fn from_c<'a>(p: *const c_char) -> &'a str {
    if p.is_null() { "" } else { unsafe { CStr::from_ptr(p) }.to_str().unwrap_or("") }
}

fn resolve_root(base: &str) -> String {
    match Repository::discover(base) {
        Ok(repo) => repo.workdir().map(|w| w.to_string_lossy().trim_end_matches('/').to_string()).unwrap_or(base.to_string()),
        Err(_) => base.to_string(),
    }
}

/// The directory an index for `base_path` would cover: its git root, or itself.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hwfff_resolve_root(base_path: *const c_char) -> *mut c_char {
    let base = unsafe { from_c(base_path) };
    to_c(catch_unwind(|| resolve_root(base)).unwrap_or_else(|_| base.to_string()))
}

/// Opens an index on the git root containing `base_path` (or `base_path` when it
/// is not in a repository) and starts its background scan and watcher. Returns
/// null on failure with the reason in `*error` (free it).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hwfff_open(base_path: *const c_char, frecency_db: *const c_char, error: *mut *mut c_char) -> *mut Index {
    let base = unsafe { from_c(base_path) }.to_string();
    let db = unsafe { from_c(frecency_db) }.to_string();
    let opened = catch_unwind(AssertUnwindSafe(|| -> Result<Index, String> {
        let root = resolve_root(&base);
        let picker = SharedFilePicker::default();
        FilePicker::new_with_shared_state(picker.clone(), frecency(&db), fff::FilePickerOptions {
            base_path: root.clone(),
            enable_mmap_cache: true,
            enable_content_indexing: true,
            watch: true,
            mode: FFFMode::Ai,
            cache_budget: None,
            follow_symlinks: false,
            enable_home_dir_scanning: false,
            enable_fs_root_scanning: false,
            git_recency: Default::default(),
        })
        .map_err(|e| format!("cannot index {root}: {e}"))?;
        Ok(Index { server: server::FffServer::new(picker), root: CString::new(root).unwrap_or_default() })
    }));
    match opened {
        Ok(Ok(index)) => Box::into_raw(Box::new(index)),
        Ok(Err(message)) => {
            if !error.is_null() { unsafe { *error = to_c(message) } }
            std::ptr::null_mut()
        }
        Err(_) => {
            if !error.is_null() { unsafe { *error = to_c("fff panicked while opening the index".into()) } }
            std::ptr::null_mut()
        }
    }
}

/// The directory the index covers (borrowed; valid until hwfff_close).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hwfff_root(index: *const Index) -> *const c_char {
    if index.is_null() { return std::ptr::null() }
    unsafe { &*index }.root.as_ptr()
}

/// Runs `tool` ("find_files", "grep", "multi_grep") with JSON `args`. Always
/// returns text; `*is_error` says whether it describes a failure.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hwfff_call(index: *const Index, tool: *const c_char, args: *const c_char, is_error: *mut bool) -> *mut c_char {
    let (text, failed) = if index.is_null() {
        ("fff index is not open".to_string(), true)
    } else {
        let index = unsafe { &*index };
        let (tool, args) = unsafe { (from_c(tool), from_c(args)) };
        match catch_unwind(AssertUnwindSafe(|| server::hw_call(&index.server, tool, args))) {
            Ok(Ok(result)) => result,
            Ok(Err(message)) => (message, true),
            Err(_) => ("fff panicked while searching".to_string(), true),
        }
    };
    if !is_error.is_null() { unsafe { *is_error = failed } }
    to_c(text)
}

/// fff-mcp's tool definitions as a JSON array (free it).
#[unsafe(no_mangle)]
pub extern "C" fn hwfff_tools() -> *mut c_char {
    to_c(catch_unwind(server::hw_tools_json).unwrap_or_else(|_| "[]".into()))
}

/// fff-mcp's usage instructions for the model (static).
#[unsafe(no_mangle)]
pub extern "C" fn hwfff_instructions() -> *const c_char {
    static TEXT: OnceLock<CString> = OnceLock::new();
    TEXT.get_or_init(|| CString::new(MCP_INSTRUCTIONS).unwrap_or_default()).as_ptr()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hwfff_free_string(s: *mut c_char) {
    if !s.is_null() { drop(unsafe { CString::from_raw(s) }) }
}

/// Stops the index's watcher and frees it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hwfff_close(index: *mut Index) {
    if !index.is_null() { drop(unsafe { Box::from_raw(index) }) }
}
