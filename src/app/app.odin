// Coordinates queries and mutations for callers such as the CLI.
package app

import "kadai:project"
import "kadai:identity"
import "kadai:graph"
import "kadai:yaml"

Task_Candidate :: project.Candidate
Readiness :: graph.Readiness
Source_Span :: yaml.Byte_Range
Custom_Node :: yaml.Node
Invocation_Report :: project.Invocation_Report
Project_Options :: project.Options
Scan_Limits :: project.Scan_Limits
DEFAULT_SCAN_LIMITS :: project.DEFAULT_SCAN_LIMITS
MAX_SCAN_LIMITS :: project.MAX_SCAN_LIMITS
initialize :: project.initialize

Collection :: struct {
	config: project.Config,
	report: ^Invocation_Report,
	index: project.Index,
	limits: project.Scan_Limits,
	glob_budget: project.Glob_Budget,
	history: identity.History, // Loaded only under the writer lock.
}

// Invocation-local view, including diagnostics from an incomplete inventory.
read_collection :: proc(cwd: string, options := Project_Options{}, limits := project.DEFAULT_SCAN_LIMITS) -> (view: Collection, issue: string) {
	if !project.valid_scan_limits(limits) do return {}, "invalid scan limits"
	view.limits, view.report = limits, options.report
	view.glob_budget.limit = limits.exclude_match_steps
	view.config, issue = project.resolve(cwd, options, limits.yaml)
	if issue != "" do return
	view.index = project.build_index(project.scan(view.config, limits, &view.glob_budget))
	return view, view.index.problem
}
