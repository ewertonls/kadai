# Roadmap

> **Planning document.** Checked planning tasks indicate completed specifications, not implemented features. Implementation tasks remain unchecked until their functionality is built and verified.

**Implementation:** Odin. **Current focus:** CLI only. **Source of truth:** project-local Markdown files with YAML frontmatter.

## Scope and milestones

| Milestone | Phases | Meaning |
| --- | --- | --- |
| **v0.1** | 0–6 | A usable local task CLI with safe Markdown editing, task relationships, and validation |
| **v0.1.x** | 6a | Scheduled follow-up TODOs for richer CLI UX and explicit Markdown import, before boards |
| **v0.2** | 7 | Optional manually curated Markdown Kanban boards |
| **v0.3** | 8 | Search, task context, custom metadata, and agent ergonomics |
| **v1.0** | 9 | Stability, compatibility, performance, and distribution |

**Time budget:** Aim for a focused v0.1 after one week, not a guarantee. KAD-001 [defines the non-deferrable v0.1 contract](docs/specs/KAD-001-v0.1-scope.md); rich filtering, custom sorting, richer dependency views, and extra CLI conveniences are scheduled TODOs for v0.1.x. Do not sacrifice core functionality, safe file editing, integrity checks, or JSON contracts to meet a date. The YAML writer remains the primary schedule risk.

**Out of current planning scope:** TUI and desktop app. They may be considered only after the CLI is reliable; no implementation tasks or technology choices for them are committed here.

## Non-negotiable invariants

- Markdown is authoritative for task state. Indexes/caches remain rebuildable; a small durable used-ID record stores allocation history only, not task contents/status.
- A task's stable ID is independent of its filename and directory. Folder nesting is not automatically parent/child nesting.
- Parent/child hierarchy and `depends_on` are separate relationships. Readiness/blocking is derived from prerequisites.
- Task bodies have no required sections. Custom YAML frontmatter fields remain intact after unrelated CLI edits.
- Supported metadata edits preserve unrelated bytes and supported file security metadata. Unsafe YAML patches or filesystem link/metadata cases fail closed instead of silently discarding content.
- Manual edits take effect on the next CLI read. Kadai writers coordinate via collection locks and shared-file coordination for overlapping collections, check conflicts before atomic replacement and keep private immutable pre-write recovery copies. Non-cooperating editors can still race between final verification and replacement; do not promise absolute lost-update prevention.
- Boards reference task IDs. A board is a selection/view; task state remains in each task file.
- The CLI provides deterministic text output, structured JSON, documented errors, and no required hosted service or MCP server.

## Task backlog

### 0. Product contract and scope

**Milestone:** v0.1. **Goal:** Freeze the rules that cannot be changed casually once users have Markdown task files.

**Depends on:** None. **Done when:** A written v0.1 specification and fixtures cover valid, invalid, and hand-edited tasks.

- [x] **KAD-001** Define the v0.1 boundary. _Acceptance:_ Document the minimum CLI workflow and explicitly defer boards, TUI, and desktop. _Specification:_ [KAD-001 v0.1 scope](docs/specs/KAD-001-v0.1-scope.md).
- [x] **KAD-002** Specify task frontmatter. _Acceptance:_ List reserved keys, defaults, optional keys, status values, and the policy for arbitrary custom metadata. _Specification:_ [KAD-002 task frontmatter v1](docs/specs/KAD-002-frontmatter-v1.md).
- [x] **KAD-003** Specify project configuration. _Acceptance:_ Document `.kadai.yaml`, configurable task root, optional board root, and CWD-based project discovery rules. _Specification:_ [KAD-003 project configuration v1](docs/specs/KAD-003-project-config-v1.md).
- [x] **KAD-004** Specify task identity. _Acceptance:_ Define durable collection-local used-ID history without a numeric counter, non-reuse of CLI-issued IDs, collision quarantine after Git merges, explicit reference-aware repair, filenames and path-independent IDs. _Specification:_ [KAD-004 task identity v1](docs/specs/KAD-004-task-identity-v1.md).
- [x] **KAD-005** Specify hierarchy and dependencies. _Acceptance:_ Define hierarchy and prerequisites independently; use KAD-002's optional `parent: ID|null` field; validate parent/dependency graph, missing references, cycles, invalid statuses, three-state readiness and deletion. _Specification:_ [KAD-005 hierarchy and dependencies v1](docs/specs/KAD-005-hierarchy-dependencies-v1.md).
- [x] **KAD-006** Set YAML compatibility and mutation rules. _Acceptance:_ Define supported YAML syntax, parser resource limits (bytes, depth, nodes and collection size), ambiguous representations and failure rules for non-destructive source patches. _Specification:_ [KAD-006 YAML compatibility and source-safe mutation v1](docs/specs/KAD-006-yaml-compatibility-mutation-v1.md).
- [x] **KAD-007** Build a fixture corpus. _Acceptance:_ Include valid, invalid, partial, duplicate and unsupported-schema tasks; YAML numeric edge cases and parser limits; comments, CRLF, Unicode, nested dirs, malformed YAML and graph cycles; CWD/config/override roots, exclusion globs, and symlink boundaries from KAD-003. _Specification:_ [KAD-007 fixture corpus v1](docs/specs/KAD-007-fixture-corpus-v1.md). _Fixtures:_ [192 independent scenarios](tests/fixtures/v1/README.md); runner execution belongs to KAD-011 and later.

