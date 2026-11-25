# Core CLI grammar

KAD-047 defines the command grammar and invocation overrides. Run `kadai`,
`kadai --help`, `kadai help COMMAND` or `kadai COMMAND --help` for built-in help.
`kadai --version` prints the executable version.

## Arguments

Use `kadai COMMAND [arguments] [options]`. Options may appear anywhere **after**
the command, before `--`. Value options accept `--name VALUE` and `--name=VALUE`.
Quote multiword arguments in the shell. Place `--` before one or more literal
operands, including `-draft` or `--help`.

Unknown commands/options, missing/extra operands, invalid field selections and
conflicting body/exclusion options fail with an argument error. For repeated
scalar options the last value wins. `--exclude` accumulates a replacement list;
`--limit` accepts different names but rejects a repeated name. Empty option
values are rejected; use `--clear-excludes` for an empty exclusion override.

## Commands

All commands below accept the common project and resource options.

| Command | Operands and command-specific options |
| --- | --- |
| `init` | No operands. Explicitly create minimal config and the effective task directory. Initialization is optional. |
| `add TITLE` | `--status STATUS`, `--path FILE`, and one of `--body-file FILE` or `--stdin`. Default status is `todo`; default body is empty; default filename is `<ID>.md`. Prints the allocated ID. |
| `import SOURCE.md --yes` | Copy one ordinary Markdown file into a new `todo` task and print its ID. Use `--title TITLE` to override the filename-derived title and `--path FILE` to choose an unused destination. |
| `list` | Lists tasks matching `--status STATUS`, `--directory DIR`, `--tag TAG`, `--parent ID` and `--where EXPR`. Use `--sort KEY` and `--order asc\|desc` to select the row order. `--long` adds priority and due date to text output. |
| `show ID` | Print the collection-relative path and original task source, or report diagnostic-only metadata. |
| `log add ID [MESSAGE]` | Append one timestamped Markdown entry. Supply a message argument, `--stdin`, or `--body-file PATH`. |
| `log list ID` | Print entries as Markdown in file order. An empty or absent log produces empty output. |
| `set ID FIELD [VALUE ...]` | Fields: `title`, `status`, `priority`, `due`, `tags`. Scalars require exactly one value. Tags take zero or more values; zero clears the sequence. `--force` is accepted only for `status`. |
| `unset ID FIELD` | Remove `priority`, `due` or `tags`. Required fields cannot be unset. |
| `status ID STATUS` | Alias for setting the status. `--force` permits completion with blocked/unresolved prerequisites. |
| `edit ID` | Open the source file using `$EDITOR` and wait for exit. `--editor COMMAND` selects an editor for this invocation. |
| `move ID DEST` | Move/rename one task to a collection-relative file path. |
| `move --directory SOURCE DEST` | Move a collection-relative directory, preserving task identities and discoverability. |
| `remove ID` | Preview with `--dry-run`. Delete with `--yes` or `--plan TOKEN`. Add `--detach` to clear inbound parent and dependency references. Prints an operation ID on deletion. |
| `parent add CHILD PARENT` | Set or replace the child's logical parent. |
| `parent remove CHILD` | Clear the child's parent. |
| `dep add TASK PREREQUISITE` | Add a direct prerequisite. A duplicate case-insensitive reference is an error. |
| `dep remove TASK PREREQUISITE` | Remove a direct prerequisite. |
| `dep show ID` | Show immediate prerequisites and dependents as `prerequisite -> dependent`. |
| `dep graph ID [prerequisites\|dependents]` | Show all reachable prerequisite edges (default), or follow dependents downstream. |
| `tree` | No operands. Show the logical parent hierarchy. |
| `ready [ID]` | Without an ID, list actionable ready tasks; with an ID, report `ready`, `blocked` or `unresolved`. |
| `validate` | No operands. Read-only validation of config, tasks, relationships and internal state. |
| `recover resume [OPERATION] --yes` | Resume the pending operation or the selected operation. |
| `recover rollback [OPERATION] --yes` | Roll back the pending operation or the selected operation. |

