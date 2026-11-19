package document

import "core:strings"
import "kadai:yaml"

// On append, the encoded item goes between prefix and suffix. On removal,
// the replacement is empty except when the last block item becomes [].
@(private)
Item_Splice :: struct {
	span          : Byte_Range,
	prefix, suffix: string,
}

@(private)
null_item_splice :: proc(header: string, node: ^yaml.Node) -> (Item_Splice, bool) {
	span := node.span
	if span.start == span.end {
		if span.start == 0 || header[span.start - 1] != ':' {
			return {}, false
		}
		return {span, " [", "]"}, true
	}
	return {span, "[", "]"}, single_line_token(node, header[span.start:span.end])
}

@(private)
flow_item_splice :: proc(
	header: string,
	node: ^yaml.Node,
	index: int,
) -> (
	splice: Item_Splice,
	ok: bool,
) {
	raw := header[node.span.start:node.span.end]
	if len(raw) < 2 ||
	   raw[0] != '[' ||
	   raw[len(raw) - 1] != ']' ||
	   strings.contains_any(raw, "\r\n") {
		return {}, false
	}
	items := node.items[:]
	if len(items) == 0 {
		pos := node.span.start + 1
		return {{pos, pos}, "", ""}, true
	}
	last := len(items) - 1
	if index == len(items) {
		separator := ", "
		if last > 0 {
			separator = header[items[last - 1].span.end:items[last].span.start]
			if strings.trim(separator, " \t") != "," {
				return {}, false
			}
		}
		pos := items[last].span.end
		return {{pos, pos}, separator, ""}, true
	}

	span := items[index].span
	if index < last {
		end := items[index + 1].span.start
		if strings.trim(header[span.end:end], " \t") != "," {
			return {}, false
		}
		span.end = end
	} else if index > 0 {
		start := items[index - 1].span.end
		if strings.trim(header[start:span.start], " \t") != "," {
			return {}, false
		}
		span.start = start
	} else {
		// In a singleton [item,] the trailing comma also belongs to the item.
		tail := header[span.end:node.span.end - 1]
		if comma := strings.index_byte(tail, ','); comma >= 0 {
			span.end += comma + 1
		}
	}
	return {span = span}, true
}

@(private)
block_item_splice :: proc(
	header: string,
	node: ^yaml.Node,
	index, root_indent: int,
) -> (
	splice: Item_Splice,
	ok: bool,
) {
	items := node.items[:]
	adding := index == len(items)
	item := &items[min(index, len(items) - 1)]
	token := item.span
	if !single_line_token(item, header[token.start:token.end]) {
		return {}, false
	}
	start := line_start(header, token.start)
	prefix := header[start:token.start]
	dash := strings.trim_left(prefix, " ")
	if len(dash) < 2 || dash[0] != '-' || strings.trim_left(dash[1:], " \t") != "" {
		return {}, false
	}
	lf := strings.index_byte(header[token.end:], '\n')
	if lf < 0 {
		return {}, false
	}
	end := token.end + lf + 1
	tail := strings.trim(header[token.end:end - 1], " \t\r")
	if adding {
		point := Byte_Range{end, end}
		if (tail != "" && !strings.has_prefix(tail, "#")) || adjacent_comment(header, point) {
			return {}, false
		}
		return {span = point, prefix = prefix}, true
	}
	line := Byte_Range{start, end}
	if tail != "" || adjacent_comment(header, line) {
		return {}, false
	}
	if len(items) == 1 {
		// A flow value on its own line must be indented beneath the key.
		indent := len(prefix) - len(dash)
		empty := "  []" if indent == root_indent else "[]"
		return {span = {start + indent, token.end}, prefix = empty}, true
	}
	return {span = line}, true
}
