#[derive(Debug, Clone, Copy, PartialEq)]
enum Family {
    Temperature,
    Length,
    Mass,
    Data,
    Time,
    Volume,
}

struct Unit {
    symbol: &'static str,
    names: &'static [&'static str],
    family: Family,
    factor: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Conversion {
    pub value: f64,
    pub from: String,
    pub to: String,
    pub result: f64,
}

const CONNECTORS: [&str; 7] = ["to", "in", "into", "as", "→", "->", ">"];
const MIN_WORDS: usize = 3;
const MAX_WORDS: usize = 8;
const KELVIN_OFFSET: f64 = 273.15;

const UNITS: &[Unit] = &[
    Unit { symbol: "°C", names: &["c", "°c", "celsius", "degc"], family: Family::Temperature, factor: 1.0 },
    Unit { symbol: "°F", names: &["f", "°f", "fahrenheit", "degf"], family: Family::Temperature, factor: 1.0 },
    Unit { symbol: "K", names: &["k", "kelvin"], family: Family::Temperature, factor: 1.0 },
    Unit { symbol: "mm", names: &["mm", "millimeter", "millimeters", "millimetre", "millimetres"], family: Family::Length, factor: 0.001 },
    Unit { symbol: "cm", names: &["cm", "centimeter", "centimeters", "centimetre", "centimetres"], family: Family::Length, factor: 0.01 },
    Unit { symbol: "m", names: &["m", "meter", "meters", "metre", "metres"], family: Family::Length, factor: 1.0 },
    Unit { symbol: "km", names: &["km", "kilometer", "kilometers", "kilometre", "kilometres"], family: Family::Length, factor: 1000.0 },
    Unit { symbol: "in", names: &["in", "inch", "inches", "″", "\""], family: Family::Length, factor: 0.0254 },
    Unit { symbol: "ft", names: &["ft", "foot", "feet", "′", "'"], family: Family::Length, factor: 0.3048 },
    Unit { symbol: "yd", names: &["yd", "yard", "yards"], family: Family::Length, factor: 0.9144 },
    Unit { symbol: "mi", names: &["mi", "mile", "miles"], family: Family::Length, factor: 1609.344 },
    Unit { symbol: "mg", names: &["mg", "milligram", "milligrams"], family: Family::Mass, factor: 0.001 },
    Unit { symbol: "g", names: &["g", "gram", "grams"], family: Family::Mass, factor: 1.0 },
    Unit { symbol: "kg", names: &["kg", "kilogram", "kilograms", "kilo", "kilos"], family: Family::Mass, factor: 1000.0 },
    Unit { symbol: "t", names: &["t", "ton", "tons", "tonne", "tonnes"], family: Family::Mass, factor: 1_000_000.0 },
    Unit { symbol: "oz", names: &["oz", "ounce", "ounces"], family: Family::Mass, factor: 28.349_523_125 },
    Unit { symbol: "lb", names: &["lb", "lbs", "pound", "pounds"], family: Family::Mass, factor: 453.592_37 },
    Unit { symbol: "B", names: &["b", "byte", "bytes"], family: Family::Data, factor: 1.0 },
    Unit { symbol: "kB", names: &["kb", "kilobyte", "kilobytes"], family: Family::Data, factor: 1e3 },
    Unit { symbol: "MB", names: &["mb", "megabyte", "megabytes"], family: Family::Data, factor: 1e6 },
    Unit { symbol: "GB", names: &["gb", "gigabyte", "gigabytes"], family: Family::Data, factor: 1e9 },
    Unit { symbol: "TB", names: &["tb", "terabyte", "terabytes"], family: Family::Data, factor: 1e12 },
    Unit { symbol: "KiB", names: &["kib", "kibibyte", "kibibytes"], family: Family::Data, factor: 1024.0 },
    Unit { symbol: "MiB", names: &["mib", "mebibyte", "mebibytes"], family: Family::Data, factor: 1_048_576.0 },
    Unit { symbol: "GiB", names: &["gib", "gibibyte", "gibibytes"], family: Family::Data, factor: 1_073_741_824.0 },
    Unit { symbol: "TiB", names: &["tib", "tebibyte", "tebibytes"], family: Family::Data, factor: 1_099_511_627_776.0 },
    Unit { symbol: "bit", names: &["bit", "bits"], family: Family::Data, factor: 0.125 },
    Unit { symbol: "ms", names: &["ms", "millisecond", "milliseconds"], family: Family::Time, factor: 0.001 },
    Unit { symbol: "s", names: &["s", "sec", "secs", "second", "seconds"], family: Family::Time, factor: 1.0 },
    Unit { symbol: "min", names: &["min", "mins", "minute", "minutes"], family: Family::Time, factor: 60.0 },
    Unit { symbol: "h", names: &["h", "hr", "hrs", "hour", "hours"], family: Family::Time, factor: 3600.0 },
    Unit { symbol: "d", names: &["d", "day", "days"], family: Family::Time, factor: 86_400.0 },
    Unit { symbol: "wk", names: &["wk", "wks", "week", "weeks"], family: Family::Time, factor: 604_800.0 },
    Unit { symbol: "yr", names: &["yr", "yrs", "year", "years"], family: Family::Time, factor: 31_536_000.0 },
    Unit { symbol: "ml", names: &["ml", "milliliter", "milliliters", "millilitre", "millilitres"], family: Family::Volume, factor: 1.0 },
    Unit { symbol: "l", names: &["l", "liter", "liters", "litre", "litres"], family: Family::Volume, factor: 1000.0 },
    Unit { symbol: "gal", names: &["gal", "gallon", "gallons"], family: Family::Volume, factor: 3785.411_784 },
    Unit { symbol: "qt", names: &["qt", "quart", "quarts"], family: Family::Volume, factor: 946.352_946 },
    Unit { symbol: "fl oz", names: &["fl oz", "floz"], family: Family::Volume, factor: 29.573_529_562_5 },
    Unit { symbol: "cup", names: &["cup", "cups"], family: Family::Volume, factor: 236.588_236_5 },
];

