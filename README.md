# Kadai

Local-first, Markdown-native task and issue tracking for developers and AI agents.

> **Status:** Early development. Kadai is being designed; there is no usable release yet. The examples below describe the intended format and behavior, not an implemented CLI.

Kadai is meant to help you keep track of work inside a project without depending on GitHub Issues, GitLab, Jira, or a hosted service. Tasks live alongside your code and can be managed as plain text or, eventually, through a CLI, TUI, and desktop app.

## Design goals

- **Markdown is the source of truth.** Each task is a `.md` file with YAML frontmatter. Its body and sections are entirely up to the author.
- **Folders are yours to organize.** Tasks can live in nested directories under a configurable project-local root.
- **One state across every interface.** Editing a task in a text editor, CLI, TUI, or future desktop app changes the same Markdown file.
- **Hierarchy and dependencies are separate.** A task can have a parent and depend on other tasks independently of where its file lives.
- **Kanban is optional.** Create multiple boards, include only selected tasks, and remove cards without deleting their tasks. Boards are Markdown files too.
- **Built for agents.** A scriptable CLI with machine-readable output will let AI coding agents discover, create, update, and relate tasks without needing an MCP server.
- **Project-local and offline.** No account, remote service, or database outside the project. Any optional index/cache must be rebuildable from the Markdown files.
- **Version-control friendly.** Tasks can be tracked and reviewed with the rest of the repository.

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

`tasks/` is a proposed default, not a required folder name. Directory placement organizes files; it does not define task hierarchy, status, or dependencies.

### Task example

```markdown
---
id: T-003
title: Implement Markdown syntax highlighting
status: in-progress
priority: high
parent: T-001
depends_on:
  - T-002
tags:
  - editor
  - textkit
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

Task IDs remain stable when files move or are renamed. Unknown frontmatter fields and arbitrary Markdown content should be preserved when the tools update a task.

**Parent/child is not the same as dependency.** `parent: T-001` places the task under T-001 in a logical task tree. `depends_on: [T-002]` means T-002 must be completed first. In a dependency view, `T-002 → T-003` means T-003 depends on T-002.

### Board example

```markdown
---
type: board
title: MVP
mode: manual
columns:
  - todo
  - in-progress
  - review
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

The precise configuration and schema are not finalized.

## Planned interfaces

| Interface | Purpose |
| --- | --- |
| CLI | Scriptable task operations, filters, dependency inspection, and JSON output for agents |
| TUI | Interactive task tree, details, search, and board views in the terminal |
| Desktop | Visual task hierarchy, dependency graph, and boards (planned for a later phase) |
| Plain Markdown | Direct editing with any text editor, without running Kadai |

The intended implementation language is Go. The TUI is expected to use Bubble Tea; a future desktop interface may use Wails.

## Initial roadmap

- [ ] Define and validate the Markdown/frontmatter schema and project configuration
- [ ] Discover tasks recursively and preserve content when updating metadata
- [ ] Implement core CLI operations and structured output
- [ ] Support parent/child relationships, dependencies, and cycle detection
- [ ] Support manually curated Markdown Kanban boards
- [ ] Build the first TUI
- [ ] Add tests for external edits, concurrent writes, and file moves
- [ ] Publish the first pre-release

Possible later additions include configurable filtered boards, historical board snapshots, a desktop app, and an optional local index for larger projects.

## Contributing

Kadai is in its early design phase. Ideas, bug reports, and discussions about the file format or workflow are welcome in GitHub Issues. Before building a larger feature, open an issue so the design can be discussed.

## License

Kadai is licensed under the [MIT License](LICENSE).
