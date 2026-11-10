package project

import "core:strings"
import "core:unicode/utf8"

// Retry only the most recent star. Both literal comparisons and ? advance
// by Unicode scalar, independent of filesystem case or normalization rules.
@(private)
segment_matches :: proc(pattern, name: string) -> bool {
	p, n, star, retry := 0, 0, -1, 0
	for n < len(name) {
		if p < len(pattern) && pattern[p] == '*' {
			p += 1
			star, retry = p, n
			continue
		}
		char, width := utf8.decode_rune_in_string(name[n:])
		if p < len(pattern) {
			lit, w := utf8.decode_rune_in_string(pattern[p:])
			if lit == '?' || lit == char {
				p += w
				n += width
				continue
			}
		}
		if star < 0 || retry >= len(name) do return false
		_, step := utf8.decode_rune_in_string(name[retry:])
		retry += step
		p, n = star, retry
	}
	for p < len(pattern) && pattern[p] == '*' do p += 1
	return p == len(pattern)
}

@(private)
matches :: proc(pattern, relative: string, dir: bool) -> bool {
	pattern := pattern
	if strings.has_suffix(pattern, "/") {
		if !dir do return false
		pattern = pattern[:len(pattern)-1]
	}
	// Slice views only; retry ** at successive segment boundaries.
	p, n := pattern, relative
	rest, retry: string
	star := false
	for n != "" {
		pp, nn := p, n
		part, has := strings.split_iterator(&pp, "/")
		name, _ := strings.split_iterator(&nn, "/")
		if has && part == "**" {
			star, rest, retry, p = true, pp, n, pp
			continue
		}
		if has && segment_matches(part, name) { p, n = pp, nn; continue }
		if !star || retry == "" do return false
		_, _ = strings.split_iterator(&retry, "/")
		p, n = rest, retry
	}
	for part in strings.split_iterator(&p, "/") {
		if part != "**" do return false
	}
	return true
}
