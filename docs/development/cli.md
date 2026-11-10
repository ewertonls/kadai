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
| `list` | Accepts `--status STATUS`, `--directory DIR`, `--tag TAG` and `--parent ID`. Lists tasks matching all supplied filters. |
| `show ID` | Print the collection-relative path and original task source, or report diagnostic-only metadata. |
| `set ID FIELD [VALUE ...]` | Fields: `title`, `status`, `priority`, `due`, `tags`. Scalars require exactly one value. Tags take zero or more values; zero clears the sequence. `--force` is accepted only for `status`. |
| `unset ID FIELD` | Remove `priority`, `due` or `tags`. Required fields cannot be unset. |
| `status ID STATUS` | Alias for setting the status. `--force` permits completion with blocked/unresolved prerequisites. |
| `edit ID` | Open the source file using `$EDITOR` and wait for exit. |
| `move ID DEST` | Move/rename one task to a collection-relative file path. |
| `move --directory SOURCE DEST` | Move a collection-relative directory, preserving task identities and discoverability. |
| `remove ID` | Check references before deletion. `--detach` clears inbound reserved references, `--dry-run` prints a complete preview and plan token, and `--plan TOKEN` requires that exact plan. Prints an operation ID on deletion. |
| `parent add CHILD PARENT` | Set or replace the child's logical parent. |
| `parent remove CHILD` | Clear the child's parent. |
| `dep add TASK PREREQUISITE` | Add a direct prerequisite. A duplicate case-insensitive reference is an error. |
| `dep remove TASK PREREQUISITE` | Remove a direct prerequisite. |
| `dep show ID` | Show immediate prerequisites and dependents as `prerequisite -> dependent`. |
| `tree` | No operands. Show the logical parent hierarchy. |
| `ready [ID]` | Without an ID, list actionable ready tasks; with an ID, report `ready`, `blocked` or `unresolved`. |
| `validate` | No operands. Read-only validation of config, tasks, relationships and internal state. |
| `recover resume [OPERATION]` | Resume the pending operation or the selected operation. |
| `recover rollback [OPERATION]` | Roll back the pending operation or the selected operation. |

Task IDs are looked up case-insensitively. Relationship commands use IDs, not
paths. Directory placement does not assign parents. Status overrides never
bypass identity, graph-structure or file-safety checks.

A relative body-file path resolves against the invocation CWD, independent of `--project`.
Body bytes from files/stdin are preserved, including line endings and the final
newline. `--path` and move destinations are relative to the effective task root
and must remain discoverable. Parent directories may be created as needed.

`remove ID --detach --dry-run` does not mutate files. Use the printed token with
`remove ID --detach --plan TOKEN` to reject changes to the plan after the preview. The
operation ID from removal can be passed to `recover rollback OPERATION`.
Recovery verifies recorded state before modifying files.

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
Rows follow ascending byte order of the full collection-relative path, with
`/` as the separator.

## Terminal output

`list` prints one row per match, for example `T-002  [todo]  Review notes  (docs/review.md)`.
`tree` indents direct children beneath their parent and marks unresolved parents and
cycle members. For levels deeper than 16 it prints the depth beside the task.
`ready` shows the task's stored status and labels its derived readiness separately.
Task summaries and validation findings escape tabs, line breaks and terminal control characters.

`dep show` groups immediate prerequisites and dependents. Every arrow points from
prerequisite to dependent. An unresolved prerequisite keeps its written ID and
shows the reason. When several files claim that ID, their paths appear beneath the edge.

`validate` prints the source path and available line and column alongside each
finding, followed by its severity, code and message. Related files and cycle
edges appear on indented lines. The report names incomplete checks and gives
error and warning counts when it finds issues.

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

Stable JSON/exit-code contracts and
the full cross-platform workflow matrix remain KAD-050 through KAD-054. The
dedicated collision-repair workflow specified by KAD-004 is not exposed by this
core command set; `set id` is rejected and ambiguous IDs remain quarantined.
