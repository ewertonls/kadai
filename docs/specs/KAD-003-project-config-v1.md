# KAD-003: project configuration v1 contract

> **Status:** Accepted specification, not implemented.
> **Milestone:** v0.1. **Owner task:** KAD-003. **Recorded:** 2026-11-07.
> **Depends on:** [KAD-001 product scope](KAD-001-v0.1-scope.md) and [KAD-002 task frontmatter v1](KAD-002-frontmatter-v1.md).
> **Scope:** Project selection, `.kadai.yaml`, effective configuration, task collections, directory discovery/exclusions, initialization and internal-state placement.

## 1. Model and invariants

Kadai is an offline task manager whose task content and status live in Markdown files. Initialization and `.kadai.yaml` are optional. A **project** is a selected existing directory, while a **task collection** is the effective `tasks.root` within that project. Exactly one collection is operated on per command.

- The implicit project is the **current working directory (CWD)**, exactly. `--project PATH` selects a different directory exactly; it does not initiate an ancestor search.
- Git is **not** used to select a project. A `.git` marker never changes the project root. No Git executable, repository, index, ignore file, or worktree is required for ordinary operation.
- Every collection owns its task scan, local ID namespace, durable used-ID history, native lock and recovery state. An overridden `tasks.root` selects a different collection, not a temporary mutation of the configured collection.
- All collection roots must remain physically within the selected project. A project may contain multiple independent, temporary, per-worktree or persistent collections. Overlap between roots is allowed and has explicit risks (Section 9).
- No Kadai file needs to be Git-tracked. Kadai never creates or modifies `.gitignore` or `.git/info/exclude`. The user decides whether to track tasks, config, history or any other file.
- The content of a task is governed by KAD-002. The project configuration does not introduce a second authoritative task-state store.

This specification **supersedes the earlier Git-root fallback** in KAD-001. That document and the implementation roadmap are updated accordingly.

## 2. Project and configuration discovery

1. Establish the invocation CWD. If `--project PATH` is supplied, resolve a relative `PATH` against that CWD; otherwise select the CWD itself.
2. Require that the selected project directory already exists. `kadai init` also does **not** create missing project roots.
3. Canonicalize the selected directory to its physical location. Explicit selection through a symlink is allowed and **must** emit a diagnostic warning naming the supplied path and resolved target. Cyclic, missing, inaccessible or unresolvable selections fail.
4. Look for **only** `<selected-project>/.kadai.yaml`. Do not search ancestors, the Git root, nested child directories, or global configuration.
5. If the file is absent, use the complete built-in defaults (Section 3). Normal commands never create the file.
6. If present, parse and validate it before task discovery. Invalid configuration stops ordinary commands. `kadai validate` reports effective-configuration errors and does not scan tasks when that validation fails.

The `.kadai.yaml` file may itself be an internal symlink, provided its physical target remains within the selected project's physical root. Emit the same original-path/target warning. Reject external targets and unsafe, unresolvable links. This exception for explicitly loaded configuration files does **not** mean task discovery follows symlinks.

No implicit parent-project inheritance exists. For example, running from `repo/src/` selects `repo/src/`, even if `repo/.kadai.yaml` exists. Use `--project repo` (or its absolute path) to select the parent.

## 3. Configuration v1 schema

The file is a UTF-8 YAML mapping. Its complete set of recognized top-level keys is:

| Key | Shape | Absent or `null` default | Contract |
| --- | --- | --- | --- |
| `schema_version` | Positive integer | `1` | Only supported version is `1`; any unknown version is fatal. |
| `tasks` | Mapping | Built-in task options | Optional `root` and `exclude` only. |
| `tasks.root` | String | `tasks` | Project-relative path. `.` is allowed. One effective root per command. |
| `tasks.exclude` | Sequence of strings | `[]` | Portable glob exclusions (Section 7). |
| `boards` | Mapping | Built-in board options | Optional `root` only. |
| `boards.root` | String | `boards` | Relative to **effective** `tasks.root`; must be a strict subdirectory. |
| `ids` | Mapping | Built-in ID options | Optional `prefix` only. |
| `ids.prefix` | String | No prefix | CLI-generated IDs use this prefix plus a numeric suffix. |
| `statuses` | Mapping of status to category | `{}` | Additional status names mapped to one of five native categories. |
| `priorities` | Sequence of strings | `[low, medium, high, critical]` | Complete replacement list, sorted low to high. |
| `timezone` | IANA time-zone string | Local system time zone | Applies to date-only due dates (KAD-002). |

