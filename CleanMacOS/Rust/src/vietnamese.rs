#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Tone {
    #[default]
    None,
    Acute,
    Grave,
    Hook,
    Tilde,
    Dot,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Mark {
    #[default]
    None,
    Circumflex,
    Breve,
    Horn,
    Stroke,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Letter {
    pub base: char,
    pub mark: Mark,
    pub upper: bool,
}

const TONED: &[(char, [char; 5])] = &[
    ('a', ['á', 'à', 'ả', 'ã', 'ạ']),
    ('ă', ['ắ', 'ằ', 'ẳ', 'ẵ', 'ặ']),
    ('â', ['ấ', 'ầ', 'ẩ', 'ẫ', 'ậ']),
    ('e', ['é', 'è', 'ẻ', 'ẽ', 'ẹ']),
    ('ê', ['ế', 'ề', 'ể', 'ễ', 'ệ']),
    ('i', ['í', 'ì', 'ỉ', 'ĩ', 'ị']),
    ('o', ['ó', 'ò', 'ỏ', 'õ', 'ọ']),
    ('ô', ['ố', 'ồ', 'ổ', 'ỗ', 'ộ']),
    ('ơ', ['ớ', 'ờ', 'ở', 'ỡ', 'ợ']),
    ('u', ['ú', 'ù', 'ủ', 'ũ', 'ụ']),
    ('ư', ['ứ', 'ừ', 'ử', 'ữ', 'ự']),
    ('y', ['ý', 'ỳ', 'ỷ', 'ỹ', 'ỵ']),
];

const MARKED: &[(char, char, Mark)] = &[
    ('ă', 'a', Mark::Breve),
    ('â', 'a', Mark::Circumflex),
    ('ê', 'e', Mark::Circumflex),
    ('ô', 'o', Mark::Circumflex),
    ('ơ', 'o', Mark::Horn),
    ('ư', 'u', Mark::Horn),
    ('đ', 'd', Mark::Stroke),
];

const INITIALS: &[&str] = &[
    "ngh", "ng", "nh", "ch", "gh", "gi", "kh", "ph", "qu", "th", "tr", "b", "c", "d", "đ", "g", "h", "k", "l", "m", "n", "p",
    "r", "s", "t", "v", "x", "",
];

const NUCLEI: &[&str] = &[
    "a", "ă", "â", "e", "ê", "i", "o", "ô", "ơ", "u", "ư", "y", "ai", "ao", "au", "ay", "âu", "ây", "eo", "êu", "ia", "iê",
    "iu", "oa", "oă", "oe", "oi", "oo", "ôi", "ơi", "ua", "uâ", "ue", "uê", "ui", "uô", "uơ", "uy", "ưa", "ưi", "ưu", "ươ",
    "yê", "oai", "oay", "oeo", "uây", "uôi", "uya", "uyê", "uyu", "ươi", "ươu", "iêu", "yêu", "ưo",
];

const FINALS: &[&str] = &["ch", "ng", "nh", "c", "m", "n", "p", "t", ""];

impl Letter {
    pub fn new(base: char, upper: bool) -> Self {
        Letter { base, mark: Mark::None, upper }
    }

    pub fn is_vowel(&self) -> bool {
        matches!(self.base, 'a' | 'e' | 'i' | 'o' | 'u' | 'y')
    }

    pub fn plain(&self) -> char {
        MARKED
            .iter()
            .find(|(_, base, mark)| *base == self.base && *mark == self.mark)
            .map_or(self.base, |(marked, _, _)| *marked)
    }

    pub fn render(&self, tone: Tone) -> char {
        let lower = apply_tone(self.plain(), tone);
        if self.upper {
            lower.to_uppercase().next().unwrap_or(lower)
        } else {
            lower
        }
    }
}

pub fn apply_tone(plain: char, tone: Tone) -> char {
    let index = match tone {
        Tone::None => return plain,
        Tone::Acute => 0,
        Tone::Grave => 1,
        Tone::Hook => 2,
        Tone::Tilde => 3,
        Tone::Dot => 4,
    };
    TONED.iter().find(|(vowel, _)| *vowel == plain).map_or(plain, |(_, forms)| forms[index])
}

pub fn decompose(ch: char) -> (Letter, Tone) {
    let upper = ch.is_uppercase();
    let lower = ch.to_lowercase().next().unwrap_or(ch);
    let tones = [Tone::Acute, Tone::Grave, Tone::Hook, Tone::Tilde, Tone::Dot];
    let (plain, tone) = TONED
        .iter()
        .find_map(|(vowel, forms)| forms.iter().position(|form| *form == lower).map(|index| (*vowel, tones[index])))
        .unwrap_or((lower, Tone::None));
    let letter = MARKED
        .iter()
        .find(|(marked, _, _)| *marked == plain)
        .map_or(Letter::new(plain, upper), |(_, base, mark)| Letter { base: *base, mark: *mark, upper });
    (letter, tone)
}

pub fn render_word(letters: &[Letter], tone: Tone, modern: bool) -> String {
    let target = if tone == Tone::None { None } else { tone_index(letters, modern) };
    letters
        .iter()
        .enumerate()
        .map(|(index, letter)| letter.render(if Some(index) == target { tone } else { Tone::None }))
        .collect()
}

pub fn vowel_range(letters: &[Letter]) -> Option<(usize, usize)> {
    let first = letters.iter().position(Letter::is_vowel)?;
    let mut start = first;
    let follows_vowel = |index: usize| letters.get(index).is_some_and(Letter::is_vowel);
    if first == 1 && letters[0].base == 'q' && letters[1].base == 'u' && follows_vowel(2) {
        start = 2;
    }
    if first == 1 && letters[0].base == 'g' && letters[1].base == 'i' && letters[1].mark == Mark::None && follows_vowel(2) {
        start = 2;
    }
    let mut end = start;
    while end + 1 < letters.len() && letters[end + 1].is_vowel() {
        end += 1;
    }
    Some((start, end))
}

pub fn tone_index(letters: &[Letter], modern: bool) -> Option<usize> {
    let (start, end) = vowel_range(letters)?;
    if let Some(marked) = (start..=end).rev().find(|&index| letters[index].mark != Mark::None) {
        return Some(marked);
    }
    let count = end - start + 1;
    let closed = end + 1 < letters.len();
    match count {
        1 => Some(start),
        2 if closed => Some(end),
        2 => {
            let pair = (letters[start].base, letters[end].base);
            let medial = matches!(pair, ('o', 'a') | ('o', 'e') | ('u', 'y'));
            Some(if medial && modern { end } else { start })
        }
        _ => Some(start + 1),
    }
}

pub fn is_valid_syllable(letters: &[Letter], tone: Tone) -> bool {
    let word: String = letters.iter().map(Letter::plain).collect();
    INITIALS.iter().any(|initial| {
        let Some(rest) = word.strip_prefix(initial) else { return false };
        FINALS.iter().any(|last| {
            let Some(nucleus) = rest.strip_suffix(last) else { return false };
            NUCLEI.contains(&nucleus)
                && spelling_allows(initial, nucleus)
                && (!matches!(*last, "c" | "ch" | "p" | "t") || matches!(tone, Tone::Acute | Tone::Dot))
        })
    })
}

fn spelling_allows(initial: &str, nucleus: &str) -> bool {
    let front = nucleus.starts_with(['e', 'ê', 'i', 'y']);
    match initial {
        "k" | "gh" | "ngh" => front,
        "c" | "g" | "ng" => !front || (initial == "g" && nucleus.starts_with('i')),
        "qu" => !nucleus.starts_with(['u', 'ư']),
        _ => true,
    }
}

pub fn letters_of(text: &str) -> (Vec<Letter>, Tone) {
    let mut tone = Tone::None;
    let letters = text
        .chars()
        .map(|ch| {
            let (letter, letter_tone) = decompose(ch);
            if letter_tone != Tone::None {
                tone = letter_tone;
            }
            letter
        })
        .collect();
    (letters, tone)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn word(text: &str) -> Vec<Letter> {
        letters_of(text).0
    }

    #[test]
    fn decomposes_and_renders_every_vietnamese_vowel() {
        for ch in "aáàảãạăắằẳẵặâấầẩẫậeéèẻẽẹêếềểễệiíìỉĩịoóòỏõọôốồổỗộơớờởỡợuúùủũụưứừửữựyýỳỷỹỵđ".chars() {
            let (letter, tone) = decompose(ch);
            assert_eq!(letter.render(tone), ch);
            let upper = ch.to_uppercase().next().unwrap();
            let (big, big_tone) = decompose(upper);
            assert!(big.upper);
            assert_eq!(big.render(big_tone), upper);
        }
    }

    #[test]
    fn places_tones_like_vietnamese_spelling() {
        let cases = [
            ("hoa", Tone::Grave, true, "hoà"),
            ("hoa", Tone::Grave, false, "hòa"),
            ("thuy", Tone::Acute, true, "thuý"),
            ("thuy", Tone::Acute, false, "thúy"),
            ("hoan", Tone::Grave, false, "hoàn"),
            ("mai", Tone::Acute, true, "mái"),
            ("mua", Tone::Acute, true, "múa"),
            ("nguoi", Tone::Grave, true, "nguòi"),
            ("ngươi", Tone::Grave, true, "người"),
            ("tiêng", Tone::Acute, true, "tiếng"),
            ("quy", Tone::Acute, true, "quý"),
            ("qua", Tone::Hook, true, "quả"),
            ("gia", Tone::Grave, true, "già"),
            ("gin", Tone::Grave, true, "gìn"),
            ("giưa", Tone::Tilde, true, "giữa"),
            ("khuyêt", Tone::Acute, true, "khuyết"),
            ("ngoai", Tone::Grave, true, "ngoài"),
            ("xoay", Tone::Acute, true, "xoáy"),
            ("cưu", Tone::Acute, true, "cứu"),
            ("thuơ", Tone::Hook, true, "thuở"),
        ];
        for (text, tone, modern, expected) in cases {
            assert_eq!(render_word(&word(text), tone, modern), expected, "{text}");
        }
    }

    #[test]
    fn checks_vietnamese_syllables() {
        for valid in ["tiếng", "được", "người", "quý", "giữa", "khuyết", "nghiêng", "ăn", "ạ", "học", "gì", "kìa", "ki"] {
            let (letters, tone) = letters_of(valid);
            assert!(is_valid_syllable(&letters, tone), "{valid}");
        }
        for invalid in ["class", "hello", "windows", "cè", "ngi", "àc"] {
            let (letters, tone) = letters_of(invalid);
            assert!(!is_valid_syllable(&letters, tone), "{invalid}");
        }
    }
}
