package yaml

import "core:strings"

is_plain_null :: proc(s: string) -> bool {
	return s == "" || s == "~" || s == "null" || s == "Null" || s == "NULL"
}

@(private)
digit_count :: proc(s: string) -> int {
	i := 0
	for i < len(s) && '0' <= s[i] && s[i] <= '9' do i += 1
	return i
}

// YAML 1.2.2 Core Schema, section 10.3.2. Never pass numeric text through a
// machine integer or float. A later consumer can choose its own representation.
@(private)
plain_kind :: proc(s: string) -> Node_Kind {
	if is_plain_null(s) {
		return .Null
	}
	switch s {
	case "true", "True", "TRUE", "false", "False", "FALSE": return .Boolean
	case ".nan", ".NaN", ".NAN": return .Float
	}

	if strings.has_prefix(s, "0o") || strings.has_prefix(s, "0x") {
		if len(s) == 2 do return .String
		for c in s[2:] {
			if s[1] == 'o' {
				if c < '0' || c > '7' do return .String
			} else if !(('0' <= c && c <= '9') || ('a' <= c && c <= 'f') || ('A' <= c && c <= 'F')) {
				return .String
			}
		}
		return .Integer
	}

	number := s
	if s[0] == '+' || s[0] == '-' do number = s[1:]
	switch number {
	case ".inf", ".Inf", ".INF": return .Float
	}
	whole := digit_count(number)
	if whole > 0 && whole == len(number) do return .Integer
	i := whole
	if i < len(number) && number[i] == '.' {
		i += 1
		fraction := digit_count(number[i:])
		if whole == 0 && fraction == 0 do return .String
		i += fraction
	} else if whole == 0 {
		return .String
	}
	if i < len(number) && (number[i] == 'e' || number[i] == 'E') {
		i += 1
		if i < len(number) && (number[i] == '+' || number[i] == '-') do i += 1
		exponent := digit_count(number[i:])
		if exponent == 0 do return .String
		i += exponent
	}
	return .Float if i == len(number) else .String
}

// Magnitude digits borrow the scalar. Keeping the radix avoids conversions
// proportional to the numeric value or narrowing to a machine integer.
Integer :: struct {
	digits:   string,
	base:     int,
	negative: bool,
}

integer_value :: proc(node: ^Node) -> (Integer, bool) {
	if node == nil || node.kind != .Integer do return {}, false
	digits := node.text
	base := 10
	negative := digits[0] == '-'
	if digits[0] == '+' || negative {
		digits = digits[1:]
	} else if strings.has_prefix(digits, "0o") {
		base, digits = 8, digits[2:]
	} else if strings.has_prefix(digits, "0x") {
		base, digits = 16, digits[2:]
	}
	for len(digits) > 1 && digits[0] == '0' do digits = digits[1:]
	return {digits, base, negative && digits != "0"}, true
}