A missing mapping is the same as a `null` mapping. **Every explicit YAML `null`, including a nested field, means "not specified"** and takes that field's default. This is distinct from an empty, non-null list or mapping: `tasks.exclude: []` clears exclusions; `statuses: {}` declares no extensions. `priorities: []` is invalid because there must be at least one priority.

### Status and priority rules

The five built-in statuses are always available and retain their canonical categories: `todo`, `in_progress`, `blocked`, `done`, `canceled`. `statuses` adds names but cannot replace or redefine a built-in key. Every extension value must be exactly one of those five categories.

```yaml
statuses:
  review: in_progress
  testing: in_progress
  rejected: canceled
```

Priority names, status names and custom status names use KAD-002's ASCII lowercase slug grammar: `^[a-z][a-z0-9_-]*$`. Priority values must be unique. An explicit non-null `priorities` list **replaces**, rather than extends, the built-in list. Unknown statuses or priorities in task files are errors under the effective project schema.

### IDs and time zone

An omitted or null `ids.prefix` means automatically generated IDs have no prefix, e.g. `0001`. A configured nonempty prefix such as `KAD` yields `KAD-0001`. Require a prefix whose characters, first character and last character satisfy KAD-002's ID grammar; preserve its source case. The suffix sequence, allocation-history format and collision handling belong to KAD-004.

An omitted or null `timezone` uses the local system time zone. A configured value must identify an available IANA time zone (for example `America/Maceio`); invalid or unavailable values are configuration errors, never silently replaced with UTC. `kadai init` does not auto-write the machine's time zone.

### Strictness

- The top-level document and non-null nested objects must be mappings with string keys. Unknown keys at **any** configuration level are errors. No `extensions` or arbitrary custom keys in v1.
- Invalid YAML, invalid UTF-8, duplicate mapping keys, malformed shapes, unknown `schema_version`, and unsupported YAML constructs fail closed. No "first key wins", partial config loading or silent migration. KAD-006 owns the exact parser subset and resource limits; it may only narrow unsafe YAML representations, not silently change these semantics.
- The `schema_version` key is optional; `kadai init` writes `schema_version: 1`. A future version is not interpreted using v1 rules.
- Task frontmatter `schema_version` and project configuration `schema_version` are separate versioned contracts.

## 4. Minimal initialization and no-config use

For a new project, plain `kadai init` writes the following configuration and creates the selected tasks directory if absent:

```yaml
schema_version: 1

tasks:
  root: tasks
```

- `init` is optional. Without configuration, reads scan `<CWD>/tasks/` by default, and `kadai add` can create a collection and necessary internal state on demand without writing `.kadai.yaml`.
- On first initialization, `init` persists accepted configuration flags (for example a custom `--tasks-root` or `--id-prefix`) instead of only using them for that invocation. Other default/absent fields are omitted.
- `init` creates `tasks.root` (unless the directory already exists); it does **not** create `boards.root` in v0.1, nor empty lock/history/recovery files solely for initialization.
- If `.kadai.yaml` already exists, `init` validates it and may create an absent effective tasks directory. It never overwrites or reformats existing configuration, task files, or used-ID history. An explicitly supplied initialization option that conflicts with existing persisted config must fail rather than be silently ignored or saved elsewhere.
- If a collection directory is absent, read commands treat it as an empty collection and create nothing. Commands that need to create a task may create the required directories and state securely. A missing collection directory is **not** by itself an invalid configuration.
- Failures must not silently overwrite existing files. Atomic creation, interruption and safe filesystem behavior belong to KAD-029/KAD-030.

