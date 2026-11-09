package document

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "kadai:yaml"

@(private)
single_line_token :: proc(node: ^yaml.Node, raw: string) -> bool {
	if raw == "" || strings.contains_any(raw, "\r\n") {
		return false
	}
	switch node.style {
	case .Plain:         return raw == node.text
	case .Single_Quoted: return len(raw) >= 2 && raw[0] == '\'' && raw[len(raw)-1] == '\''
	case .Double_Quoted: return len(raw) >= 2 && raw[0] == '"' && raw[len(raw)-1] == '"'
	case .Unknown, .Literal, .Folded, .Block, .Flow: return false
	}
	return false
}

// In a block mapping, quotes are necessary when a plain token would change
// the text, resolve to null, or introduce YAML syntax.
@(private)
plain_text_allowed :: proc(s: string) -> bool {
	if yaml.is_plain_null(s) || s[0] == ' ' || s[0] == '\t' || s[len(s)-1] == ' ' || s[len(s)-1] == '\t' {
		return false
	}
	switch s[0] {
	case '!', '&', '*', '#', '{', '}', '[', ']', ',', '|', '>', '@', '`', '%', '"', '\'':
		return false
	case '-', '?', ':':
		if len(s) == 1 || s[1] == ' ' || s[1] == '\t' {
			return false
		}
	}
	return !strings.has_suffix(s, ":") && !strings.contains(s, ": ") && !strings.contains(s, ":\t") &&
	       !strings.contains(s, " #") && !strings.contains(s, "\t#")
}

@(private)
replacement_style :: proc(original: yaml.Node_Style, text: string) -> yaml.Node_Style {
	if original == .Double_Quoted {
		return original
	}
	for r in text {
		if (r < 0x20 && r != '\t') || (0x7f <= r && r < 0xa0) ||
		   r == '\u2028' || r == '\u2029' || r == '\uFFFE' || r == '\uFFFF' {
			return .Double_Quoted
		}
	}
	if original == .Plain && plain_text_allowed(text) {
		return .Plain
	}
	return .Single_Quoted
}

@(private)
quoted_token_size :: proc(text: string, style: yaml.Node_Style) -> int {
	if style == .Single_Quoted {
		return 2 + len(text) + strings.count(text, "'")
	}
	size := 2
	buf: [strconv.ESCAPED_RUNE_MAX_NEEDED_BYTES]byte
	for r in text {
		size += len(strconv.encode_and_escape_rune(buf[:], r, '"'))
	}
	return size
}

@(private)
quoted_token :: proc(text: string, style: yaml.Node_Style, size: int) -> (token: string, err: runtime.Allocator_Error) {
	buf := make([]byte, size) or_return
	if len(buf) != size {
		return "", .Out_Of_Memory
	}
	if style == .Double_Quoted {
		quoted, ok := strconv.quote_string_buf(buf, text)
		assert(ok) // sized with the same rune encoder
		return quoted, nil
	}
	buf[0], buf[size-1] = '\'', '\''
	i := 1
	for j in 0..<len(text) {
		buf[i] = text[j]
		i += 1
		if text[j] == '\'' {
			buf[i] = '\''
			i += 1
		}
	}
	return string(buf), nil
}

@(private)
matches_scalar :: proc(node: ^yaml.Node, value: Maybe(string)) -> bool {
	if text, ok := value.?; ok {
		return node.kind != .Null && node.kind != .Sequence && node.kind != .Mapping && node.text == text
	}
	return node.kind == .Null
}

@(private)
compose_scalar :: proc(doc: ^Task_Document, field: string, node: ^yaml.Node, raw: string, value: Maybe(string)) -> (candidate: string, err: Header_Edit_Error) {
	if matches_scalar(node, value) {
		return compose_header_edit(doc, node.span, raw)
	}
	text, has_text := value.?
	if !has_text {
		return compose_header_edit(doc, node.span, "null")
	}
	// UTF-8 text is a lower bound on its single-line token size. The document
	// ceiling also bounds the arithmetic and scanning in quoted_token_size.
	_, _ = header_edit_sizes(doc, node.span, len(text)) or_return
	if !utf8.valid_string(text) {
		return "", yaml.diagnostic(doc.path, "invalid_utf8", field, "Supply a valid UTF-8 field value.", markdown_location(doc.parts.header, node.location)) or_return
	}
	style := replacement_style(node.style, text)
	if style == .Plain {
		return compose_header_edit(doc, node.span, text)
	}
	size := quoted_token_size(text, style)
	_, _ = header_edit_sizes(doc, node.span, size) or_return
	token := quoted_token(text, style, size) or_return
	defer delete(token)
	return compose_header_edit(doc, node.span, token)
}