Task IDs are looked up case-insensitively. Relationship commands use IDs, not
paths. Directory placement does not assign parents. Status overrides never
bypass identity, graph-structure or file-safety checks.

A relative body-file path resolves against the invocation CWD, independent of `--project`.
Body bytes from files/stdin are preserved, including line endings and the final
newline. `--path` and move destinations are relative to the effective task root
and must remain discoverable. Parent directories may be created as needed.

### Importing Markdown

`kadai import` requires an explicit source file and `--yes`. Resolve a relative
source path from the invocation's working directory, even when `--project`
selects another project. The source must be a regular UTF-8 file ending in
`.md`. A symbolic link as the source file is rejected.

The new task starts in `todo` with the source filename minus its final `.md`
as its title. Its body contains the complete original file, including any
foreign frontmatter, UTF-8 BOM, line endings and final newline if present.
Kadai leaves the original file in place. It rejects existing Kadai tasks,
including invalid or unsupported-schema candidates.

The collection allocates a fresh ID for each import. The default destination
is `<ID>.md`, skipping occupied filenames. An explicit `--path` must be
unused, even when it names the selected source itself. The source and the
resulting task must both fit `task_source_bytes`.

```sh
kadai import notes.md --yes
kadai import ../drafts/release.md --project ./repo --yes --title "Review release" --path reviews/release.md
```

### Task activity logs

`kadai log add` creates the log on the first append. The entry must contain
nonblank UTF-8 Markdown. A relative `--body-file` path resolves from the current
working directory. For example, either command below appends one entry.

```sh
kadai log add T-007 "Parser now handles empty files."
printf '%s\n' 'Remaining checks' '' '- Duplicate IDs' '- Invalid dates' | kadai log add T-007 --stdin
```

You can also add or edit entries directly in the task file.

```markdown
---
kadai: task
id: T-007
title: Implement the parser
status: in_progress
---

Keep the parser compatible with existing task files.

<!-- kadai:log:start -->

## Log

### 2026-11-17T14:30:00-03:00

Parser now handles empty files.

<!-- kadai:log:end -->
```

Put each marker on a line by itself, exactly as shown, with no surrounding
spaces. Start the section with `## Log`. Only blank lines may follow the closing marker. Each entry starts
with a `###` heading containing an RFC 3339 timestamp and consists of the
Markdown up to the next entry or closing marker. Other headings, lists, and
fenced code blocks can appear in an entry. Put literal examples of markers or
timestamp headings inside a backtick or tilde fence. The blank lines separating
the heading, content, and next entry are formatting. Additional newlines and
Markdown hard breaks in an entry are preserved.

New timestamps use the numeric UTC offset in effect in the project time zone
at the time of the append. `--timezone` overrides the configured zone. The
default is system local time. Handwritten entries can use a numeric offset
or `Z` and may include fractional seconds. Entries stay in file order even
when their timestamps repeat or go backward.

`log add`, `log list`, and `validate` report malformed logs with a source
location. The file remains available through `show` and `edit` for repair.
Appending uses the same version checks and recovery journal as other task edits.

## Noninteractive use

Kadai never prompts for missing arguments or confirmation. Commands behave the
same in a terminal and in a pipeline. Only `add --stdin` and `log add --stdin` read task data from
standard input. A title-only `add` creates an empty body even with piped input.
Only `edit` launches an editor and waits for it, so scripts using `edit` should
select an editor that runs unattended.

`remove ID --yes` deletes an unreferenced task. Inbound references block
deletion unless the invocation also includes `--detach`. To review and apply
a specific set of edits from a script with `jq`, save the preview and use its
`result.plan` token.

