use crate::vietnamese::{is_valid_syllable, letters_of, render_word, vowel_range, Letter, Mark, Tone};
use std::collections::HashMap;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Method {
    Telex,
    Vni,
}

#[derive(Clone, Debug)]
pub struct Options {
    pub method: Method,
    pub modern_tone: bool,
    pub auto_restore: bool,
    pub w_as_u: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options { method: Method::Telex, modern_tone: true, auto_restore: true, w_as_u: true }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Output {
    Pass,
    Replace { backspaces: usize, text: String },
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Action {
    Tone(Tone),
    ClearTone,
    Circumflex(Option<char>),
    Horn,
    Breve,
    HornOrBreve,
    Stroke,
}

const INITIAL_PREFIXES: &[&str] = &[
    "ngh", "ng", "nh", "ch", "gh", "gi", "kh", "ph", "qu", "th", "tr", "b", "c", "d", "đ", "g", "h", "k", "l", "m", "n", "p",
    "q", "r", "s", "t", "v", "x",
];
const FINAL_PREFIXES: &[&str] = &["ch", "ng", "nh", "c", "m", "n", "p", "t"];

pub struct Engine {
    pub options: Options,
    letters: Vec<Letter>,
    tone: Tone,
    raw: String,
    shown: String,
    literal: bool,
    macros: HashMap<String, String>,
}

impl Engine {
    pub fn new(options: Options) -> Self {
        Engine { options, letters: Vec::new(), tone: Tone::None, raw: String::new(), shown: String::new(), literal: false, macros: HashMap::new() }
    }

    pub fn set_macros(&mut self, macros: HashMap<String, String>) {
        self.macros = macros.into_iter().map(|(key, value)| (key.to_lowercase(), value)).collect();
    }

    pub fn reset(&mut self) {
        self.letters.clear();
        self.tone = Tone::None;
        self.raw.clear();
        self.shown.clear();
        self.literal = false;
    }

    pub fn shown(&self) -> &str {
        &self.shown
    }

    pub fn key(&mut self, ch: char) -> Output {
        if let Some(action) = if self.literal { None } else { self.action_for(ch) } {
            self.raw.push(ch);
            if self.apply(action, ch) {
                return self.show(ch);
            }
            self.raw.pop();
        }
        if !ch.is_alphabetic() {
            return self.finish(Some(ch));
        }
        self.raw.push(ch);
        self.letters.push(Letter::new(ch.to_lowercase().next().unwrap_or(ch), ch.is_uppercase()));
        if self.could_be_vietnamese() {
            self.complete_uo();
        } else {
            self.literal = true;
        }
        self.show(ch)
    }

    pub fn backspace(&mut self) {
        let mut chars: Vec<char> = self.shown.chars().collect();
        if chars.pop().is_none() {
            return self.reset();
        }
        let text: String = chars.into_iter().collect();
        let (letters, tone) = letters_of(&text);
        self.letters = letters;
        self.tone = tone;
        self.raw = text.clone();
        self.shown = text;
        self.literal = !self.could_be_vietnamese();
    }

    pub fn finish(&mut self, separator: Option<char>) -> Output {
        let restore = self.options.auto_restore
            && self.shown != self.raw
            && !self.letters.is_empty()
            && !is_valid_syllable(&self.letters, self.tone);
        let expansion = self.macros.get(&self.shown.to_lowercase()).cloned();
        let replacement = if restore { Some(self.raw.clone()) } else { expansion };
        let output = match (replacement, separator) {
            (Some(text), Some(separator)) => Output::Replace {
                backspaces: self.shown.chars().count(),
                text: format!("{text}{separator}"),
            },
            _ => Output::Pass,
        };
        self.reset();
        output
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
                'z' => Some(Action::ClearTone),
                'a' | 'e' | 'o' => Some(Action::Circumflex(Some(key))),
                'w' => Some(Action::HornOrBreve),
                'd' => Some(Action::Stroke),
                _ => None,
            },
            Method::Vni => match key {
                '1' => Some(Action::Tone(Tone::Acute)),
                '2' => Some(Action::Tone(Tone::Grave)),
                '3' => Some(Action::Tone(Tone::Hook)),
                '4' => Some(Action::Tone(Tone::Tilde)),
                '5' => Some(Action::Tone(Tone::Dot)),
                '0' => Some(Action::ClearTone),
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
            Action::ClearTone => {
                if self.tone == Tone::None {
                    return false;
                }
                self.tone = Tone::None;
                true
            }
            Action::Circumflex(vowel) => self.toggle_mark(Mark::Circumflex, ch, |letter| match vowel {
                Some(vowel) => letter.base == vowel,
                None => matches!(letter.base, 'a' | 'e' | 'o'),
            }),
            Action::Horn => self.apply_horn(ch, false),
            Action::Breve => self.toggle_mark(Mark::Breve, ch, |letter| letter.base == 'a'),
            Action::HornOrBreve => self.apply_horn(ch, true),
            Action::Stroke => self.apply_stroke(ch),
        }
    }

    fn vowels(&self) -> Option<(usize, usize)> {
        vowel_range(&self.letters)
    }

    fn apply_tone(&mut self, tone: Tone, ch: char) -> bool {
        if self.vowels().is_none() {
            return false;
        }
        if self.tone == tone {
            self.tone = Tone::None;
            self.push_literal(ch);
        } else {
            self.tone = tone;
        }
        true
    }

    fn toggle_mark(&mut self, mark: Mark, ch: char, matches: impl Fn(&Letter) -> bool) -> bool {
        let Some((start, end)) = self.vowels() else { return false };
        let Some(index) = (start..=end).rev().find(|&index| matches(&self.letters[index])) else { return false };
        if self.letters[index].mark == mark {
            self.letters[index].mark = Mark::None;
            self.push_literal(ch);
        } else {
            self.letters[index].mark = mark;
        }
        true
    }

    fn apply_horn(&mut self, ch: char, breve_fallback: bool) -> bool {
        let Some((start, end)) = self.vowels() else {
            if breve_fallback && self.options.w_as_u && self.could_be_vietnamese() {
                self.letters.push(Letter { base: 'u', mark: Mark::Horn, upper: ch.is_uppercase() });
                return true;
            }
            return false;
        };
        let pair = (start..end).find(|&index| self.letters[index].base == 'u' && self.letters[index + 1].base == 'o');
        if let Some(u) = pair {
            let at_end = u + 2 == self.letters.len();
            let u_horn = self.letters[u].mark == Mark::Horn;
            if self.letters[u + 1].mark == Mark::Horn && (u_horn || at_end) {
                self.letters[u].mark = Mark::None;
                self.letters[u + 1].mark = Mark::None;
                self.push_literal(ch);
            } else {
                self.letters[u + 1].mark = Mark::Horn;
                if !at_end {
                    self.letters[u].mark = Mark::Horn;
                }
            }
            return true;
        }
        if (start..=end).any(|index| matches!(self.letters[index].base, 'o' | 'u')) {
            return self.toggle_mark(Mark::Horn, ch, |letter| matches!(letter.base, 'o' | 'u'));
        }
        breve_fallback && self.toggle_mark(Mark::Breve, ch, |letter| letter.base == 'a')
    }

    fn apply_stroke(&mut self, ch: char) -> bool {
        let Some(first) = self.letters.first().copied() else { return false };
        if first.base != 'd' || (self.options.method == Method::Telex && self.letters.len() != 1 && first.mark != Mark::Stroke) {
            return false;
        }
        if first.mark == Mark::Stroke {
            self.letters[0].mark = Mark::None;
            self.push_literal(ch);
        } else {
            self.letters[0].mark = Mark::Stroke;
        }
        true
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

    fn push_literal(&mut self, ch: char) {
        self.letters.push(Letter::new(ch.to_lowercase().next().unwrap_or(ch), ch.is_uppercase()));
        self.literal = true;
    }

    fn could_be_vietnamese(&self) -> bool {
        let word: String = self.letters.iter().map(Letter::plain).collect();
        let is_vowel = |c: char| "aăâeêioôơuưy".contains(c);
        let first = word.find(is_vowel).unwrap_or(word.len());
        let initial = &word[..first];
        if !initial.is_empty() && !INITIAL_PREFIXES.iter().any(|known| known.starts_with(initial)) {
            return false;
        }
        let rest = &word[first..];
        let tail = rest.trim_start_matches(is_vowel);
        tail.is_empty() || FINAL_PREFIXES.iter().any(|known| known.starts_with(tail))
    }

    fn show(&mut self, ch: char) -> Output {
        let next = render_word(&self.letters, self.tone, self.options.modern_tone);
        let previous: Vec<char> = self.shown.chars().collect();
        let upcoming: Vec<char> = next.chars().collect();
        let common = previous.iter().zip(&upcoming).take_while(|(a, b)| a == b).count();
        let backspaces = previous.len() - common;
        let text: String = upcoming[common..].iter().collect();
        self.shown = next;
        if backspaces == 0 && text.chars().eq(std::iter::once(ch)) {
            Output::Pass
        } else {
            Output::Replace { backspaces, text }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen(method: Method, modern: bool, keys: &str) -> String {
        let mut engine = Engine::new(Options { method, modern_tone: modern, ..Options::default() });
        let mut text = String::new();
        for ch in keys.chars() {
            let output = if ch == '<' {
                engine.backspace();
                text.pop();
                continue;
            } else {
                engine.key(ch)
            };
            match output {
                Output::Pass => text.push(ch),
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

    fn telex(keys: &str) -> String {
        screen(Method::Telex, true, keys)
    }

    #[test]
    fn telex_builds_vietnamese_words() {
        let cases = [
            ("tieengs", "tiếng"),
            ("vieetj", "việt"),
            ("dduowcj", "được"),
            ("nguwowif", "người"),
            ("nguowif", "người"),
            ("hoaf", "hoà"),
            ("thuys", "thuý"),
            ("quys", "quý"),
            ("giuwax", "giữa"),
            ("khuyeets", "khuyết"),
            ("ngoaif", "ngoài"),
            ("xoays", "xoáy"),
            ("cuwus", "cứu"),
            ("thuowr", "thuở"),
            ("Vieejt Nam", "Việt Nam"),
            ("DDuwowngf", "Đường"),
            ("tooi yeeu", "tôi yêu"),
            ("aw", "ă"),
            ("awn", "ăn"),
            ("tw", "tư"),
            ("w", "ư"),
            ("muaf", "mùa"),
            ("bawts", "bắt"),
            ("hocj", "học"),
            ("ddi", "đi"),
            ("toans", "toán"),
            ("thanhf", "thành"),
            ("nhaf", "nhà"),
            ("chuyeenj", "chuyện"),
            ("gif", "gì"),
            ("huowng", "hương"),
            ("ruowuj", "rượu"),
            ("quowr", "quở"),
        ];
        for (keys, expected) in cases {
            assert_eq!(telex(keys), expected, "{keys}");
        }
    }

    #[test]
    fn telex_undoes_with_a_second_press_and_clears_tones() {
        let cases = [("aaa", "aa"), ("ass", "as"), ("ddd", "dd"), ("aww", "aw"), ("oww", "ow"), ("asz", "a"), ("tieengsz", "tiêng"), ("z", "z")];
        for (keys, expected) in cases {
            assert_eq!(telex(keys), expected, "{keys}");
        }
    }

    #[test]
    fn telex_leaves_english_words_alone() {
        let cases = [
            ("class ", "class "),
            ("windows ", "windows "),
            ("hello ", "hello "),
            ("text ", "text "),
            ("free ", "free "),
            ("street ", "street "),
            ("google ", "google "),
            ("print(x)", "print(x)"),
        ];
        for (keys, expected) in cases {
            assert_eq!(telex(keys), expected, "{keys}");
        }
    }

    #[test]
    fn old_style_puts_the_tone_on_the_first_vowel() {
        assert_eq!(screen(Method::Telex, false, "hoaf"), "hòa");
        assert_eq!(screen(Method::Telex, false, "thuys"), "thúy");
        assert_eq!(screen(Method::Telex, false, "hoanf"), "hoàn");
    }

    #[test]
    fn vni_builds_vietnamese_words() {
        let cases = [
            ("tie61ng", "tiếng"),
            ("tieng61", "tiếng"),
            ("d9u7o7c5", "được"),
            ("nguo72i", "người"),
            ("hoa2", "hoà"),
            ("a8n", "ăn"),
            ("Vie65t Nam", "Việt Nam"),
            ("a11", "a1"),
            ("a10", "a"),
            ("x2 ", "x2 "),
            ("1999", "1999"),
        ];
        for (keys, expected) in cases {
            assert_eq!(screen(Method::Vni, true, keys), expected, "{keys}");
        }
    }

    #[test]
    fn backspace_keeps_the_word_editable() {
        assert_eq!(telex("tieengs<<ng"), "tiếng");
        assert_eq!(telex("tieengs<<<ngs"), "tíng");
        assert_eq!(telex("ab<s"), "á");
    }

    #[test]
    fn expands_macros_at_the_end_of_a_word() {
        let mut engine = Engine::new(Options::default());
        engine.set_macros(HashMap::from([("ko".to_string(), "không".to_string())]));
        assert_eq!(engine.key('k'), Output::Pass);
        assert_eq!(engine.key('o'), Output::Pass);
        assert_eq!(engine.key(' '), Output::Replace { backspaces: 2, text: "không ".into() });
    }
}
