#+private
package cli

import "core:fmt"
import "core:strings"
import "kadai:app"

// Split at OR boundaries so AND binds tighter. Values for these fields are
// single tokens in task frontmatter, so the grammar needs no nested quoting.
parse_list_expression :: proc(expression: string) -> ([][]app.List_Predicate, string) {
	alloc_error :: "cannot allocate --where expression"
	words, err := strings.fields(expression, context.temp_allocator)
	if err != nil do return nil, alloc_error
	if len(words) % 2 == 0 do return nil, "--where expects predicates separated by AND or OR"
	count := len(words) / 2 + 1
	predicates, p_err := make([]app.List_Predicate, count, context.temp_allocator)
	groups, g_err := make([][]app.List_Predicate, count, context.temp_allocator)
	if p_err != nil || g_err != nil do return nil, alloc_error
	start, group := 0, 0
	for &p, i in predicates {
		if i > 0 {
			switch words[2 * i - 1] {
			case "AND":
			case "OR":
				groups[group] = predicates[start:i]
				group += 1
				start = i
			case:
				return nil, fmt.tprintf("--where expected AND or OR, got %q", words[2 * i - 1])
			}
		}
		word := words[2 * i]
		name, _, value := strings.partition(word, "=")
		if name == "" || value == "" || strings.contains(value, "=") {
			return nil, fmt.tprintf("--where expected FIELD=VALUE or FIELD!=VALUE, got %q", word)
		}
		p.value, p.negated = value, strings.has_suffix(name, "!")
		switch strings.trim_suffix(name, "!") {
		case "id":
			p.field = .ID
		case "status":
			p.field = .Status
		case "priority":
			p.field = .Priority
		case "tag":
			p.field = .Tag
		case "due":
			p.field = .Due
		case:
			return nil, fmt.tprintf("unknown --where field in %q", word)
		}
	}
	groups[group] = predicates[start:]
	return groups[:group + 1], ""
}
