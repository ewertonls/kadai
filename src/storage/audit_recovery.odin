package storage

import "core:fmt"
import "core:os"
import "core:strings"

@(private)
Recovery_Audit :: struct {
	using result                     : State_Audit,
	root                             : string,
	limits                           : Journal_Limits,
	entries                          : int,
	control_bytes, image_bytes, nodes: i64,
}

@(private)
audit_io :: proc(a: ^Recovery_Audit, path: string, e: os.Error, dimension: string) {
	msg := os.error_string(e)
	if e == .Short_Buffer do msg = fmt.tprintf("%s limit exceeded", dimension)
	state_problem(&a.result, path, "recovery_incomplete", msg, true)
}

@(private)
hex_digest :: proc(value: string) -> bool {
	return len(value) == 64 && strings.trim_left(value, "0123456789abcdef") == ""
}

@(private)
snapshot_difference :: proc(expected, actual: string) -> string {
	if actual == "-" do return "Recovery image is missing."
	if expected == "-" do return "Found an unexpected recovery image."
	// Both stamps contain device.inode.content:metadata.
	expected_payload, actual_payload := payload_signature(expected), payload_signature(actual)
	expected_id := expected[:len(expected) - len(expected_payload)]
	actual_id := actual[:len(actual) - len(actual_payload)]
	changed := make([dynamic]string, 0, 3, context.temp_allocator)
	if expected_id != actual_id do append(&changed, "identity")
	if expected_payload[:64] != actual_payload[:64] do append(&changed, "content")
	if expected_payload[65:] != actual_payload[65:] do append(&changed, "metadata")
	return fmt.tprintf(
		"Recovery image differs from the recorded %s.",
		strings.join(changed[:], ", ", context.temp_allocator),
	)
}

