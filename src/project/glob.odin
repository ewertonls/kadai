package project

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

Glob_Budget :: struct {
	limit, used, observed: i64,
}

@(private)
glob_charge :: proc(budget: ^Glob_Budget, steps: i64) -> bool {
	if budget == nil do return true
	if steps > budget.limit - budget.used {
		max_i64: i64 = 0x7fff_ffff_ffff_ffff
		budget.observed = max_i64 if steps > max_i64 - budget.used else budget.used + steps
		return false
	}
	budget.used += steps
	return true
}

glob_limit_issue :: proc(budget: ^Glob_Budget) -> string {
	return fmt.tprintf("exclude_match_steps limit exceeded (observed %d, limit %d)", budget.observed, budget.limit)
}

// Retry only the most recent star. Both literal comparisons and ? advance
// by Unicode scalar, independent of filesystem case or normalization rules.
@(private)
segment_matches :: proc(pattern, name: string, budget: ^Glob_Budget) -> (matched, ok: bool) {
	p, n, star, retry := 0, 0, -1, 0
	for n < len(name) {
		if p < len(pattern) && pattern[p] == '*' {
			if !glob_charge(budget, 1) do return false, false
			p += 1
			star, retry = p, n
			continue
		}
		char, width := utf8.decode_rune_in_string(name[n:])
		if p < len(pattern) {
			lit, w := utf8.decode_rune_in_string(pattern[p:])
			if !glob_charge(budget, i64(width+w)) do return false, false
			if lit == '?' || lit == char {
				p += w
				n += width
				continue
			}
		} else if !glob_charge(budget, i64(width)) {
			return false, false
		}
		if star < 0 || retry >= len(name) do return false, true
		_, step := utf8.decode_rune_in_string(name[retry:])
		if !glob_charge(budget, i64(step)) do return false, false
		retry += step
		p, n = star, retry
	}
	for p < len(pattern) && pattern[p] == '*' {
		if !glob_charge(budget, 1) do return false, false
		p += 1
	}
	return p == len(pattern), true
}

@(private)
matches :: proc(pattern, relative: string, dir: bool, budget: ^Glob_Budget = nil) -> (matched, ok: bool) {
	if !glob_charge(budget, 1) do return false, false
	pattern := pattern
	if strings.has_suffix(pattern, "/") {
		if !dir do return false, true
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
		if !glob_charge(budget, i64(len(part)+len(name)+2)) do return false, false
		if has && part == "**" {
			star, rest, retry, p = true, pp, n, pp
			continue
		}
		if has {
			part_matched, complete := segment_matches(part, name, budget)
			if !complete do return false, false
			if part_matched { p, n = pp, nn; continue }
		}
		if !star || retry == "" do return false, true
		skipped, _ := strings.split_iterator(&retry, "/")
		if !glob_charge(budget, i64(len(skipped)+1)) do return false, false
		p, n = rest, retry
	}
	for part in strings.split_iterator(&p, "/") {
		if !glob_charge(budget, i64(len(part)+1)) do return false, false
		if part != "**" do return false, true
	}
	return true, true
}