`kadai init --project nonexistent` fails if the selected project directory does not exist. `--project` selects a project, not a `mkdir -p` operation.

## 5. Paths and containment

- `tasks.root` in YAML must be relative to the selected project. `boards.root` in YAML must be relative to `tasks.root`. Both use forward slash as the portable written separator.
- CLI path overrides may be relative or absolute. Relative `--tasks-root` is resolved against the selected project, **not** against the invocation CWD. Relative `--boards-root` is resolved against the **effective** collection root.
- Physical containment is mandatory: effective task roots must remain within the physical project, and effective board roots must be strictly beneath the effective task root. An absolute path in config is invalid; an absolute CLI path is valid only if it satisfies containment.
- `tasks.root: .` is valid and means the project directory itself. `boards.root: .` is invalid because it would exclude the entire task collection from scanning.
- Reject traversal outside the permitted root, including `..` escapes, symlinks to external targets and unsafe filesystem races. Path normalization must handle directory roots that do not yet exist by checking existing ancestors and securely rechecking on creation; do not require `realpath` of a nonexisting final directory.
- Explicit `--project` and `--tasks-root` selections may pass through internal symlinks. Resolve to physical paths; warn to stderr with original and target. Two spellings of the same physical collection must resolve to one lock/history identity. This does not permit following symlinks encountered during recursive task discovery.
- Exact path spelling, case sensitivity of real filesystem paths, and OS metadata safety belong to KAD-026. Do not assume every filesystem is case-insensitive or case-sensitive merely from the OS name.

## 6. Task and board discovery

Scan `*.md` candidates recursively under the **effective** task root, except for exclusions below. KAD-002 classifies valid tasks, invalid candidates, unsupported-schema candidates and ordinary Markdown. Folder nesting never automatically creates task parent relationships.

Always exclude, without a user-configurable opt-out:

1. The collection's internal `.kadai/` directory and internal `.kadai/` subtrees.
2. The complete `boards.root` subtree, including nested folders. Board support is deferred to v0.2, but its configured root is recognized and excluded in v0.1.
3. `.git/` directories. When a nested directory contains its own `.git` directory or `.git` marker file, treat that nested repository as a traversal boundary; the current project root itself is not excluded merely for containing `.git`.
4. Nested Kadai project directories containing their own `.kadai.yaml`. The selected project's **own** `.kadai.yaml` does not exclude its root.
5. File and directory symlinks found by the recursive scanner. Do not follow them, even if their target is internal; produce a useful diagnostic when appropriate.

Other hidden directories are eligible for scanning. **Do not read or apply `.gitignore`**, including when the collection sits inside a Git repository. A `.md` file ignored by Git can still be a task.

User-configured `tasks.exclude` exclusions apply on top of mandatory exclusions; they never disable mandatory boundaries.

## 7. Portable exclusion patterns

`tasks.exclude` is an ordered sequence of patterns relative to the **effective** task root. Normalize encountered relative path separators to `/` for matching on macOS, Linux and Windows.

- `*` matches zero or more non-`/` characters in a path segment.
- `?` matches exactly one non-`/` Unicode scalar value.
- `**` as a **whole segment** matches zero or more complete directory segments, including at the root.
- A trailing `/` specifies a directory and its full subtree.
- Matching is **case-sensitive on every OS**, with no implicit Unicode normalization.
- Patterns are rooted at `tasks.root`. `build/` excludes only `<tasks.root>/build/`. `**/cache/` excludes `cache/` at any depth.
- No negation, bracket classes, brace expansion, Gitignore precedence or environment-variable expansion. A pattern must not be empty or absolute, contain a traversal segment `..`, or use Windows `\` as a separator; invalid patterns fail configuration validation.

Example:

```yaml
tasks:
  root: .
  exclude:
    - vendor/
    - generated/
    - "**/archive/**"
