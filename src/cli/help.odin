#+private
package cli

import "core:flags"
import "core:fmt"
import "core:strings"
import "kadai:app"

Help_Flags :: struct {
	command: string `args:"pos=0,hidden"`,
}

Command :: struct {
	name: string,
	flag_type: typeid,
	summary, details: string,
	operands, examples: []string,
}

@(rodata)
COMMANDS := [?]Command{
	{
		"init", Project_Flags, "Create the project configuration and task directory.",
		"Run in the project directory or select an existing directory with --project.",
		{""}, {"kadai init --id-prefix KAD"},
	},
	{
		"add", Add_Flags, "Create a Markdown task and print its ID.",
		"New tasks start in todo by default. Supply the body with --body-file or --stdin.",
		{"TITLE"}, {"kadai add \"Write release notes\"", "kadai add \"Review changes\" --body-file notes.md"},
	},
	{
		"list", List_Flags, "List tasks with their ID, status, title and path.",
		"Rows match all supplied filters. By default they follow collection-relative path order.",
		{""}, {"kadai list --status todo --directory docs", "kadai list --where 'priority=high OR status=todo AND tag!=wip'", "kadai list --sort priority --order desc"},
	},
	{
		"show", Project_Flags, "Print a task's file path and Markdown contents.",
		"Look up the task by its frontmatter ID.",
		{"ID"}, {"kadai show 0001"},
	},
	{
		"tree", Project_Flags, "Display tasks in their parent-child hierarchy.",
		"Indentation follows parent links. The tree marks unresolved parents and cycles.",
		{""}, {"kadai tree"},
	},
	{
		"ready", Project_Flags, "List tasks ready to work on, or check one task by ID.",
		"With an ID, the result is ready, blocked or unresolved.",
		{"[ID]"}, {"kadai ready", "kadai ready 0001"},
	},
	{
		"validate", Project_Flags, "Check configuration, task files, relationships and history.",
		"Exit status is 1 for errors or incomplete checks, and 0 otherwise.",
		{""}, {"kadai validate"},
	},
	{
		"set", Status_Flags, "Set a task's title, status, priority, due date or tags.",
		"Use due for a due date. Pass a single value for a scalar or one value per tag.",
		{"ID FIELD [VALUE ...]"}, {"kadai set 0001 priority high", "kadai set 0001 tags docs release"},
	},
	{
		"unset", Project_Flags, "Remove an optional field from a task.",
		"The supported fields are priority, due and tags.",
		{"ID FIELD"}, {"kadai unset 0001 due"},
	},
	{
		"status", Status_Flags, "Change a task's workflow status.",
		"Moving a task to done requires satisfied prerequisites unless you pass --force.",
		{"ID STATUS"}, {"kadai status 0001 in_progress"},
	},
	{
		"parent", Project_Flags, "Set or clear a task's parent.",
		"Pass the child ID first. Removing its parent makes the child a root task.",
		{"add CHILD PARENT", "remove CHILD"}, {"kadai parent add 0002 0001", "kadai parent remove 0002"},
	},
	{
		"dep", Project_Flags, "Show, add or remove task dependencies.",
		"Use show for direct edges or graph to follow prerequisite chains. Select dependents to walk downstream.\nWith add or remove, TASK depends on PREREQUISITE.",
		{"show ID", "graph ID [prerequisites|dependents]", "add TASK PREREQUISITE", "remove TASK PREREQUISITE"},
		{"kadai dep add 0002 0001", "kadai dep show 0002", "kadai dep graph 0001 dependents"},
	},
	{
		"edit", Project_Flags, "Open a task's Markdown file in $EDITOR.",
		"Kadai waits for the editor to exit. For VS Code, set EDITOR to 'code --wait'.",
		{"ID"}, {"kadai edit 0001"},
	},
	{
		"move", Move_Flags, "Move a task file or directory within the collection.",
		"Pass a task ID and a destination relative to the task directory.\nWith --directory, both paths are relative to the task directory.",
		{"ID DEST", "--directory SOURCE DEST"}, {"kadai move 0001 docs/release.md", "kadai move --directory drafts archive"},
	},
	{
		"remove", Remove_Flags, "Delete a task after checking references from other tasks.",
		"Preview the affected files with --dry-run. To delete, pass --yes or the matching --plan token.\nAdd --detach to clear incoming references.",
		{"ID --dry-run", "ID --yes", "ID --plan TOKEN"}, {"kadai remove 0001 --detach --dry-run", "kadai remove 0001 --yes"},
	},
	{
		"recover", Recover_Flags, "Resume an interrupted write or roll back an operation.",
		"Omit the operation ID to select the pending write.\nTo undo a completed removal, pass the operation ID printed by remove.",
		{"resume [OPERATION] --yes", "rollback [OPERATION] --yes"}, {"kadai recover resume --yes"},
	},
	{
		"help", Help_Flags, "Show the command list or help for one command.",
		"", {"[COMMAND]"}, {"kadai help add"},
	},
}

