package storage

import "core:os"

// Project the remaining content and membership changes before arming recovery.
// The application can validate ID uniqueness and inbound references against
// the current inventory without storage interpreting task Markdown.
Recovery_Effect :: struct {
	path  : string,
	remove: bool,
	source: []byte,
}
Recovery_Check  :: proc(effects: []Recovery_Effect, data: rawptr) -> string

@(private)
check_recovery_effects :: proc(
	root: string,
	images: ^Directory,
	steps: []Step,
	mode: Recovery_Mode,
	check: Recovery_Check,
	data: rawptr,
	l: Journal_Limits,
	budget: ^i64,
) -> string {
	if check == nil do return ""
	content_changes := false
	for s in steps {
		if s.kind == .Create || s.kind == .Delete || s.kind == .Replace do content_changes = true
	}
	if !content_changes do return ""
	effects := make([dynamic]Recovery_Effect, context.temp_allocator)
	for s, i in steps {
		if s.kind == .Move || s.kind == .Move_Directory do return "cannot verify a mixed move and membership recovery"
		from, to, image := s.before, s.after, image_name(i, "next")
		if mode == .Rollback {from, to, image = s.after, s.restored, image_name(i, "restore")}
		path := child(root, s.path)
		dir, err := open_dir(slash(os.dir(path)))
		if err != nil do return os.error_string(err)
		current, e := entry_state(&dir, os.base(path), l.source)
		close_dir(&dir)
		if e != nil do return os.error_string(e)
		if current == to || mode == .Rollback && current == s.before do continue
		if current != from do return "source changed during recovery preflight"
		effect := Recovery_Effect {
			path   = s.path,
			remove = to == "-",
		}
		if !effect.remove {
			f, open_err := regular(images, image, mutation = true)
			if open_err != nil do return os.error_string(open_err)
			effect.source, err = read_bounded(f, int(min(i64(l.source), budget^)))
			os.close(f)
			if err != nil do return os.error_string(err)
			budget^ -= i64(len(effect.source))
		}
		if _, add_err := append(&effects, effect); add_err != nil do return "cannot allocate recovery plan"
	}
	if len(effects) == 0 do return ""
	return check(effects[:], data)
}
