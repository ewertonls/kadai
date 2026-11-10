package storage

import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"

// Internal state has independent counters but inherits the invocation limits.
Journal_Limits :: struct {
	source, record, nodes, depth, entries: int,
	total_bytes, total_nodes: i64,
}
DEFAULT_JOURNAL_LIMITS :: Journal_Limits{16<<20, 256<<10, 10_000, 32, 250_000, 256<<20, 1_000_000}

Transaction :: struct {
	id: string,
	steps: []Step,
}
Recovery_Mode :: enum {Resume, Rollback}

@(private)
encode_path :: proc(path: string) -> string {
	if path == "" do return "-"
	return string(hex.encode(transmute([]byte)path, context.temp_allocator))
}

@(private)
decode_path :: proc(value: string, directory := false) -> (path: string, valid: bool) {
	if value == "-" do return "", true
	bytes := hex.decode(transmute([]byte)value, context.temp_allocator) or_return
	return string(bytes), relative_file(string(bytes), directory)
}

// Flat, versioned, length-bounded ASCII records. Hex paths also support
// whitespace/newlines. The pointer includes a checksum of the entire manifest.
@(private)
manifest :: proc(steps: []Step, limit: int) -> (string, bool) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "kadai-transaction-v1\n")
	for s in steps {
		fmt.sbprintf(&b, "%d %s %s %s %s %s %s\n", int(s.kind), encode_path(s.path),
			encode_path(s.destination), s.before, s.after, s.backup, s.restored)
		if strings.builder_len(b) > limit do return "", false
	}
	return strings.to_string(b), true
}

@(private)
fits_plan :: proc(count: int, l: Journal_Limits) -> bool {
	nodes := i64(count)*8 + 1
	return count > 0 && count <= l.entries && l.depth >= 3 && nodes <= i64(l.nodes) && nodes <= l.total_nodes
}

@(private)
parse_manifest :: proc(src: string, l: Journal_Limits) -> ([]Step, bool) {
	input := src
	line, _ := strings.split_iterator(&input, "\n")
	if line != "kadai-transaction-v1" || !strings.has_suffix(src, "\n") do return nil, false
	steps := make([dynamic]Step, context.temp_allocator)
	for row in strings.split_iterator(&input, "\n") {
		if !fits_plan(len(steps)+1, l) do return nil, false
		v := strings.split_n(row, " ", 8, context.temp_allocator)
		if len(v) != 7 || len(v[0]) != 1 || v[0][0] < '0' || v[0][0] > '4' do return nil, false
		s := Step{kind = Change_Kind(v[0][0]-'0'), before = v[3], after = v[4], backup = v[5], restored = v[6]}
		directory := s.kind == .Move_Directory
		path, ok := decode_path(v[1], directory)
		dest, valid := decode_path(v[2], directory)
		if !ok || !valid || path == "" || (dest != "") != (s.kind == .Move || directory) do return nil, false
		if directory && (len(steps) != 0 || input != "" || within(path, dest) || within(dest, path)) do return nil, false
		s.path, s.destination = path, dest
		if _, err := append(&steps, s); err != nil do return nil, false
	}
	return steps[:], len(steps) != 0
}

@(private)
control :: proc(dir: ^Directory, name: string, max_bytes: int, budget: ^i64) -> (text: string, err: os.Error) {
	f := regular(dir, name, mutation = true) or_return
	defer os.close(f)
	data := read_bounded(f, int(min(i64(max_bytes), budget^))) or_return
	budget^ -= i64(len(data))
	return string(data), nil
}

@(private)
valid_token :: proc(id: string) -> bool {
	if len(id) != 32 do return false
	for c in id {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') do return false
	}
	return true
}

@(private)
op_directory :: proc(root, id: string, create: bool) -> (dir: Directory, err: os.Error) {
	if !valid_token(id) do return {}, .Invalid_Path
	vault := open_dir(child(root, ".kadai/recovery"), create, true) or_return
	defer close_dir(&vault)
	return open_dir(child(vault.path, id), create, true)
}

@(private)
pointer :: proc(id, plan: string) -> string {
	return fmt.tprintf("%s %s", id, digest(transmute([]byte)plan))
}

// Publish redundant, independent intent records before the first visible
// change. Either record is sufficient to block a writer and find the journal.
@(private)
arm :: proc(state: ^Directory, ptr: string) -> (err: os.Error) {
	for name in ([]string{"intent", "pending"}) {
		create_file(state, name, transmute([]byte)ptr) or_return
	}
	return
}

