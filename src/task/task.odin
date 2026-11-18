// Single-task field rules, independent of YAML and filesystem access.
package task

import "core:slice"
import "core:time/datetime"
import "core:unicode"

Vocabulary :: struct {
	additional_statuses: []string,
	// A configured list replaces the built-ins. Nil selects the defaults.
	priorities:          []string,
}

@(private)
ascii_alnum :: proc(c: u8) -> bool {
	return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9'
}

valid_id :: proc(s: string) -> bool {
	if s == "" || !ascii_alnum(s[0]) || !ascii_alnum(s[len(s) - 1]) do return false
	for i in 0 ..< len(s) {
		c := s[i]
		if !ascii_alnum(c) && c != '-' && c != '_' && c != '.' do return false
	}
	return true
}

valid_title :: proc(s: string) -> bool {
	nonblank := false
	for c in s {
		switch c {
		case '\n', '\r', '\v', '\f', '\u0085', '\u2028', '\u2029':
			return false
		}
		if !unicode.is_space(c) do nonblank = true
	}
	return nonblank
}

valid_tag :: proc(s: string) -> bool {
	for c in s {
		if !('a' <= c && c <= 'z' ||
			   '0' <= c && c <= '9' ||
			   c == '-' ||
			   c == '_' ||
			   c == '.' ||
			   c == '/') {
			return false
		}
	}
	return s != ""
}

valid_slug :: proc(s: string) -> bool {
	if s == "" || s[0] < 'a' || s[0] > 'z' do return false
	for c in s[1:] {
		if !('a' <= c && c <= 'z' || '0' <= c && c <= '9' || c == '-' || c == '_') do return false
	}
	return true
}

valid_status :: proc(s: string, vocab: Vocabulary) -> bool {
	switch s {
	case "todo", "in_progress", "blocked", "done", "canceled":
		return true
	}
	return valid_slug(s) && slice.contains(vocab.additional_statuses, s)
}

@(private, rodata)
DEFAULT_PRIORITIES := [?]string{"low", "medium", "high", "critical"}

priority_order :: proc(vocab: Vocabulary) -> []string {
	if vocab.priorities != nil do return vocab.priorities
	return DEFAULT_PRIORITIES[:]
}

valid_priority :: proc(s: string, vocab: Vocabulary) -> bool {
	return valid_slug(s) && slice.contains(priority_order(vocab), s)
}

@(private)
decimal_component :: proc(s: string) -> int {
	n := 0
	for c in s {
		if c < '0' || c > '9' do return -1
		n = 10 * n + int(c - '0')
	}
	return n
}

valid_due :: proc(s: string) -> bool {
	if len(s) != 10 && len(s) != 20 && len(s) != 25 do return false

	if s[4] != '-' || s[7] != '-' do return false

	year := decimal_component(s[:4])
	month, day := decimal_component(s[5:7]), decimal_component(s[8:10])

	if year < 0 || datetime.validate_year_month_day(year, month, day) != .None do return false

	if len(s) == 10 do return true

	if s[10] != 'T' || s[13] != ':' || s[16] != ':' do return false

	hh, mm, ss :=
		decimal_component(s[11:13]), decimal_component(s[14:16]), decimal_component(s[17:19])

	if datetime.validate_hour_minute_second(hh, mm, ss, 0) != .None do return false

	if len(s) == 20 do return s[19] == 'Z'

	if (s[19] != '+' && s[19] != '-') || s[22] != ':' do return false

	hours, minutes := decimal_component(s[20:22]), decimal_component(s[23:])

	return 0 <= hours && hours < 24 && 0 <= minutes && minutes < 60
}