// Compare live files only for an active intent. Completed tasks can
// legitimately have changed since commit.
@(private)
audit_operation :: proc(a: ^Recovery_Audit, vault: ^Directory, id: string, pointers: []string) {
	path := child(vault.path, id)
	op, e := open_dir(path, private_leaf = true)
	if e != nil {audit_io(a, path, e, "directory"); return}
	defer close_dir(&op)
	entries, dir_err := state_entries(&op, &a.entries)
	if dir_err != nil {audit_io(a, path, dir_err, "filesystem_entries"); return}
	files := make(map[string]bool, len(entries), context.temp_allocator)
	for fi in entries {
		if fi.type !=
		   .Regular {state_problem(&a.result, child(path, fi.name), "unsafe_recovery_entry", "Expected a regular recovery file.")}
		files[fi.name] = true
	}
	active := false
	for ptr in pointers {if ptr != "" && ptr[:32] == id do active = true}
	if "plan" not_in files &&
	   !active &&
	   "committed" not_in files &&
	   "rolled-back" not_in files &&
	   "rollback" not_in files {
		state_problem(
			&a.result,
			path,
			"uncommitted_preparation",
			"Preparation stopped before a journal was published.",
			warning = true,
		)
		return
	}
	plan, err := control(&op, "plan", a.limits.record, &a.control_bytes)
	if err !=
	   nil {audit_io(a, child(path, "plan"), err, "control record or aggregate byte"); return}
	want := pointer(id, plan)
	check_live := active
	for ptr in pointers {
		if ptr != "" && ptr[:32] == id && ptr != want {
			check_live = false
			state_problem(
				&a.result,
				path,
				"corrupt_journal",
				"Intent checksum differs from the plan.",
			)
		}
	}
	for receipt in ([]string{"committed", "rolled-back", "rollback"}) {
		if receipt not_in files do continue
		record, read_err := control(&op, receipt, a.limits.record, &a.control_bytes)
		if read_err !=
		   nil {audit_io(a, child(path, receipt), read_err, "control record or aggregate byte"); continue}
		if record !=
		   want {state_problem(&a.result, child(path, receipt), "corrupt_receipt", "Receipt does not identify this plan.")}
	}
	if !active && "rolled-back" not_in files && "committed" not_in files {
		state_problem(
			&a.result,
			path,
			"unconfirmed_operation",
			"No active intent or completion receipt for this plan.",
			warning = true,
		)
	}
	if !active && "rollback" in files && "rolled-back" not_in files {
		state_problem(
			&a.result,
			path,
			"missing_intent",
			"Rollback has neither an active intent nor a completion receipt.",
		)
	}
	if "rolled-back" in files && "rollback" not_in files {
		state_problem(
			&a.result,
			path,
			"corrupt_receipt",
			"Rollback receipt is missing its direction record.",
		)
	}
	count := strings.count(plan, "\n") - 1
	cost := i64(count) * 8 + 1
	if count > 0 && (!fits_plan(count, a.limits) || cost > a.nodes) {
		state_problem(
			&a.result,
			path,
			"recovery_incomplete",
			"Journal entry, node or depth limit exceeded.",
			true,
		)
		return
	}
	steps, version, ok := parse_manifest(plan, a.limits)
	if !ok {state_problem(&a.result, path, "corrupt_journal", "Invalid transaction manifest."); return}
	a.nodes -= cost
	if check_live {
		rollback := "rollback" in files
		for step, slot in steps {
			check: os.Error
			if step.kind == .Move_Directory {
				check = apply_tree_move(
					a.root,
					&op,
					step,
					rollback,
					true,
					true,
					a.limits,
					&a.image_bytes,
					&a.entries,
					version,
				)
			} else {
				check = apply_step(
					a.root,
					&op,
					slot,
					step,
					rollback,
					a.limits.source,
					verify_only = true,
					budget = &a.image_bytes,
					live_budget = &a.image_bytes,
					version = version,
				)
			}
			if check == .Invalid_File || check == .Not_Exist {
				state_problem(
					&a.result,
					child(a.root, step.path),
					"recovery_conflict",
					"The live path or staged image conflicts with the active operation.",
				)
			} else if check != nil {
				audit_io(a, child(a.root, step.path), check, "active operation read")
			}
		}
	}
	if len(steps) == 1 && steps[0].kind == .Move_Directory {
		audit_tree_images(a, &op, entries[:], steps[0], version)
		return
	}
	for s, slot in steps {
		for image in ([3]struct {
				suffix, stamp: string,
			}{{"original", s.backup}, {"restore", s.restored}, {"next", s.after}}) {
			name := image_name(slot, image.suffix)
			required :=
				image.suffix == "original" && s.kind != .Create ||
				image.suffix == "restore" &&
					"committed" in files &&
					"rollback" not_in files &&
					(s.kind == .Delete || s.kind == .Replace)
			if !required && name not_in files do continue
			stamp, image_err := entry_state(&op, name, a.limits.source, &a.image_bytes, version)
			if image_err !=
			   nil {audit_io(a, child(path, name), image_err, "snapshot or aggregate byte"); continue}
			if stamp != image.stamp || required && stamp == "-" {
				state_problem(
					&a.result,
					child(path, name),
					"corrupt_snapshot",
					snapshot_difference(image.stamp, stamp),
				)
			}
		}
	}
}

