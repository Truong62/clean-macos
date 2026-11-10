const EXACT_WORD: i32 = 140;
const WORD_PREFIX: i32 = 80;
const SUBSTRING: i32 = 44;
const IN_ORDER: i32 = 24;
const SWAPPED: i32 = 16;
const ONE_EDIT: i32 = 16;
const TITLE_EXACT: i32 = 1200;
const TITLE_PREFIX: i32 = 900;
const TITLE_CONTAINS: i32 = 700;
const KEYWORDS_CONTAIN: i32 = 350;
const FUZZY_MIN: usize = 3;
const EDIT_MIN: usize = 4;

#[derive(Debug, Clone, PartialEq)]
pub struct Row {
    pub title: String,
    pub keywords: String,
    pub bias: i32,
    pub priority: i32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Ranked {
    pub index: usize,
    pub score: i32,
    pub tier: u8,
    pub priority: i32,
}

pub fn rank(query: &str, rows: &[Row]) -> Vec<Ranked> {
    let query = query.trim();
    let words: Vec<Vec<char>> = query.split_whitespace().map(|word| word.chars().collect()).collect();
    if words.is_empty() {
        return Vec::new();
    }
    let mut ranked: Vec<Ranked> = rows
        .iter()
        .enumerate()
        .filter_map(|(index, row)| score(row, query, &words).map(|(score, tier)| Ranked { index, score: score + row.bias, tier, priority: row.priority }))
        .collect();
    ranked.sort_by(|a, b| b.priority.cmp(&a.priority).then(a.tier.cmp(&b.tier)).then(b.score.cmp(&a.score)).then(a.index.cmp(&b.index)));
    ranked
}

fn score(row: &Row, query: &str, words: &[Vec<char>]) -> Option<(i32, u8)> {
    let haystack = format!("{} {}", row.title, row.keywords);
    let tokens: Vec<Vec<char>> = haystack
        .split(|c: char| !c.is_alphanumeric())
        .filter(|token| !token.is_empty())
        .map(|token| token.chars().collect())
        .collect();
    let mut total = 0;
    for word in words {
        total += word_score(word, &tokens, &haystack)?;
    }
    let (bonus, tier) = if row.title == query {
        (TITLE_EXACT, 0)
    } else if row.title.starts_with(query) {
        (TITLE_PREFIX, 1)
    } else if row.title.contains(query) {
        (TITLE_CONTAINS, 2)
    } else if row.keywords.contains(query) {
        (KEYWORDS_CONTAIN, 3)
    } else {
        (0, 4)
    };
    Some((total + bonus, tier))
}

fn word_score(word: &[char], tokens: &[Vec<char>], haystack: &str) -> Option<i32> {
    if tokens.iter().any(|token| token.as_slice() == word) {
        return Some(EXACT_WORD);
    }
    if tokens.iter().any(|token| token.starts_with(word)) {
        return Some(WORD_PREFIX);
    }
    if haystack.contains(&word.iter().collect::<String>()) {
        return Some(SUBSTRING);
    }
    if word.len() < FUZZY_MIN || word.iter().all(|c| c.is_ascii_digit()) {
        return None;
    }
    if tokens.iter().any(|token| is_subsequence(word, token)) {
        return Some(IN_ORDER);
    }
    if tokens.iter().any(|token| swaps_into(word, token)) {
        return Some(SWAPPED);
    }
    if word.len() >= EDIT_MIN && tokens.iter().any(|token| near_prefix(word, token)) {
        return Some(ONE_EDIT);
    }
    None
}

fn is_subsequence(word: &[char], token: &[char]) -> bool {
    let mut letters = word.iter().peekable();
    for ch in token {
        if letters.peek() == Some(&ch) {
            letters.next();
        }
    }
    letters.peek().is_none()
}

fn swaps_into(word: &[char], token: &[char]) -> bool {
    if token.len() < word.len() {
        return false;
    }
    let prefix = &token[..word.len()];
    (0..word.len().saturating_sub(1)).any(|index| {
        let mut swapped = word.to_vec();
        swapped.swap(index, index + 1);
        swapped == prefix
    })
}

fn near_prefix(word: &[char], token: &[char]) -> bool {
    [word.len().saturating_sub(1), word.len(), word.len() + 1]
        .iter()
        .filter(|&&length| length > 0 && length <= token.len())
        .any(|&length| within_one(word, &token[..length]))
}

fn within_one(a: &[char], b: &[char]) -> bool {
    if a.len() == b.len() {
        let differences: Vec<usize> = (0..a.len()).filter(|&index| a[index] != b[index]).collect();
        return differences.len() <= 1
            || (differences.len() == 2 && differences[1] == differences[0] + 1 && a[differences[0]] == b[differences[1]] && a[differences[1]] == b[differences[0]]);
    }
    let (short, long) = if a.len() < b.len() { (a, b) } else { (b, a) };
    if long.len() - short.len() != 1 {
        return false;
    }
    let split = (0..short.len()).find(|&index| short[index] != long[index]).unwrap_or(short.len());
    short[split..] == long[split + 1..]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(title: &str, keywords: &str) -> Row {
        Row { title: title.to_string(), keywords: keywords.to_string(), bias: 0, priority: 0 }
    }

    fn titles(query: &str, rows: &[Row]) -> Vec<String> {
        rank(query, rows).into_iter().map(|ranked| rows[ranked.index].title.clone()).collect()
    }

    #[test]
    fn prefers_exact_then_prefix_then_contained_titles() {
        let rows = [row("google chrome", "browser"), row("chrome canary", ""), row("chrome", "")];
        assert_eq!(titles("chrome", &rows), ["chrome", "chrome canary", "google chrome"]);
        assert_eq!(rank("chrome", &rows)[0].tier, 0);
    }

    #[test]
    fn needs_every_word() {
        let rows = [row("keep awake", ""), row("keep awake for 30 minutes", "caffeinate")];
        assert_eq!(titles("keep 30", &rows), ["keep awake for 30 minutes"]);
        assert_eq!(titles("awake caff", &rows), ["keep awake for 30 minutes"]);
    }

    #[test]
    fn forgives_small_typos_on_longer_words() {
        let rows = [row("chrome", ""), row("safari", "")];
        assert_eq!(titles("chrm", &rows), ["chrome"]);
        assert_eq!(titles("crhome", &rows), ["chrome"]);
        assert_eq!(titles("chrme", &rows), ["chrome"]);
        assert_eq!(titles("safri", &rows), ["safari"]);
        assert!(titles("xq", &rows).is_empty());
        assert!(titles("123", &[row("12 3", "")]).is_empty());
    }

    #[test]
    fn scores_keywords_bias_and_priority() {
        let mut settings = row("system settings", "preferences control panel");
        let mut slack = row("slack", "chat");
        assert_eq!(rank("prefer", &[settings.clone()])[0].tier, 3);
        settings.bias = 80;
        assert!(rank("s", &[settings.clone(), slack.clone()])[0].index == 0);
        slack.priority = 2400;
        assert_eq!(rank("s", &[settings, slack])[0].index, 1);
    }
}