find_command :: proc(name: string) -> (Command, bool) {
	for command in COMMANDS {
		if command.name == name do return command, true
	}
	return {}, false
}

write_flag_help :: proc(text: ^strings.Builder, flag_type: typeid) {
	if flag_type == Help_Flags {
		strings.write_string(text, "Flags:\n")
	} else {
		flags.write_usage(strings.to_writer(text), flag_type, style = .Unix)
	}
	// Help is reserved by core:flags.
	strings.write_string(text, "\t-h, --help  | Show this help.\n")
}

help_text :: proc() -> string {
	text := strings.builder_make(context.temp_allocator)
	strings.write_string(&text, "Kadai tracks tasks in project-local Markdown files.\n\nUsage:\n  kadai COMMAND [arguments] [options]\n  kadai [option]\n\nCommands:\n")
	width := 0
	for command in COMMANDS do width = max(width, len(command.name))
	for command in COMMANDS do fmt.sbprintf(&text, "  %-*s  %s\n", width, command.name, command.summary)
	strings.write_string(&text, "\n")
	write_flag_help(&text, Options)
	strings.write_string(&text, "\nExit codes:\n  0 success, 1 command or validation failure, 2 invalid invocation\n  3 missing task ID, 4 ambiguous task ID, 5 incomplete write\n  6 response failed after a successful mutation, 7 other output failure\n")
	strings.write_string(&text, "\nFor command help, run 'kadai help COMMAND' or 'kadai COMMAND --help'.\n")
	return strings.to_string(text)
}

command_help :: proc(command: Command) -> string {
	text := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&text, "%s\n\nUsage:\n", command.summary)
	for operands in command.operands {
		fmt.sbprintf(&text, "  kadai %s", command.name)
		if operands != "" do fmt.sbprintf(&text, " %s", operands)
		strings.write_string(&text, " [options]")
		strings.write_byte(&text, '\n')
	}
	if command.details != "" do fmt.sbprintf(&text, "\n%s\n", command.details)
	strings.write_string(&text, "\nExamples:\n")
	for example in command.examples do fmt.sbprintf(&text, "  %s\n", example)
	strings.write_byte(&text, '\n')
	write_flag_help(&text, command.flag_type)
	if command.flag_type != Help_Flags {
		strings.write_string(&text, "\nResource budgets (--limit NAME=INTEGER):\n  Positive decimal integers; byte budgets use bytes. Each name may appear once.\n  Overrides apply only to this invocation, including init and recovery.\n\n")
		defaults := limit_values(app.DEFAULT_SCAN_LIMITS)
		ceilings := limit_values(app.MAX_SCAN_LIMITS)
		fmt.sbprintf(&text, "  %-24s %12s %12s\n", "NAME", "DEFAULT", "MAXIMUM")
		for key in Limit do fmt.sbprintf(&text, "  %-24s %12d %12d\n", LIMIT_NAMES[key], defaults[key], ceilings[key])
	}
	return strings.to_string(text)
}
