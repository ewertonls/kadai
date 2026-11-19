package app

import "base:runtime"
import "core:slice"
import "core:strings"
import "kadai:identity"
import "kadai:project"
import "kadai:storage"
import "kadai:yaml"

Validation :: struct {
	findings: [dynamic]Finding,
	errors, warnings: int,
	scan_complete, history_complete, recovery_complete: bool,
}

@(private)
source_finding :: proc(d: yaml.Diagnostic, id := "") -> Finding {
	return {code = d.code, path = d.path, id = id, field = d.field, location = d.location, message = d.message, observed = d.observed, limit = d.limit}
}

@(private)
state_findings :: proc(report: ^Validation, root, area: string, audit: storage.State_Audit) -> (err: runtime.Allocator_Error) {
	for p in audit.problems {
		path := strings.trim_prefix(p.path, storage.child(root, ""))
		_ = append(&report.findings, Finding{severity = .Warning if p.warning else .Error, path = path, code = p.code, message = p.message}) or_return
	}
	if audit.dropped_problem {
		_ = append(&report.findings, Finding{path = area, code = "state_incomplete", message = "Internal-state inspection did not complete."}) or_return
	}
	return
}

@(private)
collect_validation :: proc(r: ^Validation, cwd: string, options: Project_Options, l: project.Scan_Limits) -> (err: runtime.Allocator_Error) {
	// Keep the report in scratch storage. The scanner frees each task source with the caller's allocator.
	r.findings = make([dynamic]Finding, context.temp_allocator) or_return
	if !project.valid_scan_limits(l) {
		_ = append(&r.findings, Finding{code = "invalid_limit", message = "Invalid scan limits."}) or_return
		return
	}
	cfg, issue := project.resolve(cwd, options, l.yaml)
	if issue != "" {
		for d in cfg.diagnostics { _ = append(&r.findings, source_finding(d)) or_return }
		if cfg.diagnostic_alloc_failed {
			_ = append(&r.findings, Finding{code = "configuration_incomplete", path = ".kadai.yaml", message = issue}) or_return
		} else if len(cfg.diagnostics) == 0 {
			_ = append(&r.findings, Finding{code = "invalid_configuration", path = ".kadai.yaml", message = issue}) or_return
		}
		return
	}
	view := Collection{config = cfg, limits = l, index = project.build_index(project.scan(cfg, l))}
	r.scan_complete = view.index.complete
	for &item in view.index.candidates {
		for d in item.diagnostics { _ = append(&r.findings, source_finding(d, item.fields.id)) or_return }
	}
	if view.index.complete {
		findings, problem := graph_findings(&view)
		if problem != "" {
			r.scan_complete = false
			_ = append(&r.findings, Finding{code = "graph_incomplete", message = problem}) or_return
		} else { _ = append(&r.findings, ..findings[:]) or_return }
	} else {
		_ = append(&r.findings, Finding{code = "scan_incomplete", message = view.index.problem}) or_return
	}
	_, history := identity.inspect(cfg.tasks, l.yaml.bytes, l.entries, l.total_bytes)
	r.history_complete = !history.incomplete
	state_findings(r, cfg.tasks, ".kadai/used-ids", history) or_return
	recovery := storage.inspect_recovery(cfg.tasks, journal_limits(l))
	r.recovery_complete = !recovery.incomplete
	state_findings(r, cfg.tasks, ".kadai/recovery", recovery) or_return
	return
}

validate_project :: proc(cwd: string, options := Project_Options{}, limits := project.DEFAULT_SCAN_LIMITS) -> (r: Validation, issue: string) {
	if collect_validation(&r, cwd, options, limits) != nil do return {}, "validation incomplete: allocation failed"
	slice.sort_by(r.findings[:], proc(a, b: Finding) -> bool {
		if a.path != b.path do return a.path < b.path
		if a.location.span.start != b.location.span.start do return a.location.span.start < b.location.span.start
		if a.code != b.code do return a.code < b.code
		if a.field != b.field do return a.field < b.field
		if a.target_id != b.target_id do return a.target_id < b.target_id
		return a.message < b.message
	})
	for f in r.findings {
		if f.severity == .Warning { r.warnings += 1 } else { r.errors += 1 }
	}
	return
}
