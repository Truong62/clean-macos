const MAX_LENGTH: usize = 120;
const MAX_DEPTH: usize = 32;
const OF_WORDS: [&str; 8] = ["of", "de", "da", "do", "von", "di", "del", "dal"];
const FUNCTIONS: [&str; 15] = [
    "sqrt", "abs", "sin", "cos", "tan", "asin", "acos", "atan", "ln", "log", "log10", "exp", "floor", "ceil", "round",
];

#[derive(Debug, Clone, PartialEq)]
pub struct Calculation {
    pub value: f64,
    pub closed: usize,
}

#[derive(Debug, Clone, PartialEq)]
enum Token {
    Number(f64),
    Constant(f64),
    Function(String),
    Plus,
    Minus,
    Times,
    Divide,
    Power,
    Percent,
    Of,
    Open(char),
    Close(char),
}

#[derive(Clone, Copy)]
struct Value {
    number: f64,
    is_percent: bool,
}

impl Value {
    fn plain(number: f64) -> Value {
        Value { number, is_percent: false }
    }
}

pub fn evaluate(input: &str) -> Option<Calculation> {
    let trimmed = input.trim();
    let text = trimmed.strip_suffix('=').unwrap_or(trimmed).trim();
    if text.is_empty() || text.chars().count() > MAX_LENGTH || looks_like_date_or_time(text) {
        return None;
    }
    let tokens = tokenize(text)?;
    if !has_operation(&tokens) {
        return None;
    }
    let mut parser = Parser { tokens, position: 0, depth: 0, closed: 0 };
    let value = parser.expression()?;
    if parser.position != parser.tokens.len() || !value.number.is_finite() {
        return None;
    }
    Some(Calculation { value: value.number, closed: parser.closed })
}

fn looks_like_date_or_time(text: &str) -> bool {
    let compact: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    let only = |separator: char| compact.chars().all(|c| c.is_ascii_digit() || c == separator);
    (compact.contains(':') && only(':'))
        || (compact.matches('-').count() == 2 && only('-'))
        || (compact.matches('/').count() == 2 && only('/'))
}

fn tokenize(text: &str) -> Option<Vec<Token>> {
    let chars: Vec<char> = text.chars().collect();
    let mut tokens = Vec::new();
    let mut index = 0;
    while index < chars.len() {
        let ch = chars[index];
        if ch.is_whitespace() {
            index += 1;
            continue;
        }
        if ch.is_ascii_digit() || ((ch == '.' || ch == ',') && chars.get(index + 1).map_or(false, |next| next.is_ascii_digit())) {
            let (number, next) = read_number(&chars, index)?;
            tokens.push(Token::Number(number));
            index = next;
            continue;
        }
        if ch.is_alphabetic() || ch == 'π' {
            let start = index;
            while index < chars.len() && (chars[index].is_alphabetic() || chars[index] == 'π') {
                index += 1;
            }
            let mut word: String = chars[start..index].iter().collect::<String>().to_lowercase();
            if word == "log" && chars.get(index) == Some(&'1') && chars.get(index + 1) == Some(&'0') {
                word.push_str("10");
                index += 2;
            }
            tokens.push(word_token(&word)?);
            continue;
        }
        tokens.push(match ch {
            '+' => Token::Plus,
            '-' | '−' => Token::Minus,
            '*' | '×' => Token::Times,
            '/' | '÷' => Token::Divide,
            '^' => Token::Power,
            '%' => Token::Percent,
            '(' | '[' => Token::Open(ch),
            ')' | ']' => Token::Close(ch),
            _ => return None,
        });
        index += 1;
    }
    Some(tokens)
}

fn word_token(word: &str) -> Option<Token> {
    match word {
        "pi" | "π" => Some(Token::Constant(std::f64::consts::PI)),
        "e" => Some(Token::Constant(std::f64::consts::E)),
        "x" => Some(Token::Times),
        _ if OF_WORDS.contains(&word) => Some(Token::Of),
        _ if FUNCTIONS.contains(&word) => Some(Token::Function(word.to_string())),
        _ => None,
    }
}

