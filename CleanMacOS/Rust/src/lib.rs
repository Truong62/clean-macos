pub mod calc;
pub mod english;
pub mod fswalk;
pub mod rank;
pub mod typing;
pub mod units;
pub mod usage;
pub mod vietnamese;

use std::collections::HashMap;
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

fn typing_output(output: typing::Output, out_backspaces: *mut u32) -> *mut c_char {
    match output {
        typing::Output::Pass => std::ptr::null_mut(),
        typing::Output::Replace { backspaces, text } => {
            if !out_backspaces.is_null() {
                unsafe { *out_backspaces = backspaces as u32 };
            }
            into_c_string(text)
        }
    }
}

fn engine<'a>(raw: *mut typing::Engine) -> Option<&'a mut typing::Engine> {
    unsafe { raw.as_mut() }
}

#[no_mangle]
pub extern "C" fn mk_typing_new() -> *mut typing::Engine {
    Box::into_raw(Box::new(typing::Engine::new(typing::Options::default())))
}

#[no_mangle]
pub extern "C" fn mk_typing_free(raw: *mut typing::Engine) {
    if !raw.is_null() {
        drop(unsafe { Box::from_raw(raw) });
    }
}

#[no_mangle]
pub extern "C" fn mk_typing_configure(raw: *mut typing::Engine, flags: u32) {
    let Some(engine) = engine(raw) else { return };
    let on = |bit: u32| flags & (1 << bit) != 0;
    engine.options = typing::Options {
        method: if on(0) { typing::Method::Vni } else { typing::Method::Telex },
        vietnamese: on(1),
        modern_tone: on(2),
        auto_restore: on(3),
        w_as_u: on(4),
        brackets: on(5),
        foreign_consonants: on(6),
        auto_capitalize: on(7),
    };
    engine.reset();
}

#[no_mangle]
pub extern "C" fn mk_typing_restore(raw: *mut typing::Engine, out_backspaces: *mut u32) -> *mut c_char {
    let Some(engine) = engine(raw) else { return std::ptr::null_mut() };
    typing_output(engine.restore(), out_backspaces)
}

#[no_mangle]
pub extern "C" fn mk_typing_set_macros(raw: *mut typing::Engine, lines: *const c_char) {
    let Some(engine) = engine(raw) else { return };
    let text = if lines.is_null() { "" } else { unsafe { CStr::from_ptr(lines) }.to_str().unwrap_or("") };
    let macros: HashMap<String, String> = text
        .lines()
        .filter_map(|line| line.split_once('\t'))
        .filter(|(key, value)| !key.is_empty() && !value.is_empty())
        .map(|(key, value)| (key.to_string(), value.to_string()))
        .collect();
    engine.set_macros(macros);
}

#[no_mangle]
pub extern "C" fn mk_typing_key(raw: *mut typing::Engine, ch: u32, out_backspaces: *mut u32) -> *mut c_char {
    let (Some(engine), Some(ch)) = (engine(raw), char::from_u32(ch)) else { return std::ptr::null_mut() };
    typing_output(engine.key(ch), out_backspaces)
}

#[no_mangle]
pub extern "C" fn mk_typing_finish(raw: *mut typing::Engine, separator: u32, out_backspaces: *mut u32) -> *mut c_char {
    let Some(engine) = engine(raw) else { return std::ptr::null_mut() };
    typing_output(engine.finish(char::from_u32(separator).filter(|ch| *ch != '\0')), out_backspaces)
}

#[no_mangle]
pub extern "C" fn mk_typing_backspace(raw: *mut typing::Engine) {
    if let Some(engine) = engine(raw) {
        engine.backspace();
    }
}

#[no_mangle]
pub extern "C" fn mk_typing_reset(raw: *mut typing::Engine) {
    if let Some(engine) = engine(raw) {
        engine.reset();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typing_engine_round_trips_through_the_c_interface() {
        let engine = mk_typing_new();
        mk_typing_set_macros(engine, CString::new("ko\tkhông\n\tbad\n").unwrap().as_ptr());
        let mut backspaces = 0u32;
        let mut screen = String::new();
        for ch in "tieengs ko ".chars() {
            let text = mk_typing_key(engine, ch as u32, &mut backspaces);
            if text.is_null() {
                screen.push(ch);
            } else {
                for _ in 0..backspaces {
                    screen.pop();
                }
                screen.push_str(unsafe { CStr::from_ptr(text) }.to_str().unwrap());
                mk_string_free(text);
            }
        }
        assert_eq!(screen, "tiếng không ");
        mk_typing_configure(engine, 0b11111);
        assert!(mk_typing_key(engine, 'a' as u32, &mut backspaces).is_null());
        let toned = mk_typing_key(engine, '1' as u32, &mut backspaces);
        assert_eq!(unsafe { CStr::from_ptr(toned) }.to_str().unwrap(), "á");
        assert_eq!(backspaces, 1);
        mk_string_free(toned);
        mk_typing_free(engine);
    }

    #[test]
    fn escapes_paths_for_json() {
        assert_eq!(json_string("a\"b\\c\nd\u{1}"), "\"a\\\"b\\\\c\\nd\\u0001\"");
        assert_eq!(json_string("Nhạc/Sơn Tùng"), "\"Nhạc/Sơn Tùng\"");
    }
}

fn text_from<'a>(raw: *const c_char) -> Option<&'a str> {
    if raw.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(raw) }.to_str().ok()
}

#[no_mangle]
pub extern "C" fn mk_calc(input: *const c_char, out_value: *mut f64, out_closed: *mut u32) -> bool {
    let Some(result) = text_from(input).and_then(calc::evaluate) else { return false };
    if !out_value.is_null() {
        unsafe { *out_value = result.value };
    }
    if !out_closed.is_null() {
        unsafe { *out_closed = result.closed as u32 };
    }
    true
}

#[no_mangle]
pub extern "C" fn mk_convert(input: *const c_char) -> *mut c_char {
    match text_from(input).and_then(units::convert) {
        Some(conversion) => into_c_string(format!("{}\t{}\t{}\t{}", conversion.value, conversion.from, conversion.to, conversion.result)),
        None => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn mk_rank(query: *const c_char, rows: *const c_char) -> *mut c_char {
    let (Some(query), Some(rows)) = (text_from(query), text_from(rows)) else { return std::ptr::null_mut() };
    let parsed: Vec<rank::Row> = rows
        .split('\n')
        .filter(|line| !line.is_empty())
        .map(|line| {
            let mut fields = line.split('\t');
            rank::Row {
                title: fields.next().unwrap_or_default().to_string(),
                keywords: fields.next().unwrap_or_default().to_string(),
                bias: fields.next().and_then(|value| value.parse().ok()).unwrap_or(0),
                priority: fields.next().and_then(|value| value.parse().ok()).unwrap_or(0),
            }
        })
        .collect();
    let lines: Vec<String> = rank::rank(query, &parsed)
        .into_iter()
        .map(|ranked| format!("{}\t{}\t{}", ranked.index, ranked.score, ranked.tier))
        .collect();
    into_c_string(lines.join("\n"))
}

#[no_mangle]
pub extern "C" fn mk_ai_usage(request: *const c_char) -> *mut c_char {
    into_c_string(usage::handle(text_from(request).unwrap_or("")))
}
