// Source-aware YAML nodes shared by document and project readers.
package yaml

Node_Kind  :: enum {
	Absent,
	String,
	Null,
	Boolean,
	Integer,
	Float,
	Sequence,
	Mapping,
}
Node_Style :: enum {
	Unknown,
	Plain,
	Single_Quoted,
	Double_Quoted,
	Literal,
	Folded,
	Block,
	Flow,
}

Byte_Range :: struct {
	start, end: int,
}

Node :: struct {
	kind          : Node_Kind,
	style         : Node_Style,
	// Half-open byte offsets into the original YAML input.
	using location: Location,
	// Decoded scalar text. For numbers kind + text is lossless at any precision.
	text          : string,
	items         : [dynamic]Node,
	entries       : [dynamic]Entry,
}

Entry :: struct {
	key, value: Node,
}

lookup :: proc(mapping: ^Node, key: string) -> ^Node {
	if mapping == nil do return nil
	for &entry in mapping.entries {
		if entry.key.kind == .String && entry.key.text == key do return &entry.value
	}
	return nil
}

destroy :: proc(node: ^Node) {
	for &item in node.items do destroy(&item)
	for &entry in node.entries {
		destroy(&entry.key)
		destroy(&entry.value)
	}
	delete(node.items)
	delete(node.entries)
	delete(node.text)
	node^ = {}
}
