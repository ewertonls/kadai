package document

import "base:intrinsics"
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
	case .Plain:
		return raw == node.text
	case .Single_Quoted:
		return len(raw) >= 2 && raw[0] == '\'' && raw[len(raw) - 1] == '\''
	case .Double_Quoted:
		return len(raw) >= 2 && raw[0] == '"' && raw[len(raw) - 1] == '"'
	case .Unknown, .Literal, .Folded, .Block, .Flow:
		return false
	}
	return false
}

// In a block mapping, quotes are necessary when a plain token would change
// the text, resolve to null, or introduce YAML syntax.
@(private)
plain_text_allowed :: proc(s: string) -> bool {
	if yaml.is_plain_null(s) ||
	   s[0] == ' ' ||
	   s[0] == '\t' ||
	   s[len(s) - 1] == ' ' ||
	   s[len(s) - 1] == '\t' {
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
	return(
		!strings.has_suffix(s, ":") &&
		!strings.contains(s, ": ") &&
		!strings.contains(s, ":\t") &&
		!strings.contains(s, " #") &&
		!strings.contains(s, "\t#") \
	)
}

@(private)
replacement_style :: proc(original: yaml.Node_Style, text: string) -> yaml.Node_Style {
	if original == .Double_Quoted {
		return original
	}
	for r in text {
		if (r < 0x20 && r != '\t') ||
		   (0x7f <= r && r < 0xa0) ||
		   r == '\u2028' ||
		   r == '\u2029' ||
		   r == '\uFFFE' ||
		   r == '\uFFFF' {
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
quoted_token :: proc(
	text: string,
	style: yaml.Node_Style,
	size: int,
) -> (
	token: string,
	err: runtime.Allocator_Error,
) {
	buf := make([]byte, size) or_return
	if len(buf) != size {
		return "", .Out_Of_Memory
	}
	if style == .Double_Quoted {
		quoted, ok := strconv.quote_string_buf(buf, text)
		assert(ok) // sized with the same rune encoder
		return quoted, nil
	}
	buf[0], buf[size - 1] = '\'', '\''
	i := 1
	for j in 0 ..< len(text) {
		buf[i] = text[j]
		i += 1
		if text[j] == '\'' {
			buf[i] = '\''
			i += 1
		}
	}
	return string(buf), nil
}

// A string is always scalar text. An Inline_Collection is one already encoded
// YAML flow sequence or mapping. The zero value represents explicit YAML null.
Inline_Collection :: struct {
	yaml: string,
}
Field_Value       :: union {
	string,
	Inline_Collection,
}

@(private)
matches_value :: proc(node: ^yaml.Node, value: Field_Value) -> bool {
	switch v in value {
	case string:
		return(
			node.kind != .Null &&
			node.kind != .Sequence &&
			node.kind != .Mapping &&
			node.text == v \
		)
	case Inline_Collection:
		return node.style == .Flow && (node.kind == .Mapping || node.kind == .Sequence)
	}
	return node.kind == .Null
}

@(private)
compose_field_value :: proc(
	doc: ^Task_Document,
	field: string,
	span: Byte_Range,
	value: Field_Value,
	style: yaml.Node_Style,
	loc: yaml.Location,
	indent := "",
	eol := "",
) -> (
	candidate: string,
	err: Header_Edit_Error,
) {
	entry_bytes := 0
	if eol != "" {
		entry_bytes = len(indent) + len(field) + len(": ") + len(eol)
	}
	token := "null"
	owned: string
	defer delete(owned)
	switch v in value {
	case string:
		// Bound the scan and quote expansion before allocating either buffer.
		_, _ = header_edit_sizes(
			doc,
			span,
			intrinsics.saturating_add(len(v), entry_bytes),
		) or_return
		if !utf8.valid_string(v) {
			return "",
				yaml.diagnostic(
					doc.path,
					"invalid_utf8",
					field,
					"Supply a valid UTF-8 field value.",
					loc,
				) or_return
		}
		encoding := replacement_style(style, v)
		token = v
		if encoding != .Plain {
			size := quoted_token_size(v, encoding)
			_, _ = header_edit_sizes(doc, span, size + entry_bytes) or_return
			owned = quoted_token(v, encoding, size) or_return
			token = owned
		}
	case Inline_Collection:
		token = v.yaml
		_, _ = header_edit_sizes(
			doc,
			span,
			intrinsics.saturating_add(len(token), entry_bytes),
		) or_return
		if token == "" ||
		   (token[0] != '[' && token[0] != '{') ||
		   strings.contains_any(token, "\r\n") {
			return "",
				yaml.diagnostic(
					doc.path,
					"unsafe_source_patch",
					field,
					"Supply one single-line YAML flow collection.",
					loc,
				) or_return
		}
	}
	if eol == "" {
		return compose_header_edit(doc, span, token)
	}
	return compose_header_parts(doc, span, {indent, field, ": ", token, eol})
}
