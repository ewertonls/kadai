# Kadai

Local-first, Markdown-native task and issue tracking for developers and AI agents.

> **Status:** Early development. Kadai is being designed; there is no usable release yet. The examples below describe the intended format and behavior, not an implemented CLI.

Kadai is meant to help you keep track of work inside a project without depending on GitHub Issues, GitLab, Jira, or a hosted service. Tasks live alongside your code and can be edited as plain text or managed through a CLI.

**Kadai is being built in [Odin](https://odin-lang.org/), with the CLI as the sole development focus for now.** Additional interfaces may be explored later, but are not part of the current roadmap.

## Design goals

- **Markdown is the source of truth.** Each task is a `.md` file with YAML frontmatter. Its body and sections are entirely up to the author.
- **Folders are yours to organize.** Tasks can live in nested directories under a configurable project-local root.
- **Plain text and CLI stay in sync.** Editing a task manually or through the CLI changes the same Markdown file. There is no separate authoritative database.
- **Hierarchy and dependencies are separate.** A task can have a parent and depend on other tasks independently of where its file lives.
- **Kanban is optional.** Create multiple boards, include only selected tasks, and remove cards without deleting their tasks. Boards are Markdown files too.
- **Built for agents.** A scriptable CLI with machine-readable output will let AI coding agents discover, create, update, and relate tasks without needing an MCP server.
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

**Parent/child is not the same as dependency.** The reserved `parent` field will link tasks into a logical tree, with its precise schema defined in KAD-005. `depends_on: [T-002]` means T-002 must be completed first. In a dependency view, `T-002 → T-003` means T-003 is dependent on T-002.

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

Task frontmatter v1 is specified in [KAD-002](docs/specs/KAD-002-frontmatter-v1.md), and project configuration v1 is accepted in [KAD-003](docs/specs/KAD-003-project-config-v1.md). Task identity allocation (KAD-004), hierarchy (KAD-005), and YAML patch limitations (KAD-006) remain pending. Kadai-coordinated writes check for conflicts and keep recovery copies, but a non-cooperating external editor can still save during the final check/replacement interval.

## CLI-first workflow

The CLI is the primary interface for developers and coding agents. Direct Markdown editing and unconfigured read/write workflows remain supported. `kadai init` is optional; `kadai add` writes `status: todo` by default. Writes may create collection-local history under `<tasks.root>/.kadai/` without creating `.kadai.yaml`. Kadai never modifies `.gitignore`.

The following commands are **proposed examples**, not an available or finalized CLI:

```sh
kadai init # optional, creates project configuration explicitly
kadai add "Implement syntax highlighting" --dir editor
kadai add "Write tests" --body-file ./tests.md
cat ./notes.md | kadai add "Investigate" --stdin
kadai list --json
kadai status T-003 in_progress
kadai dep add T-003 T-002
kadai tree
kadai ready --json
kadai validate
```

The goal is to provide predictable commands, machine-readable output, and useful exit codes without requiring a daemon, a hosted backend, or an MCP server.

## Roadmap

The full implementation plan, task IDs, dependencies, and release criteria are in [ROADMAP.md](ROADMAP.md). Accepted specifications: [KAD-001: v0.1 scope](docs/specs/KAD-001-v0.1-scope.md), [KAD-002: task frontmatter v1](docs/specs/KAD-002-frontmatter-v1.md), and [KAD-003: project configuration v1](docs/specs/KAD-003-project-config-v1.md).

The first milestone is a reliable **Odin CLI** for project-local Markdown tasks, hierarchy, dependencies, and validation. Advanced CLI enhancements and explicit `kadai import` are scheduled for **v0.1.x**, before optional manual Kanban boards in v0.2. Agent workflow enhancements follow in v0.3. TUI and desktop are not planned for the current development cycle.

## Contributing

Kadai is in its early design phase. Ideas, bug reports, and discussions about the file format or workflow are welcome in GitHub Issues. Before building a larger feature, open an issue so the design can be discussed.

## License

Kadai is licensed under the [MIT License](LICENSE).
