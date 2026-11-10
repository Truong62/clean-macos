pub mod fswalk;

use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn path_from(raw: *const c_char) -> Option<PathBuf> {
    if raw.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(raw) }.to_str().ok()?;
    Some(PathBuf::from(text))
}

fn deadline(timeout_ms: u64) -> Instant {
    Instant::now() + Duration::from_millis(timeout_ms)
}

pub fn json_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn into_c_string(text: String) -> *mut c_char {
    CString::new(text).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn mk_dir_size(path: *const c_char, timeout_ms: u64, max_depth: u32, out_bytes: *mut u64) -> bool {
    let Some(path) = path_from(path) else { return false };
    let size = fswalk::dir_size(&path, deadline(timeout_ms), max_depth as usize);
    if !out_bytes.is_null() {
        unsafe { *out_bytes = size.bytes };
    }
    size.timed_out
}

#[no_mangle]
pub extern "C" fn mk_large_files_json(
    root: *const c_char,
    min_bytes: u64,
    older_than: i64,
    limit: u32,
    timeout_ms: u64,
    excluded_dir: *const c_char,
) -> *mut c_char {
    let Some(root) = path_from(root) else { return into_c_string("[]".into()) };
    let query = fswalk::LargeFileQuery {
        min_bytes,
        older_than: (older_than > 0).then_some(older_than),
        limit: limit as usize,
        deadline: deadline(timeout_ms),
        excluded_dirs: path_from(excluded_dir).into_iter().collect(),
        excluded_names: vec!["node_modules".into()],
    };
    let items: Vec<String> = fswalk::large_files(Path::new(&root), &query)
        .iter()
        .map(|file| format!("{{\"path\":{},\"bytes\":{},\"modified\":{}}}", json_string(&file.path), file.bytes, file.modified))
        .collect();
    into_c_string(format!("[{}]", items.join(",")))
}

#[no_mangle]
pub extern "C" fn mk_string_free(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_paths_for_json() {
        assert_eq!(json_string("a\"b\\c\nd\u{1}"), "\"a\\\"b\\\\c\\nd\\u0001\"");
        assert_eq!(json_string("Nhạc/Sơn Tùng"), "\"Nhạc/Sơn Tùng\"");
    }
}