inspect_recovery :: proc(root: string, l: Journal_Limits) -> State_Audit {
	context.allocator = context.temp_allocator
	a := Recovery_Audit {
		root          = root,
		limits        = l,
		entries       = l.entries,
		control_bytes = l.total_bytes,
		image_bytes   = l.total_bytes,
		nodes         = l.total_nodes,
	}
	path := child(root, ".kadai")
	state, e := open_dir(path)
	if e == os.General_Error.Not_Exist do return a.result
	if e != nil {audit_io(&a, path, e, "directory"); return a.result}
	defer close_dir(&state)
	lock, lock_err := regular(&state, "writer.lock", mutation = true)
	if lock_err ==
	   nil {os.close(lock)} else if lock_err != .Not_Exist {audit_io(&a, child(path, "writer.lock"), lock_err, "stable lock")}
	pointers: [2]string
	for name, i in ([2]string{"intent", "pending"}) {
		txt, err := control(&state, name, l.record, &a.control_bytes)
		if err == os.General_Error.Not_Exist do continue
		file := child(path, name)
		if err != nil {audit_io(&a, file, err, "control record or aggregate byte"); continue}
		if len(txt) != 97 || txt[32] != ' ' || !valid_token(txt[:32]) || !hex_digest(txt[33:]) {
			state_problem(&a.result, file, "corrupt_intent", "Invalid pending-operation pointer.")
			continue
		}
		pointers[i] = txt
	}
	if pointers[0] != "" && pointers[1] != "" && pointers[0] != pointers[1] {
		state_problem(&a.result, path, "corrupt_intent", "The two intent records disagree.")
	}
	pending := make(map[string]bool)
	for ptr in pointers {
		if ptr == "" || ptr[:32] in pending do continue
		pending[ptr[:32]] = true
		state_problem(
			&a.result,
			path,
			"pending_operation",
			fmt.tprintf("Verify and recover operation %s.", ptr[:32]),
		)
	}
	vault_path := child(path, "recovery")
	vault, err := open_dir(vault_path, private_leaf = true)
	if err == os.General_Error.Not_Exist && len(pending) == 0 do return a.result
	if err != nil {audit_io(&a, vault_path, err, "directory"); return a.result}
	defer close_dir(&vault)
	entries, dir_err := state_entries(&vault, &a.entries)
	if dir_err != nil {audit_io(&a, vault_path, dir_err, "filesystem_entries"); return a.result}
	for fi in entries {
		if !valid_token(fi.name) || fi.type != .Directory {
			state_problem(
				&a.result,
				child(vault_path, fi.name),
				"invalid_recovery_directory",
				"Expected a transaction directory.",
			)
			continue
		}
		delete_key(&pending, fi.name)
		audit_operation(&a, &vault, fi.name, pointers[:])
	}
	for id in pending do state_problem(&a.result, child(vault_path, id), "missing_journal", "The intent points to a missing transaction directory.")
	return a.result
}

@(private)
audit_tree_images :: proc(
	a: ^Recovery_Audit,
	op: ^Directory,
	entries: []os.File_Info,
	step: Step,
	version: Journal_Version,
) {
	stamps := make([dynamic]Image_Stamp, context.temp_allocator)
	for fi in entries {
		if !strings.has_prefix(fi.name, "original-") do continue
		if !hex_digest(fi.name[len("original-"):]) {
			state_problem(
				&a.result,
				child(op.path, fi.name),
				"corrupt_snapshot",
				"Invalid directory snapshot name.",
			)
			continue
		}
		stamp, e := entry_state(op, fi.name, a.limits.source, &a.image_bytes, version)
		if e != nil {audit_io(a, child(op.path, fi.name), e, "snapshot or aggregate byte"); return}
		if _, alloc_err := append(&stamps, Image_Stamp{fi.name, stamp});
		   alloc_err != nil {audit_io(a, op.path, alloc_err, "snapshot"); return}
	}
	if len(step.backup) == 129 {
		if image_set_digest(stamps[:]) != step.backup[65:] {
			state_problem(
				&a.result,
				op.path,
				"corrupt_snapshot",
				"The directory snapshot set differs from the recorded names, identities, hashes or metadata.",
			)
		}
		return
	}

	// Older journals hashed original relative paths, which are absent from the
	// image names. Reconstruct that checksum if either tree still supplies them.
	archived := make(map[string]string, len(stamps), context.temp_allocator)
	for image in stamps do archived[image.name] = image.stamp
	for rel in ([2]string{step.path, step.destination}) {
		l := a.limits
		l.entries = a.entries
		tree, e := inspect_tree(child(a.root, rel), l, budget = &a.image_bytes, version = version)
		a.entries -= len(tree.entries)
		if e == os.General_Error.Not_Exist do continue
		if e != nil {audit_io(a, rel, e, "legacy tree verification"); return}
		b := strings.builder_make(context.temp_allocator)
		n := 0
		for item in tree.entries {
			value := "-"
			if !item.directory {
				value = archived[tree_image_name(item.path)]
				n += 1
			}
			fmt.sbprintf(&b, "%d:%s %s\n", len(item.path), item.path, value)
		}
		if n == len(stamps) && digest(transmute([]byte)strings.to_string(b)) == step.backup do return
		if tree.version == step.before {
			state_problem(
				&a.result,
				op.path,
				"corrupt_snapshot",
				"Directory snapshot checksum mismatch.",
			)
			return
		}
	}
	state_problem(
		&a.result,
		op.path,
		"recovery_incomplete",
		"The original tree paths needed to verify this legacy snapshot are unavailable.",
		true,
	)
}