```

Neither `.gitignore` nor default Git-ignored status contributes to these matches. If `--exclude` is present, its supplied list **replaces** the configured list; it does not append. The required internal exclusions still apply. Exact repeatable-flag syntax and the mechanism for an explicitly empty override belong to KAD-047.

## 8. Effective configuration and CLI precedence

Precedence for keys that permit overrides is:

```text
explicit CLI flag > .kadai.yaml > built-in defaults
```

- `--project` selects the project itself. It is not a field of `.kadai.yaml`.
- CLI overrides may select `tasks.root`, `boards.root`, `tasks.exclude`, `timezone` and `ids.prefix`. Exact flag grammar belongs to KAD-047.
- `statuses` and `priorities` cannot be overridden by CLI flags in v0.1; they define the stable schema against which task documents are validated.
- An overridden `tasks.root` selects an **independent collection**, with its own local IDs, history, lock and recovery directory. Its effective board root is resolved anew beneath that collection. The other project configuration (including statuses/priorities) is inherited unless specifically overridden.
- Parse the full configuration file before applying overrides. Malformed YAML, duplicate keys, unknown keys, unknown schema version and structurally malformed object nesting remain errors even if a CLI override supplies a value elsewhere.
- For a successfully parsed, structurally valid configuration, apply field overrides **before** value/type validation of the overridden leaf. An invalid value in the replaced leaf does not block the command. Validate every non-overridden field and the effective combined configuration. There is no "partially applied config with warnings" fallback.
- On a failed effective-configuration validation, normal commands stop; `kadai validate` reports config diagnostics only, without scanning tasks. `kadai validate` with overrides validates that effective view.
- Warn about explicitly traversed symlinks on stderr; JSON stdout must contain only the machine-readable command result. Stable diagnostic structure and exit codes belong to KAD-050/KAD-051.

For example, if `tasks.root` in YAML points outside the project, `kadai list --tasks-root tasks` may succeed, provided all other structure and effective fields are valid. It does not read or modify the invalid original root.

## 9. Internal state, version control and overlapping collections

All internal per-collection state belongs beneath:

```text
<effective-tasks-root>/
└── .kadai/
    ├── <used-ID history, format defined by KAD-004>
    ├── <native lock state, defined by KAD-030>
    └── <private immutable recovery state, defined by KAD-029/KAD-030>