@(private)
finish :: proc(state, op: ^Directory, mode: Recovery_Mode, ptr: string) -> (err: os.Error) {
	receipt := "rolled-back" if mode == .Rollback else "committed"
	e := create_file(op, receipt, transmute([]byte)ptr)
	if e == .Exist {
		budget := i64(len(ptr))
		existing := control(op, receipt, len(ptr), &budget) or_return
		if existing != ptr do return .Invalid_File
	} else if e != nil { return e }
	for name in ([]string{"pending", "intent"}) {
		e = remove_entry(state, name)
		if e != nil && e != .Not_Exist do return e
	}
	return sync_dir(state)
}

@(private)
run_steps :: proc(root: string, dir: ^Directory, tx: Transaction, mode: Recovery_Mode, limits: Journal_Limits, dry_run: bool, budget: ^i64, replay := true) -> string {
	for _, n in tx.steps {
		i := len(tx.steps)-1-n if mode == .Rollback else n
		step := tx.steps[i]
		err: os.Error
		if step.kind == .Move_Directory {
			err = apply_tree_move(root, dir, step, mode == .Rollback, dry_run, replay, limits, budget)
		} else {
			err = apply_step(root, dir, i, step, mode == .Rollback, limits.source, dry_run, budget, replay)
		}
		if err != nil {
			reason := os.error_string(err)
			if err == .Invalid_File do reason = "file identity, contents, metadata or expected presence changed"
			return fmt.tprintf("operation %s, step %d (%s): %s", tx.id, i+1, tx.steps[i].path, reason)
		}
	}
	return ""
}

@(private)
preflight :: proc(root: string, changes: []Change, l: Journal_Limits) -> string {
	if !fits_plan(len(changes), l) || l.record < 97 do return "transaction exceeds journal limits"
	seen := make(map[string]bool, context.temp_allocator)
	for c in changes {
		if c.kind == .Move_Directory {
			if len(changes) != 1 || !relative_file(c.path, true) || !relative_file(c.destination, true) ||
			   within(c.path, c.destination) || within(c.destination, c.path) { return "invalid directory move" }
			_, e := os.lstat(child(root, c.destination), context.temp_allocator)
			if e != os.General_Error.Not_Exist do return "directory destination occupied or inaccessible"
			continue
		}
		if !relative_file(c.path) || len(c.data) > l.source || (c.destination != "") != (c.kind == .Move) do return "invalid change"
		for path in ([2]string{c.path, c.destination}) {
			if path == "" do continue
			if !relative_file(path) || path in seen do return "conflicting or unsafe transaction paths"
			seen[path] = true
			target := child(root, path)
			dir, e := open_dir(slash(os.dir(target)))
			missing := c.kind == .Create || path == c.destination
			if e == os.General_Error.Not_Exist && missing do continue
			if e != nil do return os.error_string(e)
			{
				defer close_dir(&dir)
				state, err := entry_state(&dir, os.base(path), l.source)
				if err != nil do return os.error_string(err)
				if missing {
					if state != "-" do return fmt.tprintf("occupied destination: %s", path)
				} else if c.expected == "" || !strings.has_prefix(state, fmt.tprintf("%s:", c.expected)) {
					return fmt.tprintf("source conflict: %s", path)
				}
			}
		}
	}
	return ""
}

