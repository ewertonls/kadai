// Coordinates queries and mutations for callers such as the CLI.
package app

import "kadai:project"
import "kadai:identity"

Project_Options :: project.Options
initialize :: project.initialize

Collection :: struct {
	config: project.Config,
	index: project.Index,
	limits: project.Scan_Limits,
	history: identity.History, // Loaded only under the writer lock.
}

// Invocation-local view, including diagnostics from an incomplete inventory.
read_collection :: proc(cwd: string, options := Project_Options{}, limits := project.DEFAULT_SCAN_LIMITS) -> (view: Collection, issue: string) {
	if !project.valid_scan_limits(limits) do return {}, "invalid scan limits"
	view.limits = limits
	view.config, issue = project.resolve(cwd, options, limits.yaml)
	if issue != "" do return
	view.index = project.build_index(project.scan(view.config, limits))
	return view, view.index.problem
}
