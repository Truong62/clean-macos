use crate::english;
use crate::vietnamese::{
    base_of, cluster_can_grow, is_valid_syllable, letters_of, render_word, rhyme_allows, tone_index, vowel_range, Letter, Mark, Tone,
    INITIALS, STOP_FINALS,
};
use std::collections::HashMap;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Method {
    Telex,
    Vni,
}

#[derive(Clone, Debug)]
pub struct Options {
    pub method: Method,
    pub vietnamese: bool,
    pub modern_tone: bool,
    pub auto_restore: bool,
    pub w_as_u: bool,
    pub brackets: bool,
    pub foreign_consonants: bool,
    pub auto_capitalize: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            method: Method::Telex,
            vietnamese: true,
            modern_tone: true,
            auto_restore: true,
            w_as_u: true,
            brackets: false,
            foreign_consonants: false,
            auto_capitalize: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Output {
    Pass,
    Replace { backspaces: usize, text: String },
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Action {
    Tone(Tone),
    Clear,
    Circumflex(Option<char>),
    Horn,
    Breve,
    W,
    Stroke,
    Bracket(char),
}

struct Word {
    shown: String,
    raw: String,
    separators: usize,
}

const HISTORY: usize = 10;
const FINAL_PREFIXES: &[&str] = &["ch", "ng", "nh", "c", "k", "m", "n", "p", "t"];
const FOREIGN_INITIALS: &[&str] = &["f", "j", "w", "z"];

pub struct Engine {
    pub options: Options,
    letters: Vec<Letter>,
    tone: Tone,
    raw: String,
    shown: String,
    literal: bool,
    last: Option<Action>,
    lone_w: bool,
    history: Vec<Word>,
    capitalize: bool,
    sentence_end: bool,
    macros: HashMap<String, String>,
}

impl Engine {
    pub fn new(options: Options) -> Self {
        Engine {
            options,
            letters: Vec::new(),
            tone: Tone::None,
            raw: String::new(),
            shown: String::new(),
            literal: false,
            last: None,
            lone_w: false,
            history: Vec::new(),
            capitalize: false,
            sentence_end: false,
            macros: HashMap::new(),
        }
    }

    pub fn set_macros(&mut self, macros: HashMap<String, String>) {
        self.macros = macros.into_iter().map(|(key, value)| (key.to_lowercase(), value)).collect();
    }

    pub fn shown(&self) -> &str {
        &self.shown
    }

    pub fn reset(&mut self) {
        self.clear_word();
        self.history.clear();
        self.capitalize = false;
        self.sentence_end = false;
    }

    pub fn key(&mut self, typed: char) -> Output {
        let ch = self.capitalized(typed);
        if self.options.vietnamese && !self.literal {
            if let Some(action) = self.action_for(ch) {
                self.raw.push(ch);
                if self.apply(action, ch) {
                    self.last = Some(action);
                    return self.show(typed);
                }
                self.raw.pop();
            }
        }
        if !ch.is_alphanumeric() {
            return self.finish(Some(ch));
        }
        self.sentence_end = false;
        self.raw.push(ch);
        self.push_letter(ch);
        self.last = None;
        self.lone_w = false;
        self.show(typed)
    }

    pub fn backspace(&mut self) {
        if self.shown.is_empty() {
            self.reload_previous_word();
            return;
        }
        let untouched = self.shown == self.raw;
        let mut chars: Vec<char> = self.shown.chars().collect();
        chars.pop();
        let text: String = chars.into_iter().collect();
        let (letters, tone) = letters_of(&text);
        self.letters = letters;
        self.tone = tone;
        if untouched {
            self.raw.pop();
        } else {
            self.raw = text.clone();
        }
        self.shown = text;
        self.last = None;
        self.lone_w = false;
        self.literal = !self.letters.is_empty() && !self.is_prefix();
    }

    pub fn restore(&mut self) -> Output {
        if self.shown.is_empty() || self.shown == self.raw {
            return Output::Pass;
        }
        let output = Output::Replace { backspaces: self.shown.chars().count(), text: self.raw.clone() };
        self.shown = self.raw.clone();
        self.letters = self.raw.chars().map(letter_for).collect();
        self.tone = Tone::None;
        self.literal = true;
        output
    }

    pub fn finish(&mut self, separator: Option<char>) -> Output {
        let replacement = self.replacement();
        let output = match &replacement {
            Some(text) => Output::Replace {
                backspaces: self.shown.chars().count(),
                text: separator.map_or(text.clone(), |separator| format!("{text}{separator}")),
            },
            None => Output::Pass,
        };
        if !self.shown.is_empty() {
            self.history.push(Word {
                shown: replacement.unwrap_or_else(|| self.shown.clone()),
                raw: self.raw.clone(),
                separators: usize::from(separator.is_some()),
            });
            if self.history.len() > HISTORY {
                self.history.remove(0);
            }
        } else if separator.is_some() {
            if let Some(word) = self.history.last_mut() {
                word.separators += 1;
            }
        }
        self.clear_word();
        self.arm_capitalize(separator);
        output
    }

    fn clear_word(&mut self) {
        self.letters.clear();
        self.tone = Tone::None;
        self.raw.clear();
        self.shown.clear();
        self.literal = false;
        self.last = None;
        self.lone_w = false;
    }

    fn reload_previous_word(&mut self) {
        let Some(word) = self.history.last_mut() else { return };
        if word.separators > 1 {
            word.separators -= 1;
            return;
        }
        let Some(word) = self.history.pop() else { return };
        let (letters, tone) = letters_of(&word.shown);
        self.letters = letters;
        self.tone = tone;
        self.raw = word.raw;
        self.shown = word.shown;
        self.literal = !self.is_prefix();
    }

    fn arm_capitalize(&mut self, separator: Option<char>) {
        match separator {
            Some('.' | '!' | '?') => self.sentence_end = true,
            Some(' ') if self.sentence_end => {
                self.capitalize = true;
                self.sentence_end = false;
            }
            Some('\n' | '\r') => self.capitalize = true,
            Some(',' | ';' | ':') => {
                self.capitalize = false;
                self.sentence_end = false;
            }
            Some(' ') => self.sentence_end = false,
            _ => {}
        }
    }

    fn capitalized(&mut self, ch: char) -> char {
        if !ch.is_alphanumeric() {
            return ch;
        }
        let armed = self.capitalize && self.options.auto_capitalize && self.letters.is_empty();
        self.capitalize = false;
        if armed && ch.is_lowercase() {
            ch.to_uppercase().next().unwrap_or(ch)
        } else {
            ch
        }
    }

    fn replacement(&self) -> Option<String> {
        if self.shown.is_empty() {
            return None;
        }
        if let Some(expansion) = self.macro_expansion() {
            return Some(expansion);
        }
        let restore = self.options.vietnamese
            && self.options.auto_restore
            && self.options.method == Method::Telex
            && self.shown != self.raw
            && (english::always_english(&self.raw) || (!self.is_valid_word() && english::is_english(&self.raw)));
        restore.then(|| self.raw.clone())
    }

    fn macro_expansion(&self) -> Option<String> {
        if self.macros.is_empty() || self.raw.chars().any(|ch| ch.is_ascii_digit()) {
            return None;
        }
        let expansion = self.macros.get(&self.shown.to_lowercase()).or_else(|| self.macros.get(&self.raw.to_lowercase()))?;
        let letters: Vec<char> = self.shown.chars().filter(|ch| ch.is_alphabetic()).collect();
        if letters.len() > 1 && letters.iter().all(|ch| ch.is_uppercase()) {
            return Some(expansion.to_uppercase());
        }
        if letters.first().is_some_and(|ch| ch.is_uppercase()) {
            let mut chars = expansion.chars();
            return Some(chars.next().map_or(String::new(), |first| first.to_uppercase().chain(chars).collect()));
        }
        Some(expansion.clone())
    }

    fn is_valid_word(&self) -> bool {
        self.letters.iter().any(Letter::is_vowel) && is_valid_syllable(&self.letters, self.tone)
    }

    fn action_for(&self, ch: char) -> Option<Action> {
        let key = ch.to_ascii_lowercase();
        match self.options.method {
            Method::Telex => match key {
                's' => Some(Action::Tone(Tone::Acute)),
                'f' => Some(Action::Tone(Tone::Grave)),
                'r' => Some(Action::Tone(Tone::Hook)),
                'x' => Some(Action::Tone(Tone::Tilde)),
                'j' => Some(Action::Tone(Tone::Dot)),
                'z' => Some(Action::Clear),
                'a' | 'e' | 'o' => Some(Action::Circumflex(Some(key))),
                'w' => Some(Action::W),
                'd' => Some(Action::Stroke),
                '[' | '{' if self.options.brackets => Some(Action::Bracket('o')),
                ']' | '}' if self.options.brackets => Some(Action::Bracket('u')),
                _ => None,
            },
            Method::Vni => match key {
                '1' => Some(Action::Tone(Tone::Acute)),
                '2' => Some(Action::Tone(Tone::Grave)),
                '3' => Some(Action::Tone(Tone::Hook)),
                '4' => Some(Action::Tone(Tone::Tilde)),
                '5' => Some(Action::Tone(Tone::Dot)),
                '0' => Some(Action::Clear),
                '6' => Some(Action::Circumflex(None)),
                '7' => Some(Action::Horn),
                '8' => Some(Action::Breve),
                '9' => Some(Action::Stroke),
                _ => None,
            },
        }
    }

    fn apply(&mut self, action: Action, ch: char) -> bool {
        match action {
            Action::Tone(tone) => self.apply_tone(tone, ch),
            Action::Clear => self.clear_marks(),
            Action::Circumflex(vowel) => self.toggle_mark(Mark::Circumflex, action, ch, |letter| match vowel {
                Some(vowel) => letter.base == vowel,
                None => matches!(letter.base, 'a' | 'e' | 'o'),
            }),
            Action::Horn => self.apply_horn(ch, action),
            Action::Breve => self.toggle_mark(Mark::Breve, action, ch, |letter| letter.base == 'a'),
            Action::W => self.apply_horn(ch, action),
            Action::Stroke => self.apply_stroke(ch),
            Action::Bracket(base) => self.apply_bracket(base, ch),
        }
    }

    fn apply_tone(&mut self, tone: Tone, ch: char) -> bool {
        let Some((_, end)) = vowel_range(&self.letters) else { return false };
        let special = self.letters.iter().any(|letter| letter.mark != Mark::None);
        if !special && !self.is_prefix() {
            return false;
        }
        let tail: String = self.letters[end + 1..].iter().map(Letter::plain).collect();
        if STOP_FINALS.contains(&tail.as_str()) && !matches!(tone, Tone::Acute | Tone::Dot) {
            return false;
        }
        if self.tone != tone {
            self.tone = tone;
            return true;
        }
        let consecutive = self.last == Some(Action::Tone(tone));
        let toned = tone_index(&self.letters, self.options.modern_tone).unwrap_or(end);
        if !consecutive && self.letters[toned + 1..].iter().all(Letter::is_vowel) {
            return true;
        }
        self.tone = Tone::None;
        self.push_literal(ch);
        true
    }

    fn clear_marks(&mut self) -> bool {
        if self.tone != Tone::None {
            self.tone = Tone::None;
            return true;
        }
        let marked = self.letters.iter().rposition(|letter| letter.is_vowel() && letter.mark != Mark::None);
        let Some(index) = marked else { return false };
        self.letters[index].mark = Mark::None;
        true
    }

    fn toggle_mark(&mut self, mark: Mark, action: Action, ch: char, matches: impl Fn(&Letter) -> bool) -> bool {
        let Some((start, end)) = vowel_range(&self.letters) else { return false };
        let Some(index) = (start..=end).rev().find(|&index| matches(&self.letters[index])) else { return false };
        if self.letters[index].mark == mark {
            if mark != Mark::Circumflex && self.last != Some(action) {
                return false;
            }
            self.letters[index].mark = Mark::None;
            self.push_literal(ch);
            return true;
        }
        let previous = self.letters[index].mark;
        self.letters[index].mark = mark;
        if !cluster_can_grow(&self.letters[start..=end]) {
            self.letters[index].mark = previous;
            return false;
        }
        true
    }

    fn apply_horn(&mut self, ch: char, action: Action) -> bool {
        let is_w = action == Action::W;
        if is_w && self.lone_w && self.last == Some(Action::W) {
            if let Some(letter) = self.letters.last_mut() {
                *letter = Letter::new('w', letter.upper);
            }
            self.literal = true;
            self.lone_w = false;
            return true;
        }
        let Some((start, end)) = vowel_range(&self.letters) else {
            return is_w && self.options.w_as_u && self.push_lone_u(ch);
        };
        let bases: String = self.letters[start..=end].iter().map(|letter| letter.base).collect();
        if let Some(offset) = bases.find("uo") {
            return self.horn_uo(start + offset, ch);
        }
        if is_w && bases == "oa" {
            return self.toggle_mark(Mark::Breve, action, ch, |letter| letter.base == 'a');
        }
        if bases.contains('o') && bases != "oe" {
            return self.toggle_mark(Mark::Horn, action, ch, |letter| letter.base == 'o');
        }
        if let Some(offset) = bases.find('u') {
            let index = start + offset;
            if self.letters[index].mark == Mark::Horn {
                return self.toggle_mark(Mark::Horn, action, ch, |letter| letter.base == 'u');
            }
            self.letters[index].mark = Mark::Horn;
            if cluster_can_grow(&self.letters[start..=end]) {
                return true;
            }
            self.letters[index].mark = Mark::None;
            return false;
        }
        is_w && bases.ends_with('a') && self.toggle_mark(Mark::Breve, action, ch, |letter| letter.base == 'a')
    }

    fn horn_uo(&mut self, u: usize, ch: char) -> bool {
        let at_end = u + 2 == self.letters.len();
        let u_horn = self.letters[u].mark == Mark::Horn;
        let o_horn = self.letters[u + 1].mark == Mark::Horn;
        if o_horn && u_horn {
            return true;
        }
        if o_horn && at_end {
            self.letters[u].mark = Mark::None;
            self.letters[u + 1].mark = Mark::None;
            self.push_literal(ch);
            return true;
        }
        self.letters[u + 1].mark = Mark::Horn;
        if !at_end {
            self.letters[u].mark = Mark::Horn;
        }
        true
    }

    fn push_lone_u(&mut self, ch: char) -> bool {
        self.letters.push(Letter { base: 'u', mark: Mark::Horn, upper: ch.is_uppercase() });
        if self.is_prefix() {
            self.lone_w = true;
            return true;
        }
        self.letters.pop();
        false
    }

    fn apply_bracket(&mut self, base: char, ch: char) -> bool {
        if self.lone_w && self.last == Some(Action::Bracket(base)) {
            if let Some(letter) = self.letters.last_mut() {
                *letter = Letter::new(ch, false);
            }
            self.literal = true;
            self.lone_w = false;
            return true;
        }
        self.letters.push(Letter { base, mark: Mark::Horn, upper: matches!(ch, '{' | '}') });
        if !self.is_prefix() {
            self.letters.pop();
            return false;
        }
        self.lone_w = true;
        true
    }

    fn apply_stroke(&mut self, ch: char) -> bool {
        let Some(first) = self.letters.first().copied() else { return false };
        if first.base != 'd' {
            return false;
        }
        if first.mark == Mark::Stroke {
            if self.options.method == Method::Telex && self.last != Some(Action::Stroke) {
                return false;
            }
            self.letters[0].mark = Mark::None;
            self.push_literal(ch);
            return true;
        }
        self.letters[0].mark = Mark::Stroke;
        if self.letters.len() > 1 && !self.is_prefix() {
            self.letters[0].mark = Mark::None;
            return false;
        }
        true
    }

    fn push_letter(&mut self, ch: char) {
        let follows_horned_u = self.letters.last().is_some_and(|letter| letter.base == 'u' && letter.mark == Mark::Horn)
            && !(self.letters.len() == 2 && self.letters[0].base == 'q');
        let mut letter = letter_for(ch);
        if self.options.vietnamese && letter.base == 'o' && follows_horned_u {
            letter.mark = Mark::Horn;
        }
        self.letters.push(letter);
        if ch.is_alphabetic() && self.is_prefix() {
            if self.options.vietnamese {
                self.complete_uo();
            }
            return;
        }
        let explicit = self.letters.iter().any(|letter| matches!(letter.mark, Mark::Breve | Mark::Horn | Mark::Stroke));
        if self.options.vietnamese && !explicit && !self.literal {
            self.letters = self.raw.chars().map(letter_for).collect();
            self.tone = Tone::None;
        }
        self.literal = true;
    }

    fn push_literal(&mut self, ch: char) {
        self.letters.push(letter_for(ch));
        self.literal = true;
    }

    fn complete_uo(&mut self) {
        let count = self.letters.len();
        let found = (0..count.saturating_sub(2)).find(|&index| {
            self.letters[index].base == 'u'
                && self.letters[index].mark == Mark::None
                && self.letters[index + 1].base == 'o'
                && self.letters[index + 1].mark == Mark::Horn
                && !(index == 1 && self.letters[0].base == 'q')
        });
        if let Some(index) = found {
            self.letters[index].mark = Mark::Horn;
        }
    }

    fn is_prefix(&self) -> bool {
        let first = self.letters.iter().position(Letter::is_vowel).unwrap_or(self.letters.len());
        let initial: String = self.letters[..first].iter().map(|letter| base_of(letter.plain())).collect();
        let foreign = self.options.foreign_consonants && FOREIGN_INITIALS.contains(&initial.as_str());
        let known_initial = INITIALS.iter().any(|known| known.chars().map(base_of).collect::<String>().starts_with(&initial));
        if !initial.is_empty() && !foreign && !known_initial {
            return false;
        }
        let Some((start, end)) = vowel_range(&self.letters) else { return true };
        if initial == "q" && self.letters.get(first).is_some_and(|letter| letter.base != 'u') {
            return false;
        }
        let cluster = &self.letters[start..=end];
        if !cluster_can_grow(cluster) || !spelling_ok(&initial, &self.letters[first]) {
            return false;
        }
        let tail: String = self.letters[end + 1..].iter().map(|letter| base_of(letter.plain())).collect();
        if tail.is_empty() {
            return true;
        }
        if !FINAL_PREFIXES.iter().any(|known| known.starts_with(&tail)) {
            return false;
        }
        let nucleus: String = cluster.iter().map(Letter::plain).collect();
        let open_e = cluster.iter().any(|letter| letter.base == 'e' && letter.mark == Mark::None);
        !FINAL_PREFIXES.contains(&tail.as_str()) || rhyme_allows(&nucleus, &tail) || open_e
    }

    fn show(&mut self, typed: char) -> Output {
        let next = render_word(&self.letters, self.tone, self.options.modern_tone);
        let previous: Vec<char> = self.shown.chars().collect();
        let upcoming: Vec<char> = next.chars().collect();
        let common = previous.iter().zip(&upcoming).take_while(|(a, b)| a == b).count();
        let backspaces = previous.len() - common;
        let text: String = upcoming[common..].iter().collect();
        self.shown = next;
        if backspaces == 0 && text.chars().eq(std::iter::once(typed)) {
            Output::Pass
        } else {
            Output::Replace { backspaces, text }
        }
    }
}

fn spelling_ok(initial: &str, vowel: &Letter) -> bool {
    let front = matches!(vowel.base, 'e' | 'i' | 'y');
    match initial {
        "k" => front || matches!(vowel.plain(), 'a' | 'o' | 'ô'),
        "gh" | "ngh" => front,
        "c" | "ng" => !front,
        "g" => !matches!(vowel.base, 'e' | 'y'),
        "q" => vowel.base == 'u',
        _ => true,
    }
}

fn letter_for(ch: char) -> Letter {
    Letter::new(ch.to_lowercase().next().unwrap_or(ch), ch.is_uppercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen_with(options: Options, keys: &str) -> String {
        let mut engine = Engine::new(options);
        let mut text = String::new();
        for ch in keys.chars() {
            let output = match ch {
                '<' => {
                    engine.backspace();
                    text.pop();
                    continue;
                }
                '~' => engine.restore(),
                _ => engine.key(ch),
            };
            match output {
                Output::Pass if ch != '~' => text.push(ch),
                Output::Pass => {}
                Output::Replace { backspaces, text: insert } => {
                    for _ in 0..backspaces {
                        text.pop();
                    }
                    text.push_str(&insert);
                }
            }
        }
        text
    }

    fn plain() -> Options {
        Options { auto_restore: false, ..Options::default() }
    }

    fn check(options: Options, cases: &[(&str, &str)]) {
        for (keys, expected) in cases {
            assert_eq!(screen_with(options.clone(), keys), *expected, "{keys}");
        }
    }

    #[test]
    fn telex_builds_words_in_any_order() {
        check(
            plain(),
            &[
                ("tieengs", "tiếng"),
                ("tiengse", "tiếng"),
                ("tieseng", "tiếng"),
                ("vieetj", "việt"),
                ("dduowcj", "được"),
                ("nguowif", "người"),
                ("nguwowif", "người"),
                ("hoaf", "hoà"),
                ("thusy", "thuý"),
                ("quys", "quý"),
                ("quyeets", "quyết"),
                ("gif", "gì"),
                ("giuwx", "giữ"),
                ("giuwax", "giữa"),
                ("osa", "oá"),
                ("toasn", "toán"),
                ("muaw", "mưa"),
                ("uafw", "ừa"),
                ("huow", "huơ"),
                ("thuowr", "thuở"),
                ("uwo", "ươ"),
                ("Quoiws", "Quới"),
                ("oow", "ơ"),
                ("nhw", "như"),
                ("wmf", "ừm"),
                ("raw", "ră"),
                ("hoawcj", "hoặc"),
                ("uuw", "ưu"),
                ("asa", "ấ"),
                ("xepse", "xếp"),
                ("tamsa", "tấm"),
                ("nanag", "nâng"),
                ("dauas", "dấu"),
                ("dod", "đo"),
                ("docdj", "đọc"),
                ("roofif", "rồi"),
                ("chuwaa", "chưaa"),
                ("VIEETJ", "VIỆT"),
                ("viEets", "viẾt"),
                ("DDUWOWCJ", "ĐƯỢC"),
                ("Kroong Busk", "Krông Búk"),
                ("Bacsw Kanj", "Bắc Kạn"),
                ("ruowuj", "rượu"),
                ("huowng", "hương"),
            ],
        );
    }

    #[test]
    fn telex_undo_and_clearing() {
        check(
            plain(),
            &[
                ("aaa", "aa"),
                ("aaaa", "aaa"),
                ("ass", "as"),
                ("asaa", "áa"),
                ("asf", "à"),
                ("aww", "aw"),
                ("oww", "ow"),
                ("uww", "uw"),
                ("ddd", "dd"),
                ("ww", "w"),
                ("Ww", "W"),
                ("koongz", "kong"),
                ("asz", "a"),
                ("lists", "lits"),
                ("z", "z"),
            ],
        );
    }

    #[test]
    fn telex_rejects_shapes_that_are_not_vietnamese() {
        check(
            plain(),
            &[
                ("taiw", "taiw"),
                ("kw", "kw"),
                ("otr", "otr"),
                ("matf", "matf"),
                ("ots", "ót"),
                ("things", "things"),
                ("deadline", "deadline"),
                ("kanji", "kanji"),
                ("zas", "zas"),
                ("o2o", "o2o"),
                ("class", "class"),
                ("print(x)", "print(x)"),
                ("google", "google"),
                ("ddc", "đc"),
                ("chucwsc", "chứcc"),
            ],
        );
        assert_eq!(screen_with(Options { foreign_consonants: true, ..plain() }, "zas"), "zá");
    }

    #[test]
    fn old_style_tones_differ_only_for_open_oa_oe_uy() {
        let old = Options { modern_tone: false, ..plain() };
        check(old, &[("hoaf", "hòa"), ("thuys", "thúy"), ("khoer", "khỏe"), ("hoanf", "hoàn"), ("quys", "quý")]);
    }

    #[test]
    fn restores_english_words_at_the_end_of_a_word() {
        check(
            Options::default(),
            &[
                ("text ", "text "),
                ("with ", "with "),
                ("would ", "would "),
                ("user.", "user."),
                ("windows ", "windows "),
                ("data ", "data "),
                ("as ", "as "),
                ("there ", "thể "),
                ("mix ", "mĩ "),
                ("ddc ", "đc "),
                ("tieengs ", "tiếng "),
            ],
        );
    }

    #[test]
    fn vni_builds_and_undoes() {
        let vni = Options { method: Method::Vni, ..plain() };
        check(
            vni,
            &[
                ("a1", "á"),
                ("a6", "â"),
                ("a8", "ă"),
                ("d9", "đ"),
                ("toi61", "tối"),
                ("nguoi72", "người"),
                ("VIE65T", "VIỆT"),
                ("D9U7O7NG2", "ĐƯỜNG"),
                ("hoa2", "hoà"),
                ("o67", "ơ"),
                ("o676", "ô"),
                ("dung9", "đung"),
                ("o2o", "òo"),
                ("a11", "a1"),
                ("a66", "a6"),
                ("u7o7", "ươ"),
            ],
        );
    }

    #[test]
    fn esc_restores_the_raw_keys() {
        check(plain(), &[("vieejt~", "vieejt"), ("ass~", "ass")]);
    }

    #[test]
    fn backspace_edits_the_word_and_reaches_back_into_history() {
        check(plain(), &[("tieengs<<ng", "tiếng"), ("ab<s", "á"), ("du <j", "dụ"), ("duow <c", "dươc"), ("du  <<j", "dụ")]);
    }

    #[test]
    fn brackets_type_horned_letters_when_enabled() {
        let brackets = Options { brackets: true, ..plain() };
        check(brackets, &[("[", "ơ"), ("]", "ư"), ("t]", "tư"), ("[[", "["), ("{", "Ơ")]);
        check(plain(), &[("[a", "[a")]);
    }

    #[test]
    fn capitalizes_the_start_of_a_sentence_when_enabled() {
        let capitalize = Options { auto_capitalize: true, ..Options::default() };
        check(capitalize, &[("chaof. ban", "chào. Ban"), ("ok. ddis", "ok. Đí"), ("google.com", "google.com"), ("a, b", "a, b")]);
    }

    #[test]
    fn expands_macros_following_the_case_of_the_trigger() {
        let mut engine = Engine::new(Options::default());
        engine.set_macros(HashMap::from([("vn".to_string(), "Việt Nam".to_string()), ("ko".to_string(), "không".to_string())]));
        let run = |engine: &mut Engine, keys: &str| {
            keys.chars().fold(String::new(), |mut text, ch| {
                match engine.key(ch) {
                    Output::Pass => text.push(ch),
                    Output::Replace { backspaces, text: insert } => {
                        for _ in 0..backspaces {
                            text.pop();
                        }
                        text.push_str(&insert);
                    }
                }
                text
            })
        };
        assert_eq!(run(&mut engine, "vn "), "Việt Nam ");
        assert_eq!(run(&mut engine, "VN "), "VIỆT NAM ");
        assert_eq!(run(&mut engine, "Ko "), "Không ");
        assert_eq!(run(&mut engine, "149ko "), "149ko ");
        engine.options.vietnamese = false;
        assert_eq!(run(&mut engine, "ko "), "không ");
        assert_eq!(run(&mut engine, "tieengs "), "tieengs ");
    }
}