```sh
kadai remove 0001 --detach --dry-run --json > preview.json
# After reviewing result.edits in preview.json
plan=$(jq -er '.result.plan' preview.json) && kadai remove 0001 --detach --plan "$plan"
```

The dry run is read-only, even with `--yes`. A supplied token must still
match when the writer rechecks the plan, including when `--yes` is present.
Omit `--detach` from both commands to keep references protected.

Both recovery modes require `--yes` because replaying or reversing a journal
can remove or replace files. To undo a completed removal, use
`kadai recover rollback OPERATION --yes` with the operation ID returned by
`remove`. Omit the ID to select the pending operation. An explicitly empty ID
is a usage error. Recovery verifies recorded state before modifying files. Missing
authorization for import, deletion or recovery exits with code 2 before opening the project.

When several macOS applications use the same collection, upgrade the Kadai
binary used by each one. The updated CLI can validate and recover both v1
and v2 journals. Earlier binaries can read only v1 journals.

### Choosing an editor

`kadai edit 0001 --editor 'nvim --clean'` overrides `$EDITOR` for one command.
Both forms accept an executable and literal arguments. Quote paths or arguments
containing spaces inside the command string. Kadai appends the task's absolute
path as one argument and starts the executable directly. With `--json`, editor
output goes to stderr and the successful acknowledgement goes to stdout after
the editor exits. Malformed `--editor` syntax exits with code 2. A malformed
`$EDITOR` setting exits with code 1.

On macOS and Linux, `--editor 'code --wait'` waits for VS Code to close the
file. On Windows, select a native executable such as `nvim.exe`. Kadai checks
for empty or tab-containing arguments that the Windows launcher cannot pass
literally and reports them before starting the editor.

## List filters

`kadai list --status todo --directory docs` lists todo tasks in `docs/` and
its subdirectories. Directory names are relative to the effective task root.
Matching uses the case of the indexed path. `.` selects the whole collection.
Relative paths are normalized lexically and must stay within the collection.

`--status` matches the stored status exactly, including custom names defined
in the project. `--tag` matches one whole tag. For example, `--tag cli` matches
`tags: [cli, release]` and skips a task tagged only `cli/parser`.
`--parent` selects direct children of a valid, uniquely identified task. Parent
IDs match case-insensitively. An unknown status or unresolved parent is an
error. A valid query with no matches succeeds with empty output.

Each filter takes one value. As with other scalar options, repeating a flag
uses its last value. Results come from the complete index of the effective
collection, so its exclusions and duplicate-ID quarantine apply to every query.
By default rows follow ascending byte order of the full collection-relative path, with
`/` as the separator.

### Filter expressions

`--where` takes one quoted expression. Write each predicate as `field=value`
or `field!=value`, with no spaces around the comparison. Join predicates with
uppercase `AND` or `OR`, separated by whitespace. `AND` binds first. The
grammar consists of `OR` alternatives of `AND` predicates. Other list flags
apply to the entire expression.

```sh
kadai list --directory docs --where 'priority=high OR status=todo AND tag!=wip'
kadai list --where 'id=T-001 OR due=2026-11-15' --json
```

The first command includes high-priority tasks in `docs/` and todo tasks there
that lack the `wip` tag. `priority` and `status` use the project vocabulary,
`tag` tests whole-tag membership, and `id` uses case-insensitive ID equality.
`due` compares the exact stored date or offset datetime spelling. An absent
optional field fails equality and satisfies inequality. Kadai validates every
predicate even for an empty collection. Text and JSON select the same rows.

### List sorting

`--sort` accepts `path` (the default), `id`, `title`, `status` or `priority`.
Use `--order asc` (the default) or `--order desc`. Both flags work independently.
Paths, IDs, titles and status names sort by the bytes of their stored spelling.
Priority sorts from low to critical in ascending order, or by the project's
configured priority sequence. Tasks without a priority come last in either
direction. Equal keys always use ascending collection-relative path order.
The same ordering applies to filtered results in text and JSON.

