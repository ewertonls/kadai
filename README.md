# Kadai

Local-first, Markdown-native task and issue tracking for developers and AI agents.

> **Status:** Early development. The CLI supports task creation, activity logs, metadata edits, moves, removal, recovery, hierarchy, dependencies and read-only validation. Queries and mutations support [versioned JSON output](docs/development/cli.md#json-output-v1) with `--json`.

Kadai is meant to help you keep track of work inside a project without depending on GitHub Issues, GitLab, Jira, or a hosted service. Tasks live alongside your code and can be edited as plain text or managed through a CLI.

**Kadai is being built in [Odin](https://odin-lang.org/), with the CLI as the sole development focus for now.** Additional interfaces may be explored later, but are not part of the current roadmap.

## Install a release binary

Open [Kadai releases](https://github.com/ewertonls/kadai/releases), select the version, and download `SHA256SUMS` and the package for your machine. The four targets are `linux-amd64`, `linux-arm64`, `darwin-arm64` (Apple silicon), and `windows-amd64`. The binary includes LibYAML.

For example, on Linux x64, run these commands in a directory containing the two downloads for `v0.1.0-rc.1`:

```sh
sha256sum --check --ignore-missing SHA256SUMS &&
  tar -xzf kadai-0.1.0-rc.1-linux-amd64.tar.gz &&
  ./kadai --version
```

On Linux ARM64, extract the `linux-arm64.tar.gz` package for your version. On macOS, use `shasum -a 256 kadai-0.1.0-rc.1-darwin-arm64.tar.gz`, compare its digest with the matching line of `SHA256SUMS`, then extract with `tar -xzf`. On either system, copy `kadai` to a directory on your `PATH` to run it from any project.

On Windows x64, use PowerShell. Compare the first command's hash with the entry for the ZIP in `SHA256SUMS` before extracting:

```powershell
Get-FileHash .\kadai-0.1.0-rc.1-windows-amd64.zip -Algorithm SHA256
Expand-Archive .\kadai-0.1.0-rc.1-windows-amd64.zip -DestinationPath .\kadai-cli
.\kadai-cli\kadai.exe --version
```

The expected output for this version is `kadai 0.1.0-rc.1`. Add the extracted directory to your Windows `Path` to use `kadai` from any project.

## Build the CLI

Install [Odin](docs/development/toolchain.md#installation) and run this from the repository root. Kadai's standard build selects static LibYAML with `-define:YAML_STATIC=true`, so users do not need a separate LibYAML installation to run the executable.

```sh
odin build cmd/kadai -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=true
./kadai --version
```

On Windows, run `.\kadai.exe --version`. The [build guide](docs/development/toolchain.md#build-the-cli) covers static library setup and optional dynamic linking.

## Run tests

Run the full suite from the repository root. On Windows, append `-define:ODIN_TEST_THREADS=1` to the command.

```sh
odin test tests -all-packages -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=true
```

## Design goals

- **Markdown is the source of truth.** Each task is a `.md` file with YAML frontmatter. Authors choose their own sections and can keep an optional activity log at the end.
- **Folders are yours to organize.** Tasks can live in nested directories under a configurable project-local root.
- **Plain text and CLI stay in sync.** Editing a task manually or through the CLI changes the same Markdown file. There is no separate authoritative database.
- **Hierarchy and dependencies are separate.** A task can have a parent and depend on other tasks independently of where its file lives.
- **Kanban is optional.** Create multiple boards, include only selected tasks, and remove cards without deleting their tasks. Boards are Markdown files too.
- **Built for agents.** A scriptable CLI with machine-readable output lets AI coding agents discover, create, update, and relate tasks without needing an MCP server.
- **Local and offline.** No account, remote service or authoritative task-state DB. Markdown owns task state; each task collection keeps a durable used-ID record so CLI-generated IDs are not reused after task deletion while its history is retained. Optional indexes remain rebuildable.
- **Version control is optional.** Track tasks and history in Git if useful, or keep collections untracked, per-worktree or ephemeral. Kadai does not manage `.gitignore`.

## Proposed file layout

```text
my-project/
├── .kadai.yaml
├── src/
└── tasks/
    ├── editor/
    │   ├── T-001-editor.md
    │   └── textkit/
    │       └── T-003-highlighting.md
    ├── graph/
    │   └── T-005-graph-view.md
    └── boards/
        ├── mvp.md
        └── editor-refactor.md
```

`tasks/` is the default collection directory, not a required folder name; `tasks.root: .` is also supported. Directory placement organizes files but does not define task hierarchy, status, or dependencies. Configuration is optional: without `--project`, Kadai uses exactly the current working directory (CWD), even inside a Git repository, and looks only there for `.kadai.yaml`. `--project <path>` selects a different existing project directory; `--tasks-root <path>` selects an independent collection within it. Valid task files enter the task index; invalid candidates produce separate diagnostics, while ordinary `.md` documents are ignored.

### Task example

```markdown
---
kadai: task
id: T-003
title: Implement Markdown syntax highlighting
status: in_progress
priority: high
depends_on:
  - T-002
tags:
  - editor
  - textkit
custom:
  sprint: 1
---

# Implement Markdown syntax highlighting

Use TextKit attributes to highlight Markdown without modifying
the text being edited.

## Progress

- [x] Explore available APIs
- [ ] Implement incremental updates
- [ ] Test large files

## Notes

Add whatever sections, links, or content are useful.
```

Task IDs remain stable when files move or are renamed. The four required frontmatter keys are `kadai: task`, `id`, `title`, and `status`; the v1 defaults and validation rules are in [KAD-002](docs/specs/KAD-002-frontmatter-v1.md). User-defined metadata belongs under `custom`. Unknown top-level keys produce diagnostics; unrelated YAML and arbitrary Markdown body content must be preserved by the CLI.

The `parent` field links a task to its logical parent. In the example above, `depends_on: [T-002]` means T-002 must be completed before T-003 is ready. The dependency view displays this as `T-002 -> T-003`.

### Board example

This is an illustrative proposal, not the final v0.2 board schema (KAD-056).

```markdown
---
type: board
title: MVP
mode: manual
columns:
  - todo
  - in_progress
  - blocked
  - done
tasks:
  - T-001
  - T-003
  - T-005
---

# MVP

Selected tasks for this milestone.
```

A board references tasks by ID. It does not own or duplicate their status: moving a card to another column updates the task's frontmatter. Removing a task from a board does not remove its Markdown file.

Task frontmatter v1 is specified in [KAD-002](docs/specs/KAD-002-frontmatter-v1.md), and project configuration v1 is accepted in [KAD-003](docs/specs/KAD-003-project-config-v1.md). Generated IDs use collection-local, durable [reservation markers](docs/specs/KAD-004-task-identity-v1.md). Kadai-coordinated writes check for conflicts and keep recovery copies, but a non-cooperating external editor can still save during the final check/replacement interval.

## CLI-first workflow

The CLI is the primary interface for developers and coding agents. Direct Markdown editing and unconfigured read/write workflows remain supported. `kadai init` is optional; `kadai add` writes `status: todo` by default. Writes may create collection-local history under `<tasks.root>/.kadai/` without creating `.kadai.yaml`. Kadai never modifies `.gitignore`.

Run `kadai` for a short description of each command. Use `kadai help add` or `kadai add --help` for usage, examples and flags. Flags can appear anywhere after the command and before `--`. Both `--project DIR` and `--project=DIR` select a project. Use `--` before a positional argument that starts with a hyphen, as in `kadai add -- -draft`.

The [core CLI grammar](docs/development/cli.md) documents commands, project overrides and all eight resource budgets. Use `--limit NAME=INTEGER` to override a budget for one invocation, for example `kadai validate --limit yaml_depth=64`. Invalid limits fail before input-file access; limits also govern locked writes and recovery and are never saved by `init`.

Commands use the configured exclusion list by default. Supply `--exclude GLOB` once per replacement pattern, for example `kadai list --exclude 'archive/**' --exclude 'drafts/**'`. To clear the configured list, use `--clear-excludes` in place of the former `--exclude ""` syntax. Combining `--clear-excludes` with `--exclude` is an error. Kadai's mandatory internal exclusions still apply.

`kadai edit ID` opens the task file in `$EDITOR` and waits for the editor process. To choose an editor for one task, run `kadai edit 0001 --editor 'nvim --clean'`. Quote paths or arguments containing spaces. Saves made in the editor appear on the next Kadai read.

`kadai list --long` shows priority and due date below each matching task. Add `--sort priority --order desc` to see the highest priorities first.

In a fresh collection, the first generated ID is `0001`. Task destinations are relative to the effective task root.

```sh
kadai add "Implement syntax highlighting" --path editor/parser.md
kadai list --status todo --directory editor
kadai show 0001
kadai set 0001 tags parser cli
kadai set 0001 priority high
kadai unset 0001 priority
kadai status 0001 in_progress
kadai move 0001 editor/highlight.md
kadai edit 0001
```

`add --body-file PATH` and `add --stdin` preserve the supplied Markdown body. `move --directory SOURCE DEST` renames a directory after checking its contents and destination. Moves preserve frontmatter IDs.

Use `kadai log add 0001 "Parser handles empty files"` to append a timestamped Markdown entry. Use `kadai log list 0001` to read the entries in file order. For longer notes, pass `--stdin` or `--body-file PATH`, or edit the log directly in the task file. [Activity log format](docs/development/cli.md#task-activity-logs).

`kadai import notes.md --yes` creates a new `todo` task with the entire file as its body and leaves `notes.md` in place. Use `--title` to override the filename-derived title or `--path` to choose an unused destination. [Importing Markdown](docs/development/cli.md#importing-markdown).

`remove ID --yes` deletes an unreferenced task. Preview detachment with `remove ID --detach --dry-run`, then use `remove ID --detach --plan TOKEN` to apply that exact plan. Removal returns an operation ID for `recover rollback OPERATION --yes`. For an interrupted operation in the same collection, use `recover resume --yes` or `recover rollback --yes`. These commands run without prompts. [Noninteractive use](docs/development/cli.md#noninteractive-use).

Use `kadai parent add CHILD PARENT` to set a parent and `kadai parent remove CHILD` to clear it. `kadai tree` shows the hierarchy and identifies broken parent links and cycles.

`kadai dep add TASK PREREQUISITE` and `kadai dep remove TASK PREREQUISITE` edit direct prerequisites. `kadai dep show ID` shows both immediate prerequisites and dependents. `kadai ready` lists actionable tasks whose prerequisites are complete. `kadai ready ID` shows an individual task's derived state as `ready`, `blocked` or `unresolved`.

Use `kadai dep graph ID` to follow a chain of prerequisites, or `kadai dep graph ID dependents` to see which tasks depend on it. Each arrow runs from prerequisite to dependent.

`kadai validate` checks the effective configuration, task files, relationships, used-ID history and recovery records. It reads existing state without creating files or making repairs. Validation exits with 1 for errors or incomplete checks and 0 for a clean result or warnings alone. Scripts can distinguish missing or ambiguous IDs, incomplete writes, and response failures using the [CLI exit codes](docs/development/cli.md#exit-codes-and-streams).

## Roadmap

The full implementation plan, task IDs, dependencies, and release criteria are in [ROADMAP.md](ROADMAP.md). Accepted specifications: [KAD-001: v0.1 scope](docs/specs/KAD-001-v0.1-scope.md), [KAD-002: task frontmatter v1](docs/specs/KAD-002-frontmatter-v1.md), and [KAD-003: project configuration v1](docs/specs/KAD-003-project-config-v1.md).

The first milestone is a reliable **Odin CLI** for project-local Markdown tasks, hierarchy, dependencies, and validation. The **v0.1.x** CLI enhancements and explicit Markdown import are implemented. Optional manual Kanban boards are planned for v0.2 and agent workflow enhancements for v0.3. TUI and desktop are not planned for the current development cycle.

## Contributing

Kadai is in its early design phase. Ideas, bug reports, and discussions about the file format or workflow are welcome in GitHub Issues. Before building a larger feature, open an issue so the design can be discussed.

Contributor setup: [Odin toolchain guide](docs/development/toolchain.md) (reference release, official downloads, checksums, and platform requirements).

## License

Kadai is licensed under the [MIT License](LICENSE).
