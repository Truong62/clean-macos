use memchr::memmem::Finder;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{hash_map::Entry, BTreeMap, HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

pub const RETENTION_DAYS: i64 = 91;
pub const ROW_WIDTH: usize = 13;
pub const SAVE_INTERVAL: i64 = 30 * 60;
const DAY: i64 = 86_400;
const MINUTE: i64 = 60;
const CHUNK_BYTES: usize = 4 << 20;
const EDGE_BYTES: u64 = 4096;
const CACHE_MAGIC: &str = "MKAIUSAGE";
const CACHE_VERSION: u32 = 1;
const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

static STATES: Mutex<BTreeMap<String, Ingest>> = Mutex::new(BTreeMap::new());

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Agent {
    Claude = 0,
    Codex = 1,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "[u64; 6]", into = "[u64; 6]")]
pub struct Tokens {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write_5m: u64,
    pub cache_write_1h: u64,
    pub web_searches: u64,
}

impl From<[u64; 6]> for Tokens {
    fn from(values: [u64; 6]) -> Self {
        let [input, output, cache_read, cache_write_5m, cache_write_1h, web_searches] = values;
        Tokens { input, output, cache_read, cache_write_5m, cache_write_1h, web_searches }
    }
}

impl From<Tokens> for [u64; 6] {
    fn from(tokens: Tokens) -> Self {
        [tokens.input, tokens.output, tokens.cache_read, tokens.cache_write_5m, tokens.cache_write_1h, tokens.web_searches]
    }
}