### 1. Odin foundation

**Milestone:** v0.1. **Goal:** Get a reproducible, testable native CLI skeleton with clean package boundaries.

**Depends on:** Phase 0. **Done when:** The command builds on a pinned Odin toolchain, prints help/version, and runs automated tests.

- [x] **KAD-008** Pin the Odin toolchain. _Acceptance:_ Record the compiler revision/release and provide setup instructions for contributors. _Reference:_ [Odin toolchain guide](docs/development/toolchain.md) (advisory pin).
- [x] **KAD-009** Define package boundaries. _Acceptance:_ Separate CLI, project/filesystem, Markdown/YAML, task domain, and graph logic without a UI dependency. _Reference:_ [Odin packages](docs/development/packages.md).
- [x] **KAD-010** Document the native Odin development workflow. _Acceptance:_ Document and verify the package check command with vetting from the repository root using the `kadai` collection. Document the test and CLI build commands, with their prerequisites in KAD-011 and KAD-012. _Reference:_ [Native development workflow](docs/development/toolchain.md#native-development-workflow).
- [x] **KAD-011** Set up Odin tests and fixtures. _Acceptance:_ Use `core:testing` and a repeatable runner for unit and integration tests. _Reference:_ [Native test commands](docs/development/toolchain.md#run-tests).
- [x] **KAD-012** Create the CLI entrypoint. _Acceptance:_ Implement `kadai --help`, `--version`, command dispatch, and a consistent error boundary. _Reference:_ [Build the CLI](docs/development/toolchain.md#build-the-cli).

### 2. Markdown and YAML editing

**Milestone:** v0.1. **Goal:** Treat the Markdown file as the authoritative document without silently rewriting unrelated content.

**Depends on:** Phases 0-1. **Done when:** Changing one supported metadata field preserves the body and all unrelated bytes; unsafe edits report an error.

- [x] **KAD-013** Spike YAML implementation options. _Acceptance:_ Compare a maintained parser, including LibYAML via Odin/C FFI, with licensing and cross-platform linking costs. Do not write a YAML parser from scratch. _Reference:_ [Parser comparison and native probe](docs/development/yaml-parser.md).
- [x] **KAD-014** Extract frontmatter boundaries. _Acceptance:_ Separate opening/closing delimiters and raw body; specify BOM, missing delimiters, and empty headers. _Reference:_ [Boundary contract](docs/specs/KAD-006-yaml-compatibility-mutation-v1.md#23-document-boundaries), [Odin extractor](src/document/frontmatter.odin).
- [x] **KAD-015** Parse known YAML fields. _Acceptance:_ Decode supported scalar and sequence fields while preserving unrecognized keys for round-trip editing. _Reference:_ [Task decoder](src/document/decode.odin), [field and source-preservation tests](src/document/decode_test.odin).
- [x] **KAD-016** Report useful YAML errors. _Acceptance:_ Include filename, line/column where available, field, and actionable diagnostics. _Reference:_ [Document diagnostics](docs/development/yaml-parser.md#diagnostics).
- [x] **KAD-017** Preserve arbitrary Markdown bodies. _Acceptance:_ Keep headings, code fences, links, whitespace, and final newline unchanged during metadata-only edits. _Reference:_ [Source composition and byte-preservation tests](docs/development/yaml-parser.md#preserving-the-markdown-body).
- [x] **KAD-018** Patch an existing top-level scalar. _Acceptance:_ Update fields such as `status` or `title` while preserving unrelated text, comments, and quoting where supported. _Reference:_ [Scalar patch contract and tests](docs/development/yaml-parser.md#replacing-a-task-scalar).
- [x] **KAD-019** Insert and remove top-level metadata keys. _Acceptance:_ Support a missing field or explicit unset without resaving the whole YAML document. _Reference:_ [Top-level key edits](docs/development/yaml-parser.md#inserting-and-removing-task-fields).
- [x] **KAD-020** Edit known YAML sequences. _Acceptance:_ Safely update `tags` and `depends_on`, preserving other fields and refusing ambiguous layouts. _Reference:_ [Sequence edits and tests](docs/development/yaml-parser.md#editing-sequence-items).
- [x] **KAD-021** Handle YAML edge cases defensively. _Acceptance:_ Test quoted keys, inline comments, block scalars, aliases/anchors, duplicate keys, line endings, and unsupported edits. _Reference:_ [YAML edge cases and regression tests](docs/development/yaml-parser.md#yaml-edge-cases).
- [x] **KAD-022** Add byte-level golden tests. _Acceptance:_ Assert that metadata mutations change only intended spans; malformed or unsupported cases never produce destructive output. _Reference:_ [Byte-level patch tests](docs/development/yaml-parser.md#byte-level-patch-tests).

### 3. Project storage and filesystem

**Milestone:** v0.1. **Goal:** Discover project-local tasks reliably and persist changes safely.

**Depends on:** Phases 0 and 2. **Done when:** Tasks in arbitrary nested directories are discovered; safe file operations and conflict detection work without a DB.

- [x] **KAD-023** Implement optional `kadai init`. _Acceptance:_ Create minimal project-local config and effective task directory only on explicit invocation, support safe idempotent recovery, and never overwrite existing files.
- [x] **KAD-024** Implement project/collection root resolution. _Acceptance:_ Default project to exact CWD, support exact `--project` and independent `--tasks-root`, resolve physical paths, enforce containment and effective config precedence per KAD-003; never discover a Git root implicitly.
- [x] **KAD-025** Scan nested directories. _Acceptance:_ Distinguish indexed valid tasks, diagnostic-only invalid candidates and unsupported-schema documents; exclude ordinary Markdown, boards, `.kadai/`, nested projects/repos, symlinks and configured globs while reporting malformed task-like files.
- [x] **KAD-026** Define path and symlink safety. _Acceptance:_ Define safe path resolution and handling for symlinks/hardlinks, root escapes and OS-specific filesystem metadata; refuse unsafe mutations.
- [x] **KAD-027** Build a transient task index. _Acceptance:_ Build a transient ID index, quarantine all case-insensitive duplicate-ID groups (including Git merges) and retain diagnostic-only invalid candidates without choosing arbitrary winners.
- [x] **KAD-028** Handle creates, moves, and renames. _Acceptance:_ Preserve stable IDs while changing file paths and detect destination collisions.
- [ ] **KAD-029** Implement atomic file writes. _Acceptance:_ Stage atomic replacement on the same filesystem, preserve supported ownership/mode/ACLs/xattrs or fail closed, keep private immutable pre-write recovery snapshots and test rollback/durability on all OSes. _Implementation:_ [storage](docs/development/storage.md). Native macOS and Linux tests pass. Native Windows validation is pending.
- [ ] **KAD-030** Detect concurrent edits. _Acceptance:_ Coordinate Kadai writes with collection-scoped native locks plus cross-collection coordination for shared physical files (including atomic replacement), verify identity/hash immediately before replacing, reject detected conflicts, document the residual external-editor race and test recovery.

### 4. Task domain and CRUD

**Milestone:** v0.1. **Goal:** Make all basic task operations work through the domain core before wiring CLI output.

**Depends on:** Phases 2-3. **Done when:** A task can be created, retrieved, updated, moved, and removed without losing unrelated Markdown.

- [ ] **KAD-031** Create tasks with unique IDs. _Acceptance:_ Reserve generated IDs durably before file creation; never reuse recorded IDs after deletion; default to `status: todo` when omitted; support title-only empty-body and `--body-file`/`--stdin`.
- [ ] **KAD-032** Get and list tasks. _Acceptance:_ Resolve a task by ID and return deterministic listing data, including path and parsed metadata.
- [ ] **KAD-033** Update core metadata. _Acceptance:_ Set/unset title, status, priority, tags, and other supported fields using the safe writer.
- [ ] **KAD-034** Define status transitions. _Acceptance:_ Support planned task states and reopening; treat blocked/readiness as derived information.
- [ ] **KAD-035** Open a task in an external editor. _Acceptance:_ Support `$EDITOR` as a plain-text editing path without a proprietary editor.
- [ ] **KAD-036** Move and rename tasks. _Acceptance:_ Keep ID-based references intact when the underlying Markdown file changes path.
- [ ] **KAD-037** Remove tasks safely. _Acceptance:_ Require explicit deletion and reference checking; preserve used-ID/tombstone history before removing files so allocated IDs cannot be silently reused.
- [ ] **KAD-038** Test editor/CLI equivalence. _Acceptance:_ Manually edit a task between commands and verify subsequent reads reflect the changed source file.

### 5. Hierarchy, dependencies, and validation

**Milestone:** v0.1. **Goal:** Provide logical hierarchy and dependency analysis independent of filesystem folders.

**Depends on:** Phase 4. **Done when:** Parent trees, prerequisite edges, ready/blocked results, and integrity diagnostics are correct.

- [ ] **KAD-039** Add and remove parent links. _Acceptance:_ Manage one logical parent per task, independent of file location.
- [ ] **KAD-040** Add and remove dependency links. _Acceptance:_ Persist `depends_on` references and define A → B to mean B depends on A.
- [ ] **KAD-041** Detect cycles across relationships. _Acceptance:_ Reject parent cycles and dependency cycles on CLI mutations.
- [ ] **KAD-042** Detect invalid references and IDs. _Acceptance:_ Report missing parents, missing dependencies, self-links, and duplicate task IDs.
- [ ] **KAD-043** Build a task tree view. _Acceptance:_ Display indented parent/child hierarchy with stable ordering and task IDs.
- [ ] **KAD-044** Build a dependency view. _Acceptance:_ Show immediate prerequisites and reverse dependents with explicit arrow direction.
- [ ] **KAD-045** Derive ready and blocked tasks. _Acceptance:_ Compute `ready`/`blocked`/`unresolved` from direct prerequisites without persisting derived state; invalid or unknown prerequisite status/category/schema yields unresolved.
- [ ] **KAD-046** Implement project validation. _Acceptance:_ Report all detectable integrity issues; validation itself never modifies files.

### 6. CLI UX, tests, and first release

**Milestone:** v0.1. **Goal:** Ship a useful CLI that works equally well for people and coding agents.

**Depends on:** Phases 1-5. **Done when:** The documented commands pass CLI-to-file integration tests on macOS, Linux, and Windows; a tagged pre-release exists.

- [ ] **KAD-047** Implement core command grammar. _Acceptance:_ Expose optional init; add with `--body-file`/`--stdin`; list, show, set/status, edit, move, remove, parent, dep, tree, ready, validate; and `--project`, `--tasks-root`, `--exclude` and other KAD-003 effective-configuration overrides.
- [ ] **KAD-048** Add basic list filters and deterministic ordering. _Acceptance:_ Filter by status, directory, tags, and parent with stable default ordering; advanced predicates and custom sort modes are KAD-080/KAD-081 (v0.1.x).
- [ ] **KAD-049** Make readable terminal output. _Acceptance:_ Show compact task lists, trees, dependency arrows, and clear validation messages.
- [ ] **KAD-050** Add JSON output contracts. _Acceptance:_ Define stable ID/path/status JSON contracts plus reversible encoding (or explicit unsupported-output error) for non-JSON-safe YAML numbers, including large integers and `.nan`/`.inf`.
- [ ] **KAD-051** Define exit codes and stderr policy. _Acceptance:_ Make errors distinguishable in scripts; keep normal JSON output free of logs.
- [ ] **KAD-052** Support automation defaults. _Acceptance:_ Avoid mandatory prompts; use explicit flags for destructive operations and support safe noninteractive use.
- [ ] **KAD-053** Test end-to-end command workflows. _Acceptance:_ In initialized and unconfigured projects, create title-only and file/stdin-body tasks; hand-edit, update, move, relate, validate, and read the same tasks via CLI.
- [ ] **KAD-054** Run the cross-platform test matrix. _Acceptance:_ Test path separators, UTF-8, permissions/ACLs/xattrs, symlinks/hardlinks, replacement/recovery and competing writers on macOS, Linux and Windows.
- [ ] **KAD-055** Publish v0.1 pre-release. _Acceptance:_ Document real syntax, build/package binaries, verify license notices and secrets, and publish when ready.

### 6a. v0.1.x follow-ups (scheduled TODOs)

**Milestone:** v0.1.x, after the safe v0.1 core and before v0.2 boards. **Goal:** Complete non-essential CLI enhancements and explicit import without weakening the v0.1 release boundary.

**Depends on:** Phase 6. **Done when:** Every task below is implemented and tested. These tasks are postponed, not cancelled.

- [ ] **KAD-080** Add advanced task filtering. _Acceptance:_ Support documented multi-criteria and advanced filter expressions beyond the baseline status/directory/tag/parent filters, with predictable text/JSON behavior and tests.
- [ ] **KAD-081** Add custom sorting. _Acceptance:_ Support documented user-selectable sort keys and order directions beyond the default stable order; tie-breaking stays deterministic in text and JSON.
- [ ] **KAD-082** Add richer dependency visualizations. _Acceptance:_ Provide expanded graph or transitive dependency views beyond the v0.1 immediate prerequisites/dependents, without changing dependency semantics or task files.
- [ ] **KAD-083** Add CLI convenience features. _Acceptance:_ Document and implement post-v0.1 ergonomic improvements (such as richer terminal presentation and editor shortcuts), preserving script-safe defaults and existing command contracts.
- [ ] **KAD-084** Implement explicit `kadai import` for Markdown. _Acceptance:_ Convert user-selected ordinary `.md` files into valid tasks only on explicit request; preserve the existing Markdown body, handle IDs/collisions, provide a non-destructive preview or clear opt-in, and never overwrite source or destination files silently.

### 7. Manual Markdown Kanban boards

**Milestone:** v0.2. **Goal:** Provide optional, manually curated boards without duplicating task state.

**Depends on:** Phase 6. **Done when:** Multiple boards can select, order, and display task IDs; removing a card never deletes its task.

- [ ] **KAD-056** Finalize the board document schema. _Acceptance:_ Define board identity, column-to-status mapping, membership list, and order as Markdown frontmatter.
- [ ] **KAD-057** Add board file discovery. _Acceptance:_ Find boards beneath the effective task root in the configurable board subtree without mistaking them for tasks.
- [ ] **KAD-058** Create, list, show, and remove boards. _Acceptance:_ Manage board Markdown files through dedicated CLI commands.
- [ ] **KAD-059** Add and remove board membership. _Acceptance:_ Reference tasks by stable ID; reject duplicates without editing the task's own metadata.
- [ ] **KAD-060** Group and order cards. _Acceptance:_ Render cards by current task status and persist manual card order in the board file.
- [ ] **KAD-061** Move cards between status columns. _Acceptance:_ Update the task's `status` in its Markdown file, not a duplicated status in the board.
- [ ] **KAD-062** Validate board references. _Acceptance:_ Detect missing task IDs, unknown status columns, and malformed board definitions.
- [ ] **KAD-063** Test multi-board consistency. _Acceptance:_ Verify that manual task edits update every board's view and board removal never deletes a task.

### 8. Agent workflows and CLI ergonomics

**Milestone:** v0.3. **Goal:** Make sessions of human and AI work easier to resume without imposing Markdown body sections.

**Depends on:** Phases 6-7. **Done when:** Agents can query context, modify supported metadata, and append progress with stable CLI/JSON contracts.

- [ ] **KAD-064** Add text search. _Acceptance:_ Search titles, metadata, paths, and Markdown bodies with predictable CLI filters.
- [ ] **KAD-065** Add generic metadata inspection. _Acceptance:_ Read arbitrary YAML frontmatter fields without discarding custom keys.
- [ ] **KAD-066** Add safe custom metadata updates. _Acceptance:_ Set and remove custom keys where the YAML patcher can preserve source formatting.
- [ ] **KAD-067** Support progress notes. _Acceptance:_ Append Markdown notes or update an explicitly requested section without imposing a template.
- [ ] **KAD-068** Provide compact context commands. _Acceptance:_ Offer a concise task view with parents, prerequisites, dependents, and recent progress where available.
- [ ] **KAD-069** Improve piped and scripted input. _Acceptance:_ Extend the v0.1 `add --stdin` body input with documented structured JSON input and richer scripted operations where useful.
- [ ] **KAD-070** Add preview and bulk safety. _Acceptance:_ Provide dry-run/diff for mutations and require explicit confirmation or flags for bulk destructive changes.
- [ ] **KAD-071** Publish agent integration guidance. _Acceptance:_ Document safe command recipes and optional agent instruction files; keep MCP optional.

### 9. Hardening and CLI v1.0

**Milestone:** v1.0. **Goal:** Stabilize data compatibility, correctness, performance, packaging, and documentation.

**Depends on:** Phases 0-8. **Done when:** The CLI has versioned on-disk contracts, reproducible releases, bounded performance, and verified recovery behavior.

- [ ] **KAD-072** Stress-test concurrent writers. _Acceptance:_ Stress coordinated Kadai writers and uncoordinated external-editor saves; verify detected conflicts, recovery snapshots and the documented residual race without claiming an impossible absolute guarantee.
- [ ] **KAD-073** Fuzz parsers and path handling. _Acceptance:_ Test malformed input, large values, odd Unicode, symlinks, and hostile YAML within documented limits.
- [ ] **KAD-074** Benchmark larger projects. _Acceptance:_ Measure scans, filtering, and dependency queries with 1k–10k tasks and track regressions.
- [ ] **KAD-075** Evaluate optional caching. _Acceptance:_ Introduce a rebuildable project-local index only if benchmarked performance warrants it.
- [ ] **KAD-076** Document schema evolution. _Acceptance:_ Define forward/backward compatibility and explicit, backup-aware migrations for future format changes.
- [ ] **KAD-077** Add release distribution. _Acceptance:_ Package checksummed macOS/Linux/Windows binaries and optional package-manager installation.
- [ ] **KAD-078** Improve diagnostics and repair tooling. _Acceptance:_ Offer non-destructive suggestions and explicitly opted-in fixes for invalid files or stale references.
- [ ] **KAD-079** Freeze v1 CLI and document compatibility. _Acceptance:_ Publish command and JSON contracts, usage guides, contributing docs, changelog, and release checks.

## Suggested first-week critical path

| Day | Focus |
| --- | --- |
| 1 | Phase 0 and Odin skeleton; test YAML parser viability early |
| 2–3 | Safe frontmatter extraction, patching, golden tests |
| 4 | Project scanning, index, atomic writes, conflict detection |
| 5 | Task CRUD and status changes; direct `.md` edits reflected in reads |
| 6 | Parent/dependency relations, validation, basic human/JSON CLI |
| 7 | End-to-end tests, CLI documentation, initial pre-release if ready |

This schedule is a planning target, not a promised delivery. Manual boards begin **after** v0.1. If the YAML round-trip behavior is not trustworthy, do not ship mutating commands.

## Release acceptance checklist

- [ ] A task created or edited by hand appears on the next CLI read.
- [ ] CLI status updates leave the Markdown body unchanged and preserve unrelated YAML content.
- [ ] Moving a file keeps its ID, parent links, and dependency links valid.
- [ ] Invalid/ambiguous YAML and **detected** concurrent-write conflicts fail safely. Recovery and limitations with non-cooperating editors are documented.
- [ ] `kadai validate` reports duplicate IDs, broken references, and cycles.
- [ ] `--json` output is parseable and does not mix in log messages.
- [ ] CI exercises builds/tests for macOS, Linux, and Windows.
- [ ] Real commands, installation steps, and any known limitations are documented before release.

## Technical decisions pending

- **YAML distribution:** KAD-013 selected LibYAML. Release packaging still needs to verify native linking and include the appropriate license notices for each target. [Development link options](docs/development/yaml-parser.md#licensing-and-linking).
- **ID generation:** KAD-002 fixes collection-local case-insensitive sequential IDs with optional prefix and durable used-ID history; KAD-004 owns the record format, post-merge repair, filenames and collision details.
- **Deletion:** Specify whether v0.1 removes files outright, moves them to a project-local trash directory, or requires explicit `--force`.
- **YAML patch scope:** Specify readable-but-uneditable YAML constructs, parser resource limits, v1 deadline grammar and lossless JSON numeric handoff.
- **Board columns:** In v0.2, column status mappings must be unambiguous; custom workflow rules can come later.

## Future ideas, not scheduled

Filtered/dynamic boards, historical board snapshots, optional project-local caching, cross-project queries, TUI, and desktop UI. These are not part of the current CLI milestones; the v0.1.x enhancements and `kadai import` above are explicitly scheduled, not unscheduled ideas.

## References

- [Odin documentation](https://odin-lang.org/docs/)
- [Odin test runner](https://odin-lang.org/docs/testing/)
- [LibYAML](https://github.com/yaml/libyaml)