```sh
kadai list --status todo --sort priority --order desc
kadai list --sort title --json
```

## Terminal output

`list` prints one row per match, for example `T-002  [todo]  Review notes  (docs/review.md)`.
Use `list --long` to show the stored priority and due date below each row.
A dash marks a missing value. Filters and sorting apply to either layout.
`--long` and `--json` select different output formats and cannot be combined.

```text
T-002  [todo]  Review notes  (docs/review.md)
    priority high  due 2026-11-15
```

`tree` indents direct children beneath their parent and marks unresolved parents and
cycle members. For levels deeper than 16 it prints the depth beside the task.
`ready` shows the task's stored status and labels its derived readiness separately.
Task summaries, validation findings and command errors escape tabs, line breaks and terminal control characters.

`dep show` groups immediate prerequisites and dependents. Every arrow points from
prerequisite to dependent. An unresolved prerequisite keeps its written ID and
shows the reason. When several files claim that ID, their paths appear beneath the edge.

### Dependency graphs

`kadai dep graph ID` follows the subject's prerequisites recursively.
`kadai dep graph ID dependents` follows the reverse links to find every task
that depends directly or indirectly on the subject. In both directions,
`A -> B` means B declares A in `depends_on`. For example, a task C that
depends on B, which depends on A, produces the edges `B -> C` and `A -> B`
in `kadai dep graph C`.

The graph expands tasks breadth-first. Within each task it emits prerequisites
in frontmatter order or dependents in collection-relative path order. Each
task is expanded once, so cycles terminate and shared prerequisites keep all
their declared edges. A resolved endpoint uses its stored ID. An unresolved
prerequisite keeps its written ID and resolution reason, and traversal stops
at that endpoint. Use `dep show` on the declaring task to inspect candidate
paths. The graph is read-only. Readiness continues to use direct prerequisites.

### Validation output

`validate` prints the source path and available line and column alongside each
finding, followed by its severity, code and message. Related files and cycle
edges appear on indented lines. The report names incomplete checks and gives
error and warning counts when it finds issues.

## JSON output v1

Pass `--json` after any query or mutation command. Stdout carries one UTF-8 JSON
object followed by a newline. The integer `version` identifies the response
contract. The following `kadai list --json` response contains one task in `result`.

```json
{"version":1,"result":[{"id":"T-002","path":"docs/review.md","status":"todo","title":"Review notes"}]}
```

A task summary contains the strings `id`, `path`, `status` and `title`. The
ID keeps its stored spelling. Paths use `/` separators and are relative to the
effective task root. The status comes from the task file. Arrays retain the command's documented order and can be empty.
Consumers should look up object fields by name.

| Command | `result` |
| --- | --- |
| `list` | Array of task summaries using the same filters and sort order as text output. The default is ascending collection-relative path order. |
| `log list` | Array of entries in file order, each with string fields `timestamp` and `content`. An empty or absent log returns `[]`. |
| `add`, `import` | Summary of the task created, including the allocated ID and actual destination. |
| `show` | Task summary plus integer `schema_version`, nullable strings `priority`, `parent` and `due`, string arrays `tags` and `depends_on`, `custom` and the original Markdown `source` including delimiters and line endings. |
| `tree` | Array of task summaries with nullable `parent`, integer `depth` and `position` (`root`, `child`, `unresolved_parent` or `parent_cycle`). |
| `ready [ID]` | Array of task summaries with derived `readiness` (`ready`, `blocked` or `unresolved`). |
| `dep show` | Subject summary in `task`, direct `prerequisites` in source order, and `dependents` as summaries in path order. Each prerequisite has its written `id`, `resolution` (`resolved`, `missing`, `ambiguous`, `invalid` or `unsupported`), and an array of candidate `{id,path}` objects. |
| `dep graph` | Subject summary in `task`, the chosen `direction` (`prerequisites` or `dependents`), and an ordered `edges` array. Each edge contains string IDs `prerequisite` and `dependent`, plus the same `resolution` values as `dep show`. An isolated task has an empty array. |
| `validate` | Counts `errors` and `warnings`, booleans `scan_complete`, `history_complete` and `recovery_complete`, and a `findings` array. A completed report is available on stdout even when findings produce a nonzero exit. |
| `remove --dry-run` | A `plan` token and an `edits` array with `id`, `path`, `field` and a half-open byte `span` (`start`, `end`) in the original file. |
| `init`, `set`, `unset`, `status`, `log add`, `edit`, `move`, `remove`, `parent add/remove`, `dep add/remove`, `recover` | An acknowledgement with `ok: true` and `operation` containing the journal ID when available, otherwise JSON null. Pass the ID from `remove` to `recover rollback`. |