impl Tokens {
    fn combine(self, other: Tokens, pick: impl Fn(u64, u64) -> u64) -> Tokens {
        let (left, right) = (<[u64; 6]>::from(self), <[u64; 6]>::from(other));
        Tokens::from(std::array::from_fn(|index| pick(left[index], right[index])))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    pub ts: i64,
    pub agent: u8,
    pub model: u32,
    pub project: u32,
    pub session: u32,
    pub tier: u32,
    pub tokens: Tokens,
}

impl Record {
    fn merged(self, other: Record) -> Record {
        let earliest = if other.ts < self.ts { other } else { self };
        Record { tokens: self.tokens.combine(other.tokens, u64::max), ..earliest }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitWindow {
    pub used_percent: f64,
    pub window_minutes: Option<u64>,
    pub resets_at: Option<i64>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    pub observed_at: i64,
    pub primary: Option<LimitWindow>,
    pub secondary: Option<LimitWindow>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
struct FileState {
    model: String,
    project: String,
    session: String,
    totals: Option<[u64; 3]>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
struct Cursor {
    inode: u64,
    offset: u64,
    head: u64,
    tail: u64,
    #[serde(default)]
    state: FileState,
}

#[derive(Default, Serialize, Deserialize)]
struct Store {
    version: u32,
    names: Vec<String>,
    cursors: HashMap<String, Cursor>,
    records: HashMap<u64, Record>,
    limits: Option<Limits>,
}

struct Found {
    key: u64,
    ts: i64,
    agent: Agent,
    model: String,
    project: String,
    session: String,
    tier: String,
    tokens: Tokens,
}

type RowKey = (i64, u8, u32, u32, u32, u32);

struct Scan {
    path: String,
    cursor: Cursor,
    found: Vec<Found>,
    limits: Option<Limits>,
}

pub struct Ingest {
    path: PathBuf,
    store: Store,
    index: HashMap<String, u32>,
    pub generation: u64,
    dirty: bool,
    saved_at: Option<i64>,
}

#[derive(Deserialize)]
struct ClaudeLine {
    #[serde(rename = "type")]
    kind: Option<String>,
    timestamp: Option<String>,
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    #[serde(rename = "requestId")]
    request_id: Option<String>,
    cwd: Option<String>,
    message: Option<ClaudeMessage>,
}

#[derive(Deserialize)]
struct ClaudeMessage {
    id: Option<String>,
    model: Option<String>,
    usage: Option<ClaudeUsage>,
}

#[derive(Deserialize)]
struct ClaudeUsage {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_creation_input_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
    cache_creation: Option<CacheCreation>,
    service_tier: Option<String>,
    server_tool_use: Option<ServerToolUse>,
    inference_geo: Option<Value>,
    speed: Option<Value>,
}

#[derive(Deserialize)]
struct CacheCreation {
    ephemeral_1h_input_tokens: Option<u64>,
}

#[derive(Deserialize)]
struct ServerToolUse {
    web_search_requests: Option<u64>,
}

#[derive(Deserialize)]
struct CodexLine {
    timestamp: Option<String>,
    #[serde(rename = "type")]
    kind: Option<String>,
    payload: Option<CodexPayload>,
}

#[derive(Deserialize)]
struct CodexPayload {
    #[serde(rename = "type")]
    kind: Option<String>,
    id: Option<String>,
    session_id: Option<String>,
    cwd: Option<String>,
    model: Option<String>,
    info: Option<CodexInfo>,
    rate_limits: Option<Value>,
}

#[derive(Deserialize)]
struct CodexInfo {
    total_token_usage: Option<CodexTokens>,
    last_token_usage: Option<CodexTokens>,
}

#[derive(Deserialize)]
struct CodexTokens {
    input_tokens: Option<u64>,
    cached_input_tokens: Option<u64>,
    output_tokens: Option<u64>,
}

impl CodexTokens {
    fn triple(&self) -> [u64; 3] {
        [self.input_tokens.unwrap_or(0), self.cached_input_tokens.unwrap_or(0), self.output_tokens.unwrap_or(0)]
    }
}

#[derive(Deserialize)]
struct Request {
    cache: String,
    #[serde(default)]
    claude: Vec<String>,
    #[serde(default)]
    codex: Vec<String>,
    #[serde(default)]
    now: i64,
    #[serde(default)]
    since: i64,
    #[serde(default)]
    known: u64,
    #[serde(default)]
    release: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Response<'a> {
    generation: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    names: Option<&'a [String]>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rows: Option<Vec<i64>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    limits: Option<&'a Limits>,
    files: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

pub fn fnv(bytes: &[u8]) -> u64 {
    fnv_extend(FNV_OFFSET, bytes)
}

fn fnv_extend(hash: u64, bytes: &[u8]) -> u64 {
    bytes.iter().fold(hash, |hash, byte| (hash ^ u64::from(*byte)).wrapping_mul(FNV_PRIME))
}

fn fnv_parts(parts: &[&[u8]]) -> u64 {
    parts.iter().fold(FNV_OFFSET, |hash, part| fnv_extend(fnv_extend(hash, part), &[0]))
}

fn digits(text: &str, start: usize, len: usize) -> Option<i64> {
    let slice = text.get(start..start + len)?;
    slice.bytes().all(|byte| byte.is_ascii_digit()).then(|| slice.parse().ok()).flatten()
}

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let day_of_year = (153 * ((month + 9) % 12) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

pub fn parse_timestamp(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.len() < 19 || bytes[4] != b'-' || bytes[7] != b'-' || !matches!(bytes[10], b'T' | b't' | b' ') || bytes[13] != b':' || bytes[16] != b':' {
        return None;
    }
    let (year, month, day) = (digits(text, 0, 4)?, digits(text, 5, 2)?, digits(text, 8, 2)?);
    let (hour, minute, second) = (digits(text, 11, 2)?, digits(text, 14, 2)?, digits(text, 17, 2)?);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    let mut rest = &text[19..];
    if let Some(fraction) = rest.strip_prefix('.') {
        rest = fraction.trim_start_matches(|ch: char| ch.is_ascii_digit());
    }
    let offset = match rest {
        "" | "Z" | "z" => 0,
        zone => {
            let sign = match zone.as_bytes()[0] {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            let clock = zone[1..].replace(':', "");
            if clock.len() != 4 {
                return None;
            }
            sign * (digits(&clock, 0, 2)? * 3600 + digits(&clock, 2, 2)? * 60)
        }
    };
    Some(days_from_civil(year, month, day) * DAY + hour * 3600 + minute * 60 + second - offset)
}

fn folder_name(path: &str) -> String {
    Path::new(path).file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default()
}

fn parent_session(path: &Path) -> Option<String> {
    let folder = path.parent()?;
    (folder.file_name()? == "subagents").then(|| folder.parent()?.file_name().map(|name| name.to_string_lossy().into_owned())).flatten()
}

fn collect_logs(dir: &Path, agent: Agent, out: &mut Vec<(String, Agent)>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let Ok(kind) = entry.file_type() else { continue };
        let path = entry.path();
        if kind.is_dir() {
            collect_logs(&path, agent, out);
        } else if kind.is_file() && path.extension().is_some_and(|extension| extension == "jsonl") {
            out.push((path.to_string_lossy().into_owned(), agent));
        }
    }
}

fn read_range(file: &File, start: u64, len: u64) -> Option<Vec<u8>> {
    let mut buffer = vec![0u8; usize::try_from(len).ok()?];
    file.read_exact_at(&mut buffer, start).ok()?;
    Some(buffer)
}

fn edges(file: &File, offset: u64) -> Option<(u64, u64)> {
    let span = offset.min(EDGE_BYTES);
    Some((fnv(&read_range(file, 0, span)?), fnv(&read_range(file, offset - span, span)?)))
}

fn scan_lines(file: &mut File, start: u64, chunk: &mut [u8], mut on_line: impl FnMut(&[u8])) -> u64 {
    if file.seek(SeekFrom::Start(start)).is_err() {
        return start;
    }
    let mut carry: Vec<u8> = Vec::new();
    let mut offset = start;
    loop {
        let read = match file.read(chunk) {
            Ok(0) => break,
            Ok(read) => read,
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        let mut data = &chunk[..read];
        if !carry.is_empty() {
            let Some(end) = memchr::memchr(b'\n', data) else {
                carry.extend_from_slice(data);
                continue;
            };
            carry.extend_from_slice(&data[..end]);
            on_line(&carry);
            offset += carry.len() as u64 + 1;
            carry.clear();
            data = &data[end + 1..];
        }
        let mut begin = 0;
        for end in memchr::memchr_iter(b'\n', data) {
            on_line(&data[begin..end]);
            begin = end + 1;
        }
        offset += begin as u64;
        carry.extend_from_slice(&data[begin..]);
    }
    offset
}

fn claude_tier(usage: &ClaudeUsage) -> String {
    let geo = usage.inference_geo.as_ref().and_then(Value::as_str).filter(|geo| !matches!(*geo, "" | "global" | "not_available"));
    let speed = usage.speed.as_ref().and_then(Value::as_str).filter(|speed| !matches!(*speed, "" | "standard"));
    let mut tier = usage.service_tier.clone().unwrap_or_default();
    for extra in [geo, speed].into_iter().flatten() {
        tier.push('/');
        tier.push_str(extra);
    }
    tier
}

fn claude_found(line: &[u8], session: Option<&str>, cutoff: i64) -> Option<Found> {
    let entry: ClaudeLine = serde_json::from_slice(line).ok()?;
    if entry.kind.as_deref() != Some("assistant") {
        return None;
    }
    let message = entry.message?;
    let model = message.model.filter(|model| !model.starts_with('<'))?;
    let usage = message.usage?;
    let id = message.id?;
    let ts = parse_timestamp(entry.timestamp.as_deref()?)?;
    if ts < cutoff {
        return None;
    }
    let written = usage.cache_creation_input_tokens.unwrap_or(0);
    let written_1h = usage.cache_creation.as_ref().and_then(|creation| creation.ephemeral_1h_input_tokens).unwrap_or(0).min(written);
    let request = entry.request_id.unwrap_or_default();
    Some(Found {
        key: fnv_parts(&[b"claude", id.as_bytes(), request.as_bytes()]),
        ts,
        agent: Agent::Claude,
        model,
        project: entry.cwd.as_deref().map(folder_name).unwrap_or_default(),
        session: session.map(str::to_string).or(entry.session_id).unwrap_or_default(),
        tier: claude_tier(&usage),
        tokens: Tokens {
            input: usage.input_tokens.unwrap_or(0),
            output: usage.output_tokens.unwrap_or(0),
            cache_read: usage.cache_read_input_tokens.unwrap_or(0),
            cache_write_5m: written - written_1h,
            cache_write_1h: written_1h,
            web_searches: usage.server_tool_use.as_ref().and_then(|tools| tools.web_search_requests).unwrap_or(0),
        },
    })
}

fn codex_delta(previous: Option<[u64; 3]>, total: Option<[u64; 3]>, last: Option<[u64; 3]>) -> Option<[u64; 3]> {
    match (previous, total) {
        (Some(before), Some(now)) if (0..3).all(|index| now[index] >= before[index]) => {
            Some(std::array::from_fn(|index| now[index] - before[index]))
        }
        _ => last.or(total),
    }
}

fn limit_window(value: Option<&Value>) -> Option<LimitWindow> {
    let value = value?;
    Some(LimitWindow {
        used_percent: value.get("used_percent")?.as_f64()?,
        window_minutes: value.get("window_minutes").and_then(Value::as_u64),
        resets_at: value.get("resets_at").and_then(Value::as_i64),
    })
}

fn codex_line(line: &[u8], state: &mut FileState, cutoff: i64, found: &mut Vec<Found>, limits: &mut Option<Limits>) {
    let Ok(entry) = serde_json::from_slice::<CodexLine>(line) else { return };
    let Some(payload) = entry.payload else { return };
    match (entry.kind.as_deref(), payload.kind.as_deref()) {
        (Some("session_meta"), _) => {
            if let Some(id) = payload.id.or(payload.session_id) {
                state.session = id;
            }
            if let Some(cwd) = payload.cwd {
                state.project = folder_name(&cwd);
            }
        }
        (Some("turn_context"), _) => {
            if let Some(model) = payload.model {
                state.model = model;
            }
            if let Some(cwd) = payload.cwd {
                state.project = folder_name(&cwd);
            }
        }
        (Some("event_msg"), Some("token_count")) => {
            let Some(stamp) = entry.timestamp else { return };
            let Some(ts) = parse_timestamp(&stamp) else { return };
            if let Some(rates) = payload.rate_limits {
                let observed = Limits { observed_at: ts, primary: limit_window(rates.get("primary")), secondary: limit_window(rates.get("secondary")) };
                let newer = limits.as_ref().is_none_or(|current| ts >= current.observed_at);
                if newer && (observed.primary.is_some() || observed.secondary.is_some()) {
                    *limits = Some(observed);
                }
            }
            let Some(info) = payload.info else { return };
            let total = info.total_token_usage.as_ref().map(CodexTokens::triple);
            let last = info.last_token_usage.as_ref().map(CodexTokens::triple);
            let delta = codex_delta(state.totals, total, last);
            if total.is_some() {
                state.totals = total;
            }
            let Some([input, cached, output]) = delta else { return };
            if input + cached + output == 0 || ts < cutoff {
                return;
            }
            let identity = format!("{:?}", total.or(last));
            found.push(Found {
                key: fnv_parts(&[b"codex", stamp.as_bytes(), identity.as_bytes()]),
                ts,
                agent: Agent::Codex,
                model: state.model.clone(),
                project: state.project.clone(),
                session: state.session.clone(),
                tier: String::new(),
                tokens: Tokens { input: input.saturating_sub(cached), output, cache_read: cached, ..Tokens::default() },
            });
        }
        _ => {}
    }
}

fn scan_file(path: &str, agent: Agent, previous: Option<&Cursor>, cutoff: i64, chunk: &mut [u8]) -> Option<Scan> {
    let meta = fs::metadata(path).ok()?;
    if previous.is_some_and(|cursor| cursor.inode == meta.ino() && cursor.offset == meta.len()) {
        return None;
    }
    let mut file = File::open(path).ok()?;
    let resumed = previous.filter(|cursor| {
        cursor.inode == meta.ino() && cursor.offset < meta.len() && edges(&file, cursor.offset) == Some((cursor.head, cursor.tail))
    });
    let start = resumed.map_or(0, |cursor| cursor.offset);
    let mut state = resumed.map(|cursor| cursor.state.clone()).unwrap_or_default();
    let mut found = Vec::new();
    let mut limits = None;
    let offset = match agent {
        Agent::Claude => {
            let session = parent_session(Path::new(path));
            let (usage, assistant) = (Finder::new(b"\"usage\""), Finder::new(b"\"assistant\""));
            scan_lines(&mut file, start, chunk, |line| {
                if usage.find(line).is_some() && assistant.find(line).is_some() {
                    found.extend(claude_found(line, session.as_deref(), cutoff));
                }
            })
        }
        Agent::Codex => {
            let markers = [Finder::new(b"\"token_count\""), Finder::new(b"\"turn_context\""), Finder::new(b"\"session_meta\"")];
            scan_lines(&mut file, start, chunk, |line| {
                if markers.iter().any(|marker| marker.find(line).is_some()) {
                    codex_line(line, &mut state, cutoff, &mut found, &mut limits);
                }
            })
        }
    };
    let (head, tail) = edges(&file, offset)?;
    Some(Scan { path: path.to_string(), cursor: Cursor { inode: meta.ino(), offset, head, tail, state }, found, limits })
}

fn load(path: &Path) -> Option<Store> {
    let bytes = fs::read(path).ok()?;
    let split = memchr::memchr(b'\n', &bytes)?;
    let (magic, checksum) = std::str::from_utf8(&bytes[..split]).ok()?.split_once(' ')?;
    let payload = &bytes[split + 1..];
    if magic != CACHE_MAGIC || u64::from_str_radix(checksum, 16).ok()? != fnv(payload) {
        return None;
    }
    let store: Store = serde_json::from_slice(payload).ok()?;
    (store.version == CACHE_VERSION).then_some(store)
}

impl Ingest {
    pub fn open(path: PathBuf) -> Ingest {
        let store = load(&path).unwrap_or_default();
        let index = store.names.iter().enumerate().map(|(id, name)| (name.clone(), id as u32)).collect();
        Ingest { path, store, index, generation: 1, dirty: false, saved_at: None }
    }

    pub fn update(&mut self, sources: &[(PathBuf, Agent)], now: i64) {
        let cutoff = now - RETENTION_DAYS * DAY;
        let mut files = Vec::new();
        for (root, agent) in sources {
            collect_logs(root, *agent, &mut files);
        }
        files.sort();
        let cursors = &self.store.cursors;
        let scans: Vec<Scan> = files
            .par_iter()
            .map_init(|| vec![0u8; CHUNK_BYTES], |chunk, (path, agent)| scan_file(path, *agent, cursors.get(path), cutoff, chunk))
            .flatten()
            .collect();
        let live: HashSet<&String> = files.iter().map(|(path, _)| path).collect();
        let tracked = self.store.cursors.len();
        self.store.cursors.retain(|path, _| live.contains(path));
        self.dirty |= self.store.cursors.len() != tracked;
        let mut changed = false;
        for scan in scans {
            changed |= self.absorb(scan);
        }
        let count = self.store.records.len();
        self.store.records.retain(|_, record| record.ts >= cutoff);
        changed |= self.store.records.len() != count;
        if changed {
            self.generation += 1;
            self.dirty = true;
        }
    }

    fn absorb(&mut self, scan: Scan) -> bool {
        let mut changed = false;
        for found in scan.found {
            changed |= self.merge(found);
        }
        if let Some(limits) = scan.limits {
            let newer = self.store.limits.as_ref().is_none_or(|current| limits.observed_at >= current.observed_at);
            if newer && self.store.limits.as_ref() != Some(&limits) {
                self.store.limits = Some(limits);
                changed = true;
            }
        }
        self.store.cursors.insert(scan.path, scan.cursor);
        self.dirty = true;
        changed
    }

    fn intern(&mut self, name: &str) -> u32 {
        if let Some(id) = self.index.get(name) {
            return *id;
        }
        let id = self.store.names.len() as u32;
        self.store.names.push(name.to_string());
        self.index.insert(name.to_string(), id);
        id
    }

    fn merge(&mut self, found: Found) -> bool {
        let record = Record {
            ts: found.ts,
            agent: found.agent as u8,
            model: self.intern(&found.model),
            project: self.intern(&found.project),
            session: self.intern(&found.session),
            tier: self.intern(&found.tier),
            tokens: found.tokens,
        };
        match self.store.records.entry(found.key) {
            Entry::Vacant(slot) => {
                slot.insert(record);
                true
            }
            Entry::Occupied(mut slot) => {
                let merged = slot.get().merged(record);
                let changed = merged != *slot.get();
                slot.insert(merged);
                changed
            }
        }
    }

    pub fn names(&self) -> &[String] {
        &self.store.names
    }

    pub fn limits(&self) -> Option<&Limits> {
        self.store.limits.as_ref()
    }

    pub fn files(&self) -> usize {
        self.store.cursors.len()
    }

    pub fn records(&self) -> usize {
        self.store.records.len()
    }

    pub fn rows(&self, since: i64) -> Vec<i64> {
        let mut groups: HashMap<RowKey, (i64, Tokens, i64)> = HashMap::new();
        for record in self.store.records.values().filter(|record| record.ts >= since) {
            let key = (record.ts.div_euclid(MINUTE), record.agent, record.model, record.project, record.session, record.tier);
            let group = groups.entry(key).or_insert((record.ts, Tokens::default(), 0));
            group.0 = group.0.min(record.ts);
            group.1 = group.1.combine(record.tokens, u64::saturating_add);
            group.2 += 1;
        }
        let mut sorted: Vec<_> = groups.into_iter().collect();
        sorted.sort_unstable_by_key(|((_, agent, model, project, session, tier), (ts, _, _))| (*ts, *agent, *model, *project, *session, *tier));
        let mut flat = Vec::with_capacity(sorted.len() * ROW_WIDTH);
        for ((_, agent, model, project, session, tier), (ts, tokens, requests)) in sorted {
            flat.extend([ts, i64::from(agent), i64::from(model), i64::from(project), i64::from(session), i64::from(tier)]);
            flat.extend(<[u64; 6]>::from(tokens).map(|value| i64::try_from(value).unwrap_or(i64::MAX)));
            flat.push(requests);
        }
        flat
    }

    pub fn save(&mut self, now: i64) -> std::io::Result<()> {
        self.store.version = CACHE_VERSION;
        let payload = serde_json::to_vec(&self.store)?;
        if let Some(folder) = self.path.parent() {
            fs::create_dir_all(folder)?;
        }
        let temp = self.path.with_extension("tmp");
        let mut file = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&temp)?;
        file.write_all(format!("{CACHE_MAGIC} {:016x}\n", fnv(&payload)).as_bytes())?;
        file.write_all(&payload)?;
        fs::rename(&temp, &self.path)?;
        self.dirty = false;
        self.saved_at = Some(now);
        Ok(())
    }

    pub fn save_if_due(&mut self, now: i64) -> std::io::Result<()> {
        if self.dirty && self.saved_at.is_none_or(|saved| now - saved >= SAVE_INTERVAL) {
            self.save(now)
        } else {
            Ok(())
        }
    }
}

fn reply(response: &Response) -> String {
    serde_json::to_string(response).unwrap_or_else(|error| format!("{{\"generation\":0,\"files\":0,\"error\":{}}}", crate::json_string(&error.to_string())))
}

fn empty(error: Option<String>) -> String {
    reply(&Response { generation: 0, names: None, rows: None, limits: None, files: 0, error })
}

pub fn handle(request: &str) -> String {
    let request: Request = match serde_json::from_str(request) {
        Ok(request) => request,
        Err(error) => return empty(Some(format!("Bad usage request: {error}"))),
    };
    let mut states = STATES.lock().unwrap_or_else(PoisonError::into_inner);
    if request.release {
        let error = states.remove(&request.cache).and_then(|mut state| if state.dirty { state.save(request.now).err() } else { None });
        return empty(error.map(|error| format!("Could not save the usage cache: {error}")));
    }
    let state = states.entry(request.cache.clone()).or_insert_with(|| Ingest::open(PathBuf::from(&request.cache)));
    let sources: Vec<(PathBuf, Agent)> = request
        .claude
        .iter()
        .map(|root| (PathBuf::from(root), Agent::Claude))
        .chain(request.codex.iter().map(|root| (PathBuf::from(root), Agent::Codex)))
        .collect();
    state.update(&sources, request.now);
    let error = state.save_if_due(request.now).err().map(|error| format!("Could not save the usage cache: {error}"));
    let rows = (state.generation != request.known).then(|| state.rows(request.since));
    let response = Response {
        generation: state.generation,
        names: rows.is_some().then(|| state.names()),
        rows,
        limits: state.limits(),
        files: state.files(),
        error,
    };
    reply(&response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::ffi::{CStr, CString};

    const NOW: i64 = 1_794_312_000;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mackit-usage-{}-{}", name, std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_lines(path: &Path, lines: &[String]) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, lines.iter().map(|line| format!("{line}\n")).collect::<String>()).unwrap();
    }

    fn append(path: &Path, text: &str) {
        OpenOptions::new().append(true).open(path).unwrap().write_all(text.as_bytes()).unwrap();
    }

    fn usage(input: u64, output: u64, read: u64, written: u64, written_1h: u64) -> Value {
        json!({
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_input_tokens": read,
            "cache_creation_input_tokens": written,
            "cache_creation": { "ephemeral_1h_input_tokens": written_1h, "ephemeral_5m_input_tokens": written - written_1h },
            "service_tier": "standard",
            "server_tool_use": { "web_search_requests": 0 },
            "inference_geo": "global",
            "speed": "standard"
        })
    }

    fn assistant(id: &str, time: &str, model: &str, usage: Value) -> String {
        json!({
            "type": "assistant",
            "timestamp": time,
            "sessionId": "s-main",
            "requestId": format!("req-{id}"),
            "cwd": "/Users/me/code/mackit",
            "message": { "id": id, "model": model, "role": "assistant", "content": [{ "type": "text", "text": "x".repeat(300) }], "usage": usage }
        })
        .to_string()
    }

    fn codex(time: &str, kind: &str, payload: Value) -> String {
        json!({ "timestamp": time, "type": kind, "payload": payload }).to_string()
    }

    fn token_count(time: &str, total: [u64; 3], last: [u64; 3], used: f64) -> String {
        let tokens = |[input, cached, output]: [u64; 3]| json!({ "input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": 0, "total_tokens": input + output });
        codex(time, "event_msg", json!({
            "type": "token_count",
            "info": { "total_token_usage": tokens(total), "last_token_usage": tokens(last), "model_context_window": 272000 },
            "rate_limits": {
                "primary": { "used_percent": used, "window_minutes": 300, "resets_at": NOW + 3600 },
                "secondary": { "used_percent": 4.0, "window_minutes": 10080, "resets_at": NOW + 86_400 }
            }
        }))
    }

    fn records(ingest: &Ingest) -> Vec<(String, Record)> {
        let mut list: Vec<(String, Record)> = ingest.store.records.values().map(|record| (ingest.names()[record.model as usize].clone(), *record)).collect();
        list.sort_by_key(|(_, record)| record.ts);
        list
    }

    fn claude_sources(root: &Path) -> Vec<(PathBuf, Agent)> {
        vec![(root.join("projects"), Agent::Claude)]
    }

    #[test]
    fn parses_timestamps_in_utc_and_with_offsets() {
        assert_eq!(parse_timestamp("2026-11-10T12:00:00Z"), Some(NOW));
        assert_eq!(parse_timestamp("2026-11-10T12:00:00.123Z"), Some(NOW));
        assert_eq!(parse_timestamp("2026-11-10T19:00:00+07:00"), Some(NOW));
        assert_eq!(parse_timestamp("2026-11-10T07:30:00-0430"), Some(NOW));
        assert_eq!(parse_timestamp("2000-02-29T23:59:59.999Z"), Some(951_868_799));
        assert_eq!(parse_timestamp("1969-12-31T23:59:59Z"), Some(-1));
        for bad in ["2026-13-01T00:00:00Z", "yesterday", "2026-11-10", "2026-11-10T12:00:00+7", "2026-11-10T12:00:00 nope", "+026-11-10T12:00:00Z"] {
            assert_eq!(parse_timestamp(bad), None, "{bad}");
        }
    }

    #[test]
    fn counts_streamed_claude_chunks_once_with_the_largest_usage() {
        let root = scratch("claude");
        let project = root.join("projects/-Users-me-code-mackit");
        let mut searched = usage(5, 7, 0, 0, 0);
        searched["server_tool_use"]["web_search_requests"] = json!(2);
        write_lines(&project.join("s-main.jsonl"), &[
            json!({ "type": "user", "timestamp": "2026-11-10T10:59:00Z", "message": { "role": "user", "content": "what is \"usage\" for the assistant" } }).to_string(),
            assistant("msg-1", "2026-11-10T11:00:00.000Z", "claude-opus-5-5", usage(10, 1, 100, 50, 20)),
            assistant("msg-1", "2026-11-10T11:00:02.000Z", "claude-opus-5-5", usage(10, 40, 100, 50, 20)),
            assistant("msg-2", "2026-11-10T11:05:00.000Z", "claude-sonnet-5-5", searched),
            assistant("msg-3", "2026-11-10T11:06:00.000Z", "<synthetic>", usage(1, 1, 0, 0, 0)),
            assistant("msg-4", "2026-08-01T11:06:00.000Z", "claude-opus-5-5", usage(1, 1, 0, 0, 0)),
        ]);
        let mut sub = json!({ "type": "assistant", "timestamp": "2026-11-10T11:07:00Z", "sessionId": "agent-own", "requestId": "req-sub", "cwd": "/Users/me/code/mackit" });
        sub["message"] = json!({ "id": "msg-sub", "model": "claude-haiku-5-5", "usage": usage(3, 4, 0, 0, 0) });
        write_lines(&project.join("s-main/subagents/agent-a1.jsonl"), &[sub.to_string()]);
        let mut ingest = Ingest::open(root.join("cache"));
        ingest.update(&claude_sources(&root), NOW);
        let found = records(&ingest);
        assert_eq!(found.iter().map(|(model, _)| model.as_str()).collect::<Vec<_>>(), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]);
        let (_, first) = found[0];
        assert_eq!(first.ts, NOW - 3600);
        assert_eq!(first.tokens, Tokens { input: 10, output: 40, cache_read: 100, cache_write_5m: 30, cache_write_1h: 20, web_searches: 0 });
        assert_eq!(found[1].1.tokens.web_searches, 2);
        assert_eq!(ingest.names()[first.project as usize], "mackit");
        assert_eq!(ingest.names()[first.tier as usize], "standard");
        assert_eq!(ingest.names()[found[2].1.session as usize], "s-main");
        assert_eq!(ingest.files(), 2);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn marks_regional_and_fast_requests_as_a_different_tier() {
        let parse = |geo: &str, speed: &str| {
            let mut value = usage(1, 1, 0, 0, 0);
            value["inference_geo"] = json!(geo);
            value["speed"] = json!(speed);
            claude_tier(&serde_json::from_value(value).unwrap())
        };
        assert_eq!(parse("global", "standard"), "standard");
        assert_eq!(parse("not_available", "standard"), "standard");
        assert_eq!(parse("us", "standard"), "standard/us");
        assert_eq!(parse("global", "fast"), "standard/fast");
    }

    #[test]
    fn reads_only_appended_lines_and_waits_for_a_finished_line() {
        let root = scratch("append");
        let log = root.join("projects/p/s.jsonl");
        write_lines(&log, &[assistant("a", "2026-11-10T11:00:00Z", "claude-opus-5-5", usage(1, 1, 0, 0, 0))]);
        let mut ingest = Ingest::open(root.join("cache"));
        ingest.update(&claude_sources(&root), NOW);
        assert_eq!((ingest.records(), ingest.generation), (1, 2));
        let partial = assistant("c", "2026-11-10T11:02:00Z", "claude-opus-5-5", usage(3, 3, 0, 0, 0));
        let (head, rest) = partial.split_at(40);
        append(&log, &format!("{}\n{head}", assistant("b", "2026-11-10T11:01:00Z", "claude-opus-5-5", usage(2, 2, 0, 0, 0))));
        ingest.update(&claude_sources(&root), NOW);
        assert_eq!(ingest.records(), 2);
        let cursor = &ingest.store.cursors[&log.to_string_lossy().into_owned()];
        assert_eq!(cursor.offset, fs::metadata(&log).unwrap().len() - head.len() as u64);
        ingest.update(&claude_sources(&root), NOW);
        assert_eq!(ingest.generation, 3);
        append(&log, &format!("{rest}\n"));
        ingest.update(&claude_sources(&root), NOW);
        assert_eq!((ingest.records(), ingest.generation), (3, 4));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn rereads_a_rewritten_file_from_the_start() {
        let root = scratch("rewrite");
        let log = root.join("projects/p/s.jsonl");
        write_lines(&log, &[assistant("a", "2026-11-10T11:00:00Z", "claude-opus-5-5", usage(1, 1, 0, 0, 0))]);
        let mut ingest = Ingest::open(root.join("cache"));
        ingest.update(&claude_sources(&root), NOW);
        let mut long = usage(2, 2, 0, 0, 0);
        long["note"] = json!("y".repeat(2000));
        write_lines(&log, &[
            assistant("b", "2026-11-10T11:01:00Z", "claude-sonnet-5-5", long),
            assistant("c", "2026-11-10T11:02:00Z", "claude-sonnet-5-5", usage(3, 3, 0, 0, 0)),
        ]);
        ingest.update(&claude_sources(&root), NOW);
        let models: Vec<String> = records(&ingest).into_iter().map(|(model, _)| model).collect();
        assert_eq!(models, ["claude-opus-5-5", "claude-sonnet-5-5", "claude-sonnet-5-5"]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn takes_codex_deltas_without_cached_input_and_follows_the_model_and_limits() {
        let root = scratch("codex");
        let sessions = root.join("sessions");
        let log = sessions.join("2026/11/10/rollout-a.jsonl");
        write_lines(&log, &[
            codex("2026-11-10T10:00:00.000Z", "session_meta", json!({ "id": "codex-1", "cwd": "/Users/me/code/api", "instructions": "\"token_count\"" })),
            codex("2026-11-10T10:00:01.000Z", "turn_context", json!({ "cwd": "/Users/me/code/api", "model": "gpt-5.1-codex" })),
            codex("2026-11-10T10:00:02.000Z", "event_msg", json!({ "type": "token_count", "info": null, "rate_limits": { "primary": { "used_percent": 10.0, "window_minutes": 300, "resets_at": NOW } } })),
            token_count("2026-11-10T10:01:00.000Z", [1000, 600, 50], [1000, 600, 50], 11.0),
            token_count("2026-11-10T10:01:01.000Z", [1000, 600, 50], [1000, 600, 50], 11.0),
            codex("2026-11-10T10:02:00.000Z", "turn_context", json!({ "cwd": "/Users/me/code/api", "model": "gpt-5.2-codex" })),
            token_count("2026-11-10T10:03:00.000Z", [1500, 900, 80], [500, 300, 30], 12.5),
        ]);
        let archive = root.join("archived_sessions");
        let sources = vec![(sessions.clone(), Agent::Codex), (archive.clone(), Agent::Codex)];
        let mut ingest = Ingest::open(root.join("cache"));
        ingest.update(&sources, NOW);
        let found = records(&ingest);
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].0, "gpt-5.1-codex");
        assert_eq!(found[0].1.tokens, Tokens { input: 400, output: 50, cache_read: 600, ..Tokens::default() });
        assert_eq!(found[1].0, "gpt-5.2-codex");
        assert_eq!(found[1].1.tokens, Tokens { input: 200, output: 30, cache_read: 300, ..Tokens::default() });
        assert_eq!(ingest.names()[found[1].1.project as usize], "api");
        assert_eq!(ingest.names()[found[1].1.session as usize], "codex-1");
        let limits = ingest.limits().unwrap();
        assert_eq!(limits.observed_at, NOW - 2 * 3600 + 180);
        assert_eq!(limits.primary, Some(LimitWindow { used_percent: 12.5, window_minutes: Some(300), resets_at: Some(NOW + 3600) }));
        assert_eq!(limits.secondary.as_ref().map(|window| window.window_minutes), Some(Some(10080)));
        fs::create_dir_all(&archive).unwrap();
        fs::rename(&log, archive.join("rollout-a.jsonl")).unwrap();
        let generation = ingest.generation;
        ingest.update(&sources, NOW);
        assert_eq!((ingest.records(), ingest.files(), ingest.generation), (2, 1, generation));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn codex_delta_falls_back_to_the_last_response_when_totals_restart() {
        assert_eq!(codex_delta(None, Some([9000, 100, 900]), Some([10, 1, 2])), Some([10, 1, 2]));
        assert_eq!(codex_delta(Some([100, 10, 5]), Some([150, 30, 9]), Some([1, 1, 1])), Some([50, 20, 4]));
        assert_eq!(codex_delta(Some([100, 10, 5]), Some([20, 0, 1]), Some([20, 0, 1])), Some([20, 0, 1]));
        assert_eq!(codex_delta(Some([100, 10, 5]), None, Some([7, 0, 1])), Some([7, 0, 1]));
        assert_eq!(codex_delta(None, None, None), None);
    }

    #[test]
    fn the_cache_survives_a_restart_keeps_deleted_logs_and_rejects_corruption() {
        let root = scratch("cache");
        let cache = root.join("support/ai-usage.cache");
        let log = root.join("projects/p/s.jsonl");
        write_lines(&log, &[assistant("a", "2026-11-10T11:00:00Z", "claude-opus-5-5", usage(1, 1, 0, 0, 0))]);
        let mut ingest = Ingest::open(cache.clone());
        ingest.update(&claude_sources(&root), NOW);
        ingest.save_if_due(NOW).unwrap();
        assert!(cache.exists());
        let mut reopened = Ingest::open(cache.clone());
        assert_eq!((reopened.records(), reopened.files()), (1, 1));
        reopened.update(&claude_sources(&root), NOW + 60);
        assert_eq!(reopened.generation, 1);
        append(&log, &format!("{}\n", assistant("b", "2026-11-10T11:01:00Z", "claude-opus-5-5", usage(2, 2, 0, 0, 0))));
        reopened.update(&claude_sources(&root), NOW + 60);
        assert_eq!((reopened.records(), reopened.generation), (2, 2));
        reopened.save(NOW + 60).unwrap();
        fs::remove_file(&log).unwrap();
        let mut history = Ingest::open(cache.clone());
        history.update(&claude_sources(&root), NOW + 120);
        assert_eq!((history.records(), history.files()), (2, 0));
        let mut bytes = fs::read(&cache).unwrap();
        let last = bytes.len() - 2;
        bytes[last] ^= 1;
        fs::write(&cache, bytes).unwrap();
        assert_eq!(Ingest::open(cache).records(), 0);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn drops_history_older_than_the_retention_window() {
        let root = scratch("retention");
        write_lines(&root.join("projects/p/s.jsonl"), &[assistant("a", "2026-11-10T11:00:00Z", "claude-opus-5-5", usage(1, 1, 0, 0, 0))]);
        let mut ingest = Ingest::open(root.join("cache"));
        ingest.update(&claude_sources(&root), NOW);
        assert_eq!(ingest.records(), 1);
        ingest.update(&claude_sources(&root), NOW + (RETENTION_DAYS + 1) * DAY);
        assert_eq!((ingest.records(), ingest.generation), (0, 3));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn groups_requests_into_minute_rows() {
        let root = scratch("rows");
        write_lines(&root.join("projects/p/s.jsonl"), &[
            assistant("a", "2026-11-10T11:00:10Z", "claude-opus-5-5", usage(1, 2, 3, 4, 1)),
            assistant("b", "2026-11-10T11:00:50Z", "claude-opus-5-5", usage(10, 20, 30, 40, 10)),
            assistant("c", "2026-11-10T11:01:05Z", "claude-opus-5-5", usage(100, 0, 0, 0, 0)),
        ]);
        let mut ingest = Ingest::open(root.join("cache"));
        ingest.update(&claude_sources(&root), NOW);
        let rows = ingest.rows(0);
        assert_eq!(rows.len(), 2 * ROW_WIDTH);
        assert_eq!(rows[0], NOW - 3600 + 10);
        assert_eq!(&rows[6..13], &[11, 22, 33, 33, 11, 0, 2]);
        assert_eq!(rows[ROW_WIDTH], NOW - 3600 + 65);
        assert_eq!(rows[ROW_WIDTH + 12], 1);
        assert!(ingest.rows(NOW - 3600 + 60).len() == ROW_WIDTH);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn the_c_interface_returns_rows_once_per_generation_and_releases_state() {
        let root = scratch("ffi");
        write_lines(&root.join("claude/p/s.jsonl"), &[assistant("a", "2026-11-10T11:00:00Z", "claude-opus-5-5", usage(1, 1, 0, 0, 0))]);
        let cache = root.join("support/ai-usage.cache");
        let call = |request: Value| -> Value {
            let text = CString::new(request.to_string()).unwrap();
            let raw = crate::mk_ai_usage(text.as_ptr());
            let reply = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_string();
            crate::mk_string_free(raw);
            serde_json::from_str(&reply).unwrap()
        };
        let request = |known: u64, release: bool| json!({
            "cache": cache.to_string_lossy(), "claude": [root.join("claude").to_string_lossy()], "codex": [root.join("missing").to_string_lossy()],
            "now": NOW, "since": NOW - 31 * DAY, "known": known, "release": release
        });
        let first = call(request(0, false));
        assert_eq!(first["files"], 1);
        assert_eq!(first["rows"].as_array().unwrap().len(), ROW_WIDTH);
        assert!(first["names"].as_array().unwrap().iter().any(|name| name == "claude-opus-5-5"));
        assert!(cache.exists());
        let generation = first["generation"].as_u64().unwrap();
        let second = call(request(generation, false));
        assert!(second.get("rows").is_none() && second.get("names").is_none());
        assert_eq!(second["generation"].as_u64(), Some(generation));
        let released = call(request(generation, true));
        assert!(released.get("error").is_none());
        assert!(!STATES.lock().unwrap().contains_key(&cache.to_string_lossy().into_owned()));
        assert!(call(json!({ "cache": 5 }))["error"].as_str().unwrap().starts_with("Bad usage request"));
        fs::remove_dir_all(root).unwrap();
    }
}
