use std::sync::OnceLock;

pub const SYSTEM_WORDS: &str = "/usr/share/dict/words";
const ALWAYS_ENGLISH: &[&str] = &[
    "as", "is", "if", "of", "us", "has", "his", "was", "its", "this", "does", "goes", "yes", "gas", "bus", "plus", "thus", "os", "ox",
];
const SUFFIXES: &[&str] = &["ies", "es", "s", "ed", "ing", "er", "ly"];
const MODERN: &[&str] = &[
    "google", "email", "online", "offline", "website", "iphone", "ipad", "macbook", "airpods", "wifi", "android", "login", "logout",
    "signup", "username", "password", "hashtag", "emoji", "laptop", "smartphone", "startup", "update", "feedback", "internet", "blog",
    "vlog", "podcast", "playlist", "youtube", "tiktok", "shopee", "lazada", "zalo", "grab", "netflix", "spotify", "instagram",
    "facebook", "messenger", "telegram", "slack", "discord", "notion", "figma", "github", "gitlab", "docker", "kubernetes", "redis",
    "postgres", "mongodb", "firebase", "vercel", "deploy", "repo", "commit", "rebase", "merge", "refactor", "debug", "backend",
    "frontend", "fullstack", "devops", "server", "serverless", "database", "api", "json", "yaml", "config", "localhost", "browser",
    "chrome", "safari", "firefox", "macos", "windows", "linux", "ubuntu", "typescript", "javascript", "python", "rust", "swift",
    "kotlin", "react", "vue", "angular", "nextjs", "nodejs", "npm", "yarn", "webpack", "vite", "eslint", "prettier", "jest", "test",
    "tests", "bug", "bugs", "fix", "fixes", "issue", "issues", "sprint", "deadline", "meeting", "standup", "review", "release",
    "pasta", "pizza", "coffee", "latte", "selfie", "video", "videos", "photo", "photos", "screenshot", "download", "upload",
];

static WORDS: OnceLock<Vec<Box<str>>> = OnceLock::new();

pub fn load(text: &str) -> Vec<Box<str>> {
    let mut words: Vec<Box<str>> = text
        .lines()
        .map(str::trim)
        .filter(|word| word.len() >= 2 && word.bytes().all(|byte| byte.is_ascii_alphabetic()))
        .map(|word| word.to_ascii_lowercase().into_boxed_str())
        .collect();
    words.sort_unstable();
    words.dedup();
    words
}

fn system_words() -> &'static [Box<str>] {
    WORDS.get_or_init(|| std::fs::read_to_string(SYSTEM_WORDS).map(|text| load(&text)).unwrap_or_default())
}

pub fn always_english(word: &str) -> bool {
    ALWAYS_ENGLISH.contains(&word.to_lowercase().as_str())
}

pub fn is_english(word: &str) -> bool {
    MODERN.contains(&word.to_lowercase().as_str()) || contains(system_words(), word)
}

pub fn contains(words: &[Box<str>], word: &str) -> bool {
    let word = word.to_lowercase();
    if !word.bytes().all(|byte| byte.is_ascii_alphabetic()) {
        return false;
    }
    let found = |candidate: &str| words.binary_search_by(|entry| entry.as_ref().cmp(candidate)).is_ok();
    found(&word)
        || SUFFIXES.iter().any(|suffix| {
            word.strip_suffix(suffix).is_some_and(|stem| {
                stem.len() >= 2 && (found(stem) || (*suffix == "ies" && found(&format!("{stem}y"))) || found(&format!("{stem}e")))
            })
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_words_and_simple_inflections() {
        let words = load("Window\nthing\nlist\ntest\ncity\ntype\nx\nfoo-bar\n");
        for word in ["window", "windows", "things", "lists", "TEST", "cities", "typed", "typing"] {
            assert!(contains(&words, word), "{word}");
        }
        for word in ["tieeng", "duowc", "x", "s", "foo-bar", "việt"] {
            assert!(!contains(&words, word), "{word}");
        }
        assert!(always_english("Has"));
        assert!(!always_english("hoa"));
    }
}
