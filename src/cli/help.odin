#+private
package cli

import "core:flags"
import "core:fmt"
import "core:strings"

Command :: struct {
	name, operands: string,
	flag_type: typeid,
}

@(rodata)
COMMANDS := [?]Command{
	{"init", "", Project_Flags},
	{"add", "TITLE", Add_Flags},
	{"list", "", Project_Flags},
	{"show", "ID", Project_Flags},
	{"tree", "", Project_Flags},
	{"ready", "[ID]", Project_Flags},
	{"validate", "", Project_Flags},
	{"set", "ID FIELD [VALUE ...]", Status_Flags},
	{"unset", "ID FIELD", Project_Flags},
	{"status", "ID STATUS", Status_Flags},
	{"parent", "(add CHILD PARENT | remove CHILD)", Project_Flags},
	{"dep", "(show ID | (add|remove) TASK PREREQUISITE)", Project_Flags},
	{"edit", "ID", Project_Flags},
	{"move", "SOURCE DEST", Move_Flags},
	{"remove", "ID", Remove_Flags},
	{"recover", "(resume|rollback) [OPERATION]", Project_Flags},
}

find_command :: proc(name: string) -> (Command, bool) {
	for command in COMMANDS {
		if command.name == name do return command, true
	}
	return {}, false
}

command_synopsis :: proc(command: Command) -> string {
	if command.operands == "" do return command.name
	return fmt.tprintf("%s %s", command.name, command.operands)
}

write_flag_help :: proc(text: ^strings.Builder, flag_type: typeid) {
	flags.write_usage(strings.to_writer(text), flag_type, style = .Unix)
	// Help is reserved by core:flags.
	strings.write_string(text, "\t-h, --help  | Show this help.\n")
}

help_text :: proc() -> string {
	text := strings.builder_make(context.temp_allocator)
	strings.write_string(&text, "Kadai tracks tasks in project-local Markdown files.\n\nUsage: kadai [option]\n       kadai COMMAND [args] [options]\n\nCommands:\n")
	for command in COMMANDS do fmt.sbprintf(&text, "  %s\n", command_synopsis(command))
	strings.write_string(&text, "\nRun 'kadai COMMAND --help' for command options.\n\n")
	write_flag_help(&text, Options)
	return strings.to_string(text)
}

command_help :: proc(command: Command) -> string {
	text := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&text, "Usage: kadai %s [options]\n\n", command_synopsis(command))
	write_flag_help(&text, command.flag_type)
	return strings.to_string(text)
}