pub fn convert(input: &str) -> Option<Conversion> {
    let tokens = split(&input.to_lowercase());
    if !(MIN_WORDS..=MAX_WORDS).contains(&tokens.len()) {
        return None;
    }
    let (left, target) = (1..tokens.len()).rev().find_map(|index| {
        if !CONNECTORS.contains(&tokens[index].as_str()) {
            return None;
        }
        let target = unit(&tokens[index + 1..].join(" "))?;
        Some((&tokens[..index], target))
    })?;
    let (value, source) = quantity(left)?;
    if source.family != target.family {
        return None;
    }
    let result = if source.family == Family::Temperature {
        from_kelvin(to_kelvin(value, source.symbol), target.symbol)
    } else {
        value * source.factor / target.factor
    };
    result.is_finite().then(|| Conversion { value, from: source.symbol.to_string(), to: target.symbol.to_string(), result })
}

fn split(text: &str) -> Vec<String> {
    let mut spaced = String::with_capacity(text.len() * 2);
    let mut previous_digit = false;
    for ch in text.replace("->", " -> ").replace('→', " → ").chars() {
        let is_digit = ch.is_ascii_digit() || ch == '.' || ch == ',';
        let is_mark = matches!(ch, '′' | '″' | '\'' | '"');
        if (previous_digit && !is_digit && !ch.is_whitespace()) || is_mark {
            spaced.push(' ');
        }
        spaced.push(ch);
        if is_mark {
            spaced.push(' ');
        }
        previous_digit = is_digit;
    }
    spaced.split_whitespace().map(str::to_string).collect()
}

fn unit(name: &str) -> Option<&'static Unit> {
    UNITS.iter().find(|unit| unit.names.contains(&name))
}

fn number(text: &str) -> Option<f64> {
    text.replace(',', ".").parse::<f64>().ok()
}

fn quantity(tokens: &[String]) -> Option<(f64, &'static Unit)> {
    if let (Some(amount), Some(whole)) = (tokens.first().and_then(|text| number(text)), unit(&tokens.get(1..)?.join(" "))) {
        return amount.is_finite().then_some((amount, whole));
    }
    match tokens {
        [amount, name] => Some((number(amount)?, unit(name)?)),
        [amount, name, rest] => {
            let main = unit(name)?;
            let extra = number(rest)?;
            (main.symbol == "ft").then(|| (number(amount).unwrap_or(f64::NAN) + extra / 12.0, main))
        }
        [amount, name, rest, rest_name] => {
            let main = unit(name)?;
            let minor = unit(rest_name)?;
            (main.family == minor.family && main.family != Family::Temperature)
                .then(|| (number(amount).unwrap_or(f64::NAN) + number(rest).unwrap_or(f64::NAN) * minor.factor / main.factor, main))
        }
        _ => None,
    }
    .filter(|(value, _)| value.is_finite())
}

fn to_kelvin(value: f64, symbol: &str) -> f64 {
    match symbol {
        "°C" => value + KELVIN_OFFSET,
        "°F" => (value - 32.0) * 5.0 / 9.0 + KELVIN_OFFSET,
        _ => value,
    }
}

fn from_kelvin(value: f64, symbol: &str) -> f64 {
    match symbol {
        "°C" => value - KELVIN_OFFSET,
        "°F" => (value - KELVIN_OFFSET) * 9.0 / 5.0 + 32.0,
        _ => value,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn result(text: &str) -> Option<f64> {
        convert(text).map(|conversion| conversion.result)
    }

    fn near(text: &str, expected: f64) -> bool {
        result(text).map_or(false, |value| (value - expected).abs() < 1e-6 * expected.abs().max(1.0))
    }

    #[test]
    fn converts_within_a_family() {
        assert!(near("100 km to mi", 62.137_119_223_7));
        assert!(near("20c to f", 68.0));
        assert!(near("32 f in c", 0.0));
        assert!(near("0 c to k", 273.15));
        assert!(near("5 in to cm", 12.7));
        assert!(near("1 GiB to MB", 1073.741_824));
        assert!(near("2 h to min", 120.0));
        assert!(near("1 gal to l", 3.785_411_784));
        assert!(near("3 kg as lb", 6.613_867_865_5));
        assert!(near("1 fl oz to ml", 29.573_529_562_5));
        assert!(near("8 bits -> b", 1.0));
        assert!(near("90 min → h", 1.5));
    }

    #[test]
    fn reads_feet_and_inches() {
        assert!(near("5ft 11 to cm", 180.34));
        assert!(near("5′11″ to cm", 180.34));
        assert!(near("5 ft 11 in to cm", 180.34));
        assert_eq!(convert("5 in to cm").map(|c| c.from), Some("in".to_string()));
    }

    #[test]
    fn refuses_mismatched_or_unknown_units() {
        for text in ["5 km to kg", "hello to world", "5 to cm", "km to mi", "5 km to", "1 2 3 4 5 6 7 8 9 km to mi"] {
            assert_eq!(convert(text), None, "{text}");
        }
    }
}