A validation finding carries `severity` (`error` or `warning`), `code`, `message`,
and nullable `path`, `id`, `field` and `target_id`. A known `location` contains
one-based `line` and `column` and a half-open byte `span`. An unknown location is
null. Resource-limit findings include `observed` and `limit` when available.
`related` lists ID/path pairs, and `related_count` gives the total. For references
to an ambiguous ID, the `duplicate_id` finding lists the candidates once. Cycle
`edges` use `from` for the declaring task and `to` for its stored reference.

### Custom YAML values

`show --json` represents each YAML integer as `{"$integer":"<lexeme>"}` and each
float as `{"$float":"<lexeme>"}` at every nesting level. The string preserves
the original numeric spelling, including sign, radix, leading zeros, exponent,
and YAML infinities and NaN. For example, YAML `[0007, .nan, "0007"]` becomes
`[{"$integer":"0007"},{"$float":".nan"},"0007"]`.

Custom mappings, arrays, booleans, strings and null otherwise use their native
JSON types. An absent or null top-level `custom` is null. Every user mapping
key starting with `$` gains one leading `$`. For example, a literal YAML
`{"$float": ".inf"}` becomes `{"$$float":".inf"}`. A decoder recognizes the two
numeric tags and removes one leading dollar from user keys beginning with `$$`.

## Exit codes and streams

The process returns the same status in text and JSON modes.

| Exit | Meaning |
| ---: | --- |
| 0 | The command succeeded. Empty lists, a reported blocked/unresolved readiness, and validation with warnings alone are successful results. |
| 1 | Command failure, including a malformed task ID, invalid project configuration, incomplete discovery, an unsafe edit, or a failed recovery preflight. `validate` also returns 1 when its report contains errors or an incomplete check. |
| 2 | Invalid invocation, including unknown commands or flags, missing operands and conflicting options. |
| 3 | A valid, required task ID had no match in the effective collection. |
| 4 | A required task ID matched multiple files in the effective collection. |
| 5 | A write entered persistence and did not complete, or a launched editor failed. Inspect the project and run `validate` to check recovery state. Prepared directories, journal files, reserved IDs, task changes or editor saves may remain. |
| 6 | The mutation succeeded but Kadai could not encode or deliver its response. The effect stands. Stderr identifies the command and any available task or operation ID. |
| 7 | Kadai could not represent or deliver a result before a mutation completed or during a read. Examples include an invalid UTF-8 path (`unsupported_output`) and a closed pipe while listing tasks. |

Stdout carries the requested result, including help and version text. With
`--json`, each delivered query or mutation result is one JSON document. A
command rejected before delivery leaves stdout empty. A failed write to stdout
can leave a partial document. `validate` delivers its findings on stdout even
when the report gives exit 1. Use its finding codes and completeness flags for
details. A missing prerequisite in `dep show` is part of a successful result.

Kadai writes command errors to stderr with the prefix `kadai: error:` and
project warnings with `kadai: warning:`. Warnings and an unavailable stderr
leave the command's exit code intact. In JSON mode the editor's output also
goes to stderr. In text mode the editor inherits the terminal streams.