```

These are **logical locations**, not frozen filenames. Caches, if added, must be rebuildable. No state file is created by read-only discovery. Generating an ID requires a durable allocation record even in an uninitialized project, per KAD-002/KAD-004.

Kadai does not require, control, configure or modify Git tracking. A collection may be local, untracked, committed, per-worktree or ephemeral. Non-reuse of a CLI-issued ID is guaranteed only while the durable record containing that allocation is retained; deleting an entire collection (including its history), or independently allocating in separate clones/branches, removes that shared-history guarantee. Git merges may create collisions requiring KAD-004's explicit repair process.

**Overlapping collections are permitted.** For example, `tasks/` and `tasks/backend/` may be selected independently. They can contain some of the same Markdown files while keeping **different** ID histories and collection locks. Thus:

- A parent collection's recursive scan may also discover files in a nested collection. Do not claim that a nested override automatically isolates those files from its parent scan.
- IDs, parent references and dependencies are resolved against the **effective collection's** index. There is no cross-collection identity or shared sequence, even if paths overlap.
- Two different collection locks alone cannot serialize modifications of a shared file. Kadai writers **must** also coordinate writes targeting the same physical file across overlapping collections, including replacement/rename races. KAD-030 owns the concrete cross-collection locking strategy, safe lock ordering, identity checks and tests; KAD-026 owns path identity and link safety.
- The guarantee applies to cooperating Kadai writers. External editors ignoring locks retain KAD-002's documented last-check/atomic-rename race; pre-write recovery copies remain mandatory.

These overlaps are intentional and not configuration errors. Callers who need physically separate collections should choose nonoverlapping roots or explicit exclusions.

## 10. Manual relocation of a collection

A change to configured `tasks.root` is **not** an automatic migration. To relocate an existing collection, the user must move the **whole** collection, including `.kadai/` and its history, then update `.kadai.yaml`. All Kadai writers should be stopped during manual relocation. Selecting another `--tasks-root` does not move any files.

Kadai must fail closed on **detectable** missing/inconsistent internal state when continuing could reuse a recorded ID or corrupt files. However, a missing history file alone cannot prove an incomplete migration: a legitimately fresh or entirely ephemeral collection may have no history. KAD-004 and KAD-030 must specify evidence and recovery rules; do not invent a universal historical reconstruction from the current Markdown files.

## 11. Fixtures and diagnostics required of implementation

KAD-007/KAD-023–KAD-026/KAD-030 must cover at least:

| Scenario | Required behavior |
| --- | --- |
| CWD inside a Git repository with no `--project` | CWD itself is the project, never the Git root. |
| `--project` selects an existing relative or absolute directory | Exact selection, resolved physically. |
| `--project` selects a nonexistent directory | Error, including for `init`. |
| Project has no `.kadai.yaml` or `tasks/` | Read is empty and side-effect-free; `add` may create the collection without writing config. |
| First `init` with and without flags | Minimal persisted v1 config; selected tasks directory created, boards and operational files not pre-created. |
| Repeated `init` with valid config | Non-destructive; creates missing tasks directory only; conflicting new init flags fail. |
| Unknown or duplicate config key, malformed YAML, invalid UTF-8, unknown schema | Error; no silent fallback. |
| Any optional `null` value | Field-specific default; nested null mappings behave as absent. |
| Invalid config leaf replaced by CLI flag | Skip invalid replaced leaf; reject any remaining invalid effective field or malformed structure. |
| Root equals `.`; board root equals `.` | Task root valid, board root invalid. |
| Override to nested/overlapping collection | Allowed, separate histories/locks; shared files may appear in both scans. |
| Paths escaping root by `..`, absolute config, or external symlink | Error without unsafe read/write. |
| Explicit internal symlink in project, collection, or config path | Allowed with original/target warning to stderr; physical identity used. |
| Symlink encountered inside scanned directories | Not followed. |
| Nested `.kadai.yaml` or nested `.git` marker | Nested subtree excluded; no ancestor-based root selection. |
| Hidden dirs, Git-ignored Markdown | Eligible unless otherwise excluded. |
| `build/` and `**/cache/` patterns | Root-only vs any-depth matching, always case-sensitive. |
| `--exclude` over configured exclusions | CLI list replaces custom list; mandatory exclusions remain. |
| Two collections edit the same physical file | Cooperating writes coordinated despite different collection locks; race/recovery behavior tested under KAD-030. |
| Move collection with `.kadai/` vs incomplete migration | Whole-directory manual relocation supported; detectable missing/corrupt state is not silently reset. |
| Git-tracking choice | No command creates/edits `.gitignore` or requires a tracked file. |

Diagnostic categories and exact JSON/exit-code shapes are delegated to KAD-016/KAD-050/KAD-051, and parser-specific byte/depth/node limits to KAD-006. All read and validation paths must remain non-mutating.

## 12. Completion and handoffs

- [x] Exact CWD/`--project` discovery and local-only config lookup frozen; Git-root discovery intentionally removed.
- [x] `.kadai.yaml` v1 keys, types, defaults, null behavior and strict validation specified.
- [x] `tasks.root`, `boards.root`, nested scanning boundaries and portable excludes specified.
- [x] `init`, CLI precedence/overrides, independent collections, and manual migration specified.
- [x] Local state placement, optional Git tracking and cross-collection write coordination documented.
- [x] Acceptance scenarios and error boundaries documented; no implementation or executable tests claimed.

**Follow-ups:** KAD-004 owns ID record format and collision repair; KAD-006 YAML implementation limits; KAD-007 executable fixtures; KAD-023–KAD-026 discovery and filesystem implementation; KAD-029/KAD-030 atomic writes, lock behavior and recovery; KAD-047 CLI grammar; KAD-050/KAD-051 JSON and error contracts. The board document format and commands remain deferred to v0.2.