fn read_number(chars: &[char], start: usize) -> Option<(f64, usize)> {
    let mut index = start;
    while index < chars.len() && (chars[index].is_ascii_digit() || chars[index] == '.' || chars[index] == ',') {
        index += 1;
    }
    let body: String = chars[start..index].iter().collect();
    let mut number = normalize_number(&body)?;
    if index < chars.len() && (chars[index] == 'e' || chars[index] == 'E') {
        let mut cursor = index + 1;
        if cursor < chars.len() && (chars[cursor] == '+' || chars[cursor] == '-') {
            cursor += 1;
        }
        if cursor < chars.len() && chars[cursor].is_ascii_digit() {
            while cursor < chars.len() && chars[cursor].is_ascii_digit() {
                cursor += 1;
            }
            let exponent: String = chars[index..cursor].iter().collect();
            number.push_str(&exponent);
            index = cursor;
        }
    }
    number.parse::<f64>().ok().map(|value| (value, index))
}

fn normalize_number(body: &str) -> Option<String> {
    let dots = body.matches('.').count();
    let commas = body.matches(',').count();
    if dots > 0 && commas > 0 {
        let last = body.rfind(|c| c == '.' || c == ',')?;
        let (whole, fraction) = body.split_at(last);
        let digits: String = whole.chars().filter(|c| c.is_ascii_digit()).collect();
        return Some(format!("{}.{}", digits, &fraction[1..]));
    }
    let separator = if dots > 0 { '.' } else if commas > 0 { ',' } else { return Some(body.to_string()) };
    let groups: Vec<&str> = body.split(separator).collect();
    if is_thousands(&groups) {
        return Some(groups.concat());
    }
    if groups.len() == 2 {
        return Some(format!("{}.{}", groups[0], groups[1]));
    }
    None
}

fn is_thousands(groups: &[&str]) -> bool {
    let first = groups[0];
    groups.len() > 1
        && (1..=3).contains(&first.len())
        && !first.starts_with('0')
        && groups[1..].iter().all(|group| group.len() == 3 && group.chars().all(|c| c.is_ascii_digit()))
}

fn has_operation(tokens: &[Token]) -> bool {
    tokens.iter().enumerate().any(|(index, token)| match token {
        Token::Plus | Token::Minus => index > 0,
        Token::Times | Token::Divide | Token::Power | Token::Percent | Token::Of | Token::Function(_) => true,
        Token::Number(_) | Token::Constant(_) | Token::Close(_) => {
            matches!(tokens.get(index + 1), Some(Token::Constant(_)) | Some(Token::Function(_)) | Some(Token::Open(_)))
        }
        _ => false,
    })
}

struct Parser {
    tokens: Vec<Token>,
    position: usize,
    depth: usize,
    closed: usize,
}

impl Parser {
    fn peek(&self) -> Option<&Token> {
        self.tokens.get(self.position)
    }

    fn advance(&mut self) -> Option<Token> {
        let token = self.tokens.get(self.position).cloned();
        self.position += 1;
        token
    }

    fn expression(&mut self) -> Option<Value> {
        let mut left = self.term()?;
        while let Some(token) = self.peek().cloned() {
            let sign = match token {
                Token::Plus => 1.0,
                Token::Minus => -1.0,
                _ => break,
            };
            self.position += 1;
            let right = self.term()?;
            let change = if right.is_percent { left.number * right.number } else { right.number };
            left = Value::plain(left.number + sign * change);
        }
        Some(left)
    }

    fn term(&mut self) -> Option<Value> {
        let mut left = self.unary()?;
        loop {
            match self.peek().cloned() {
                Some(Token::Times) | Some(Token::Of) => {
                    self.position += 1;
                    left = Value::plain(left.number * self.unary()?.number);
                }
                Some(Token::Divide) => {
                    self.position += 1;
                    left = Value::plain(left.number / self.unary()?.number);
                }
                Some(Token::Constant(_)) | Some(Token::Function(_)) | Some(Token::Open(_)) => {
                    left = Value::plain(left.number * self.unary()?.number);
                }
                _ => break,
            }
        }
        Some(left)
    }

    fn unary(&mut self) -> Option<Value> {
        match self.peek() {
            Some(Token::Minus) => {
                self.position += 1;
                let value = self.unary()?;
                Some(Value { number: -value.number, is_percent: value.is_percent })
            }
            Some(Token::Plus) => {
                self.position += 1;
                self.unary()
            }
            _ => self.power(),
        }
    }

    fn power(&mut self) -> Option<Value> {
        let base = self.postfix()?;
        if self.peek() == Some(&Token::Power) {
            self.position += 1;
            let exponent = self.unary()?;
            return Some(Value::plain(base.number.powf(exponent.number)));
        }
        Some(base)
    }