For `add --json` and `import --json`, path encoding is checked before reserving an ID or creating
files. A rejected mutating invocation may still create the collection's lock
infrastructure. Once writing starts, codes 5 and 6 take precedence over the
underlying error. Inspect the reported task or operation before retrying.

## Project overrides

| Option | Meaning |
| --- | --- |
| `--project DIR` | Select an existing project directory. Default: exact CWD; no ancestor/Git-root search. |
| `--tasks-root DIR` | Select an independent collection within the project. Relative paths resolve against the project. |
| `--boards-root DIR` | Select the excluded boards subtree beneath the effective collection. Relative paths resolve against the task root. |
| `--id-prefix PREFIX` | Select the prefix for newly generated IDs. |
| `--timezone IANA_NAME` | Override the project time zone. |
| `--exclude GLOB` | Repeat once per pattern. Replace the configured exclusion list. Quote shell wildcards. |
| `--clear-excludes` | Replace the configured exclusion list with an empty list. Cannot combine with `--exclude`. |

Precedence is explicit option, config, then built-in default. Mandatory internal
exclusions always apply. Status/priority vocabularies have no CLI override.
Overrides do not bypass malformed config or unsupported schemas. See
[KAD-003](../specs/KAD-003-project-config-v1.md) for containment and validation.

Project overrides apply only to this invocation, except that first-time `init`
persists its effective settings using portable relative paths. Repeated `init`
validates existing config and refuses conflicting settings without rewriting it.

## Resource overrides

Use repeatable `--limit NAME=INTEGER` (or `--limit=NAME=INTEGER`). Values must be
positive decimal integers, with no sign, separators, unit suffix or exponent.
Leading zeros remain decimal. Each budget name may appear once. Omitted budgets
keep their defaults; a value equal to the maximum is accepted.

| Name | Default | Maximum | Unit |
| --- | ---: | ---: | --- |
| `task_source_bytes` | 16777216 | 268435456 | Bytes per complete task source, including body |
| `yaml_document_bytes` | 262144 | 4194304 | Bytes per YAML header or config document |
| `yaml_nodes_document` | 10000 | 100000 | YAML nodes per document, including keys |
| `yaml_depth` | 32 | 128 | Nesting depth; root is 1 |
| `filesystem_entries` | 250000 | 2000000 | Entries examined before pruning excluded subtrees |
| `markdown_candidates` | 50000 | 500000 | Non-excluded `.md` files considered |
| `scan_yaml_bytes` | 268435456 | 2147483648 | YAML bytes examined per collection scan |
| `scan_yaml_nodes` | 1000000 | 10000000 | YAML nodes examined per collection scan |
| `exclude_match_steps` | 100000000 | 1000000000 | Bytes inspected and retry steps while matching user exclusions in one invocation |

Invalid limits fail before project/config/task or body-file access. Limits apply
to the whole invocation: config, discovery, body input, locked mutation planning,
post-patch checks and the corresponding history/recovery budgets. Collection
totals exclude the standalone config parse. `init` checks both existing and
newly generated config against the same YAML limits.

Limits are never saved to `.kadai.yaml`, including by `init`, and never change
collection identity. Increasing a budget does not relax safe-editing rules.
See [KAD-006 §4](../specs/KAD-006-yaml-compatibility-mutation-v1.md#4-parser-and-collection-resource-limits).

```sh
kadai list --project ../repo --tasks-root work --clear-excludes
kadai add "Review release" --stdin --limit task_source_bytes=33554432
kadai validate --limit yaml_depth=64 --limit yaml_nodes_document=20000
```

The [KAD-053 workflow test](../../src/cli/workflow_test.odin) exercises the same commands
in initialized and unconfigured projects. KAD-054 tracks the cross-platform matrix. The
dedicated collision-repair workflow specified by KAD-004 is not exposed by this
core command set; `set id` is rejected and ambiguous IDs remain quarantined.