commit :: proc(w: ^Writer, changes: []Change, l := DEFAULT_JOURNAL_LIMITS, before_intent: proc(rawptr) -> string = nil, data: rawptr = nil) -> (id, issue: string) {
	if w.collection == nil || !domain_held(w.domain) do return "", "writer coordination required"
	if issue = check_pending(w, w.root, l.entries); issue != "" do return
	if issue = preflight(w.root, changes, l); issue != "" do return
	state, e := open_dir(child(w.root, ".kadai"))
	if e != nil do return "", os.error_string(e)
	defer close_dir(&state)
	id = random_name("")
	dir, err := op_directory(w.root, id, true)
	if err != nil do return id, os.error_string(err)
	defer close_dir(&dir)
	tx := Transaction{id, make([]Step, len(changes), context.temp_allocator)}
	for c, i in changes {
		if c.kind == .Move_Directory {
			tree: Tree
			tree, err = inspect_tree(child(w.root, c.path), l, &dir, capture = true)
			if err == nil && tree.version != c.expected do err = .Invalid_File
			tx.steps[i] = {c.kind, c.path, c.destination, tree.version, tree.version, tree.backup, "-"}
			if err == nil do err = sync_dir(&dir)
		} else {
			tx.steps[i], err = prepare_step(w.root, &dir, i, c, l.source)
		}
		if err != nil do return id, fmt.tprintf("preparing %s: %s", c.path, os.error_string(err))
	}
	plan, ok := manifest(tx.steps, l.record)
	if !ok || i64(len(plan)) + 4*97 > l.total_bytes do return id, "journal exceeds byte limit"
	if err = create_file(&dir, "plan", transmute([]byte)plan); err != nil do return id, os.error_string(err)
	ptr := pointer(id, plan)
	image_budget := l.total_bytes
	if issue = run_steps(w.root, &dir, tx, .Resume, l, true, &image_budget, false); issue != "" do return
	if image_budget < l.total_bytes-image_budget do return id, "verification exceeds recovery byte limit"
	if before_intent != nil {
		if issue = before_intent(data); issue != "" do return
	}
	if err = arm(&state, ptr); err != nil do return id, fmt.tprintf("recording operation intent: %s", os.error_string(err))
	if issue = run_steps(w.root, &dir, tx, .Resume, l, false, &image_budget, false); issue != "" do return
	return id, os.error_string(finish(&state, &dir, .Resume, ptr))
}

recover :: proc(w: ^Writer, mode: Recovery_Mode, operation := "", l := DEFAULT_JOURNAL_LIMITS, check: Recovery_Check = nil, data: rawptr = nil) -> (id, issue: string) {
	if w.collection == nil || !domain_held(w.domain) do return "", "writer coordination required"
	if issue = check_pending(w, w.root, l.entries, allow_own = true); issue != "" do return
	state, e := open_dir(child(w.root, ".kadai"))
	if e != nil do return "", os.error_string(e)
	defer close_dir(&state)
	budget := l.total_bytes
	ptr := ""
	for name in ([]string{"intent", "pending"}) {
		text, err := control(&state, name, l.record, &budget)
		if err == os.General_Error.Not_Exist do continue
		if err != nil || len(text) != 97 || text[32] != ' ' || ptr != "" && ptr != text do return "", "inconsistent pending record"
		ptr = text
	}
	id = operation
	if ptr != "" {
		if id != "" && id != ptr[:32] do return "", "another operation is pending"
		id = ptr[:32]
	} else if mode != .Rollback || id == "" { return "", "no pending operation" }
	dir, err := op_directory(w.root, id, false)
	if err != nil do return id, os.error_string(err)
	defer close_dir(&dir)
	plan, plan_err := control(&dir, "plan", l.record, &budget)
	if plan_err != nil do return id, os.error_string(plan_err)
	expected := pointer(id, plan)
	if ptr != "" && ptr != expected do return id, "journal checksum mismatch"
	steps, ok := parse_manifest(plan, l)
	if !ok do return id, "invalid or oversized journal"
	image_budget := l.total_bytes
	tx := Transaction{id, steps}
	if issue = run_steps(w.root, &dir, tx, mode, l, true, &image_budget); issue != "" do return
	apply_bytes := l.total_bytes-image_budget
	if issue = check_recovery_effects(w.root, &dir, steps, mode, check, data, l, &image_budget); issue != "" do return
	if image_budget < apply_bytes do return id, "verification exceeds recovery byte limit"
	if ptr == "" {
		receipt, receipt_err := control(&dir, "committed", l.record, &budget)
		if receipt_err != nil || receipt != expected do return id, "missing commit receipt"
		if err = arm(&state, expected); err != nil do return id, os.error_string(err)
	}
	// Once rollback starts, a restart can only continue it.
	direction, direction_err := control(&dir, "rollback", l.record, &budget)
	if direction_err == nil {
		if direction != expected || mode != .Rollback do return id, "rollback already in progress"
	} else if direction_err != os.General_Error.Not_Exist { return id, os.error_string(direction_err) }
	if mode == .Rollback && direction_err != nil {
		if err = create_file(&dir, "rollback", transmute([]byte)expected); err != nil do return id, os.error_string(err)
	}
	if issue = run_steps(w.root, &dir, tx, mode, l, false, &image_budget); issue != "" do return
	return id, os.error_string(finish(&state, &dir, mode, expected))
}