    fn postfix(&mut self) -> Option<Value> {
        let mut value = self.primary()?;
        while self.peek() == Some(&Token::Percent) {
            self.position += 1;
            value = Value { number: value.number / 100.0, is_percent: true };
        }
        Some(value)
    }

    fn primary(&mut self) -> Option<Value> {
        match self.advance()? {
            Token::Number(number) | Token::Constant(number) => Some(Value::plain(number)),
            Token::Function(name) => {
                let open = match self.advance()? {
                    Token::Open(ch) => ch,
                    _ => return None,
                };
                let inner = self.group(open)?;
                apply(&name, inner.number).map(Value::plain)
            }
            Token::Open(ch) => self.group(ch).map(|value| Value::plain(value.number)),
            _ => None,
        }
    }

    fn group(&mut self, open: char) -> Option<Value> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return None;
        }
        let value = self.expression()?;
        self.depth -= 1;
        let expected = if open == '(' { ')' } else { ']' };
        match self.peek() {
            Some(Token::Close(ch)) if *ch == expected => {
                self.position += 1;
                Some(value)
            }
            None => {
                self.closed += 1;
                Some(value)
            }
            _ => None,
        }
    }
}

fn apply(name: &str, value: f64) -> Option<f64> {
    let result = match name {
        "sqrt" => value.sqrt(),
        "abs" => value.abs(),
        "sin" => value.sin(),
        "cos" => value.cos(),
        "tan" => value.tan(),
        "asin" => value.asin(),
        "acos" => value.acos(),
        "atan" => value.atan(),
        "ln" => value.ln(),
        "log" | "log10" => value.log10(),
        "exp" => value.exp(),
        "floor" => value.floor(),
        "ceil" => value.ceil(),
        "round" => value.round(),
        _ => return None,
    };
    result.is_finite().then_some(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn value(text: &str) -> Option<f64> {
        evaluate(text).map(|result| result.value)
    }

    fn close(text: &str, expected: f64) -> bool {
        value(text).map_or(false, |result| (result - expected).abs() < 1e-9)
    }

    #[test]
    fn follows_precedence_and_associativity() {
        assert!(close("2+2*3", 8.0));
        assert!(close("(2+3)*4", 20.0));
        assert!(close("2^3^2", 512.0));
        assert!(close("-2^2", -4.0));
        assert!(close("2^-1", 0.5));
        assert!(close("3 × 4 ÷ 2", 6.0));
        assert!(close("2x3", 6.0));
        assert!(close("10 − 4", 6.0));
        assert!(close("2+2=", 4.0));
    }

    #[test]
    fn multiplies_implicitly_and_knows_constants_and_functions() {
        assert!(close("2(3+4)", 14.0));
        assert!(close("2π", 2.0 * std::f64::consts::PI));
        assert!(close("(1+2)(3+4)", 21.0));
        assert!(close("sqrt(16)+1", 5.0));
        assert!(close("round(2.6)*e", 3.0 * std::f64::consts::E));
        assert!(close("[1+2]*3", 9.0));
        assert!(close("1e3+1", 1001.0));
        assert!(close("log10(1000)", 3.0));
        assert!(close("2e", 2.0 * std::f64::consts::E));
        assert!(close(".5*4", 2.0));
    }

    #[test]
    fn handles_percentages() {
        assert!(close("50% of 20", 10.0));
        assert!(close("200 + 10%", 220.0));
        assert!(close("200 - 10%", 180.0));
        assert!(close("20%", 0.2));
    }

    #[test]
    fn reads_both_decimal_marks() {
        assert!(close("1,5*2", 3.0));
        assert!(close("1.000.000/4", 250_000.0));
        assert!(close("1,234+1", 1235.0));
        assert!(close("1.234,5+0,5", 1235.0));
        assert!(close("0,25*4", 1.0));
    }

    #[test]
    fn closes_missing_brackets() {
        assert_eq!(evaluate("(1+2"), Some(Calculation { value: 3.0, closed: 1 }));
        assert_eq!(evaluate("sqrt((16"), Some(Calculation { value: 4.0, closed: 2 }));
        assert_eq!(evaluate("(1+2]"), None);
    }

    #[test]
    fn refuses_things_that_are_not_sums() {
        for text in ["10/0", "sqrt(-1)", "5", "-5", "pi", "2026-07-27", "27/07/2026", "10:30", "abc", "2 3", "sqrt 4", "", "((((((((((((((((((((((((((((((((((1))"] {
            assert_eq!(evaluate(text), None, "{text}");
        }
        assert_eq!(evaluate(&"1+".repeat(70)), None);
    }
}
