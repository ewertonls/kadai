# KAD-002: task frontmatter v1 contract

> **Status:** Accepted specification, not implemented.
> **Milestone:** v0.1. **Owner task:** KAD-002. **Recorded:** 2026-11-06. **Architecture review:** 2026-11-06.
> **Depends on:** [KAD-001 product scope](KAD-001-v0.1-scope.md).
> **Scope:** On-disk task recognition, reserved keys, validation, defaults, YAML types, and the decisions that constrain later implementations.

## 1. Principles and recognition

- A task is a project-local `.md` file whose initial YAML frontmatter contains the exact discriminator `kadai: task`. The body is unrestricted Markdown, including an empty body. The file path never determines task identity or logical hierarchy.
- The frontmatter must start on the first line, except for an optional UTF-8 BOM. Opening and closing delimiter lines are `---`. Only LF and CRLF are supported. A missing closing delimiter is an error.
- Input is strict UTF-8. Invalid byte sequences fail with a diagnostic; they are not replaced or silently repaired. Preserve BOM, line endings, and all unrelated bytes.
- The frontmatter document's root must be a YAML mapping with string keys. A valid YAML file without `kadai: task`, or with another `kadai` value, is not a task. It must not be imported implicitly.
- Discovery classifies Markdown as **non-task**, **valid task**, **invalid task candidate** or **unsupported-schema task**. A parsed `kadai: task` with field errors is an invalid candidate; malformed frontmatter is a candidate only when a conservative task marker is found (KAD-006 defines that rule). Ordinary Markdown is ignored.
- Candidates with a valid, project-unique ID may be available through **diagnostic-only partial reads**, never normal task listing/readiness. Invalid YAML syntax, ambiguous `kadai`/`id` keys and invalid IDs preclude usable indexing. After scanning the whole project, **all** case-insensitive ID collisions are quarantined: ID-based reads/writes fail until explicit repair, and no file wins by scan order. Unknown future schemas are recognized but read-only absent proven compatibility.
- Recognition, parsing, semantic validation, graph integrity, and mutation eligibility are separate steps. A readable or partially indexed file is **not** necessarily valid or safe to write.

## 2. Reserved keys and types

Keys are case-sensitive and live at the top level unless stated otherwise.

| Key | Required | Type | Contract |
| --- | --- | --- | --- |
| `kadai` | Yes | String | Exactly `task` |
| `id` | Yes | String | Project-unique ASCII ID, case-insensitive lookup |
| `title` | Yes | String | Nonblank single-line Unicode text |
| `status` | Yes | String | Configured state slug |
| `schema_version` | No | Positive integer or null | Absent/null means `1` |
| `priority` | No | Configured slug or null | Absent/null means no priority |
| `tags` | No | List of strings or null | Absent/null means no tags; `[]` is valid |
| `depends_on` | No | List of IDs or null | Absent/null means no prerequisites; `[]` is valid |
| `parent` | No | ID string or null | Absent/null means no logical parent; graph rules in KAD-005 |
| `due` | No | Date/datetime string or null | Absent/null means no deadline |
| `custom` | No | Mapping or null | Absent/null means no custom metadata |

The four primary required fields are `kadai`, `id`, `title`, and `status`. No required field may be YAML null.

**`parent` is an optional reserved v1 field**, with type project-local ID or null. It is not custom metadata. KAD-005 owns target validation, self-links, cycles, moves and deletion. Path nesting does not imply parenthood.

All other unknown top-level keys are schema errors, not warnings. Preserve their source text and report them; suggest a likely spelling when practical. Custom properties belong under `custom` only.

Example of a task valid under the KAD-002 contract:

~~~yaml
---
kadai: task
id: KAD-002
title: "Especificar o frontmatter"
status: in_progress
priority: high
tags: [architecture, core]
depends_on: [KAD-001]
due: "2026-11-15"
custom:
  sprint: 1
  reviewer: Ana
  integrations:
    jira: PROJ-123
---

~~~

Any Markdown text may follow the closing delimiter. The empty Markdown body in this example is valid.

## 3. Field-specific validation

### Identity

- Allowed ID characters: ASCII letters (`A-Z`, `a-z`), digits (`0-9`), hyphen, underscore, dot.
- ID must be nonempty and start and end with an ASCII alphanumeric character. Internal consecutive separators are allowed. No arbitrary maximum length at the schema level.
- Examples valid: `KAD-002`, `0001`, `bug_42`, `setup.cli`. Invalid: `-task`, `task-`, `.config`, `task_`.
- IDs are unique **within a project**, regardless of file name or directory. Compare by ASCII case folding only. `KAD-002` and `kad-002` collide; retain the originally written case.
- `depends_on` uses the same ID grammar and comparison. The rules for ID allocation and filesystem safety belong to KAD-004.

### Title

- Unicode string, one logical line, with at least one non-whitespace character.
- No embedded line breaks. No artificial maximum length. Preserve original whitespace and punctuation rather than normalizing the stored value.
- The CLI may truncate a long title in presentation only.

### Status and priority

- Allowed value names, including custom values, are ASCII lowercase slugs: first character `a-z`, remaining characters `a-z`, `0-9`, `_`, or `-`. Comparison is case-sensitive; no silent correction.
- Built-in statuses: `todo`, `in_progress`, `blocked`, `done`, `canceled`.
- Projects can declare additional statuses; each maps to **exactly one** canonical category from those five. A standard status maps to its own category.
- Built-in priorities, from lowest to highest: `low`, `medium`, `high`, `critical`. Projects may replace the list and its order. Missing/null `priority` is not a hidden `medium`.
- Unconfigured status/priority values are errors. `kadai add` without an explicit status writes `status: todo`. This is a **creation default**, not a missing-field fallback for existing files. KAD-003 defines configuration syntax.

### Tags

- `tags` is an ordered YAML sequence of nonempty slugs containing only `a-z`, `0-9`, `-`, `_`, `.`, and `/`.
- No spaces or uppercase letters. Examples: `backend`, `v0.1`, `cli/parser`.
- Exact duplicate tags are schema errors. Preserve order, case and source formatting. Do not auto-correct.

### Dependencies

- `depends_on` is an ordered sequence of IDs. Duplicates, including differently cased spellings, are schema errors.
- Missing targets, ambiguous ID targets, self-links, and dependency cycles generate integrity diagnostics. Manual malformed references stay visible for repair; the CLI must not create new invalid edges.
- The direction of a prerequisite edge and parent/dependency independence belong to KAD-005. See Section 5 for derived readiness rules already decided in KAD-002.

### Deadline

`due` accepts a valid date `YYYY-MM-DD` or the **v1 subset of RFC 3339** `YYYY-MM-DDTHH:mm:ss(Z|+HH:mm|-HH:mm)`. Seconds and offset are mandatory; `T`/`Z` must be uppercase. Hours 00–23, seconds 00–59. Fractional seconds, leap-second `:60` and lowercase `t`/`z` are unsupported in v1. Examples: `"2026-11-15"`, `"2026-11-15T18:30:00-03:00"`, `"2026-11-15T21:30:00Z"`.

Invalid dates, times or offsets are errors. Dates are YAML strings; quoting is recommended. Date-only deadlines become overdue when the current date is later than `due` in the configured project IANA time zone, falling back to local system time zone. Offset datetimes denote absolute instants.

### Custom metadata

- `custom`, when not null, must be a YAML mapping. Its values may be strings, integers, floats, booleans, null, sequences, and nested mappings.
- All mapping keys, at every nesting level, must be nonempty Unicode strings without control characters. Spaces, punctuation, and accents are allowed.
- Keys are case-sensitive and compared by their exact Unicode codepoint sequences. No NFC/NFD normalization; canonically equivalent but differently encoded keys remain distinct.
- Duplicate keys are errors at every nesting level. Anchors, aliases, and explicit YAML tags are outside the supported contract.
- Implicit scalar types in `custom` follow YAML 1.2 **Core Schema**, resolved explicitly rather than relying on a parser's implicit YAML 1.1 conversions. For example, `true` is a boolean, `no` is a string, `3` is an integer, `1.2` is a float, and `2026-11-15` is a string.
- The CLI preserves custom YAML types and original numeric spelling in unrelated edits. YAML 1.2 Core includes `.nan`/`.inf` and integers beyond JSON's interoperable exact numeric range. KAD-050 must specify a reversible JSON encoding or return an explicit unsupported-output error rather than silently coerce values. Generic custom mutations belong to KAD-066.

## 4. YAML scalar interpretation and versioning

- Known fields are typed by the Kadai schema. For a required string field, a plain scalar like `id: 0001` is interpreted as the text `0001`, preserving leading zeros; `title: 123` is text `123`. This rule does **not** turn YAML null into a valid required value.
- An explicit null in an optional field is equivalent to absence. Preserve `null` versus omission versus `[]` in the source while making their documented domain meanings equivalent where appropriate. Within `custom`, null remains an actual custom value.
- `schema_version` must be a positive integer if present and not null. Missing or null means schema v1.
- A future schema version unknown to the running CLI may be surfaced as a partially readable unsupported document. Do not apply v1 unknown-field rules to it or mutate it without proven compatibility. No silent version migration.

### Operational resource limits

The abstract schema has no arbitrary ID/title length limit, but parsers MUST bound file and header bytes, YAML node count, collection size and nesting depth. Reaching a limit yields a non-destructive diagnostic and forbids mutation. KAD-006 sets numeric defaults/override rules and KAD-007 supplies fixtures.

## 5. Dependency readiness and status invariants

Persist the author's declared `status` unchanged. Prerequisites produce a **derived** in-memory dependency result, never another persisted status:

| Derived result | Meaning |
| --- | --- |
| `ready` | No prerequisites, or all direct prerequisites have canonical category `done` |
| `blocked` | At least one valid direct prerequisite is not `done` and no unresolved integrity problem takes precedence |
| `unresolved` | Missing/ambiguous references, cycles or direct prerequisites with unresolvable IDs, status, status categories or schemas; takes precedence over `blocked` |

- Only canonical `done` satisfies dependencies, including custom statuses mapped to `done`; `canceled` does not. A direct prerequisite with missing/invalid status, unknown canonical category or unsupported schema is `unresolved`, never implicitly `ready` or `blocked`.
- Blocking uses direct prerequisites. Do **not** recursively block on incomplete prerequisites of an already completed direct dependency.
- Nonetheless, validation detects and reports transitive inconsistencies, such as a task marked `done` while its own prerequisites are incomplete, and graph cycles.
- Manual `status: blocked` describes an author's state, separate from derived `blocked`.
- CLI transitions into a `done` category must fail by default when dependency result is `blocked` or `unresolved`. An explicit override such as `--force` may permit the transition without removing any links. The CLI must still refuse unsafe structural file writes. Manual edits are never silently reverted.
- Exact graph diagnostics, direction, invalidation, and command syntax belong to KAD-005/KAD-047/KAD-051.

## 6. Validation and conservative mutation

### Read contract

- YAML syntax errors or unsafe structural ambiguity produce diagnostics, not best-effort YAML repair.
- Duplicate YAML mapping keys are errors everywhere. No first/last occurrence wins. An ambiguous field is unavailable for targeted mutation. Duplicate `kadai` or `id` prevents reliable task identification.
- Valid tasks enter ordinary indexes. Invalid candidates with an identifiable unique ID may appear in diagnostic-only partial reads, not regular listings or readiness. Ambiguous duplicate IDs block **all** ID-based queries and writes until explicit repair; malformed candidates remain visible to validation when recognizable.
- Each diagnostic should carry a stable machine category, file path, field (if known), and line/column or source span when available. Exact error codes and JSON shape are assigned to KAD-016, KAD-050, and KAD-051.
- Invalid/unsupported candidates must never be rewritten during discovery or validation.

### Write contract

- Change **only** the requested metadata span, retaining unrelated content, formatting, Markdown body and bytes. Preserve supported ownership, mode, ACLs and xattrs or fail closed; refuse unsafe symlink or multi-hardlink mutations (KAD-026/KAD-029). Write timestamps naturally change.
- Use a YAML parser for validation and a separate source-aware patching mechanism for local edits; never fall back silently to whole-header reserialization.
- If a field's representation cannot be updated safely, fail without modifying the file. Edits fixing individual invalid fields are allowed only when they do not introduce additional errors.
- All Kadai writes share a native project lock, stage on the same filesystem, check source identity/hash immediately before replacement, and require an immutable private pre-write recovery snapshot. Fail closed if required recovery cannot be recorded. KAD-029/KAD-030 define retention, rollback, fsync and OS-specific behavior.
- **Residual race:** external editors ignoring the lock can save between final verification and replacement. A hash check plus rename is not atomic as a pair; the snapshot may miss that last editor save. Never promise universal prevention of lost updates. Document the limitation and recovery procedure. Read-only commands create no recovery state.

## 7. ID generation and concurrent creation (cross-task constraints)

The following decisions are accepted but belong primarily to KAD-004 and KAD-030:

- Manual IDs remain flexible. Automatic IDs are sequential, with optional project prefix, and at least four digits: `JOOJ-0001` or `0001`. The numeric field grows past `9999` as needed.
- For each prefix, allocate above the highest numeric suffix in live files **and durable used-ID history**. No numeric counter is needed, but a small project-local used-ID/tombstone record (IDs only, not authoritative task state) is required even without `.kadai.yaml`. Record each allocation durably before task creation; gaps are allowed. CLI-issued IDs **must never be reused** after deletion.
- Prefixes have independent sequences. Check all live/manual IDs case-insensitively. Independent Git branches, worktrees and clones can allocate the same sequential ID: locks do not span them. Following a merge, quarantine all colliding files and require explicit reference-aware re-ID/repair; never silently select a winner.
- All Kadai writes share a project-scoped native exclusive OS lock (e.g. `flock` on macOS/Linux, `LockFileEx` on Windows). Hold it across scan, durable ID reservation and task creation. External editors and independent clones still need conflict/duplicate validation.
- Lock, recovery, used-ID record locations (including Git tracking/exclusion), timeout and crash recovery belong to KAD-003/KAD-004/KAD-029/KAD-030. CLI deletion retains ID history. A manually created and deleted ID that Kadai never observed cannot be inferred; non-reuse is guaranteed only for recorded IDs.

## 8. Examples for fixtures and diagnostics

KAD-007 should record golden files for these cases; examples here are **contracts**, not proof of implementation.

| Fixture | Expected outcome |
| --- | --- |
| Minimal four-field task with empty Markdown body | Valid; CLI title-only creation writes `status: todo` |
| Optional fields omitted or explicitly null | Valid; domain defaults applied |
| ID `0001` without quotes | Valid text ID with leading zeros |
| UTF-8 BOM; LF and CRLF inputs | Valid; unrelated bytes retained |
| Unicode one-line title and nested `custom` | Valid |
| `custom: {enabled: true, archived: no}` | Boolean `true`, string `no` |
| Unicode custom keys that differ only by normalization form | Distinct keys, each preserved |
| Duplicate `status` or duplicate nested custom key | Error; no first/last-wins behavior |
| Missing `title` or `status` | Schema error; diagnostic-only partial read if unique ID is available |
| `status: in-progress` or `priority: urgent` without config | Error (unknown value) |
| Unknown top-level `sprint: 2` | Error; preserve source |
| `tags: [backend, backend]` | Error |
| `depends_on: [KAD-001, kad-001]` | Error |
| Missing dependency, self-link, cycle, duplicate project IDs | Integrity diagnostic, unresolved where applicable |
| `parent: KAD-001` or `parent: null` | Valid optional scalar; graph checks in KAD-005 |
| Duplicate IDs after Git merge | Every colliding ID quarantined until explicit repair |
| Direct prerequisite with invalid status or unsupported schema | `unresolved` |
| Deleted highest generated ID | Never reallocated if present in used-ID history |
| Direct dependency done but its dependency todo | Ready for direct caller; transitive inconsistency diagnostic |
| Transition to done with blocked/unresolved prerequisites | Reject absent explicit override |
| YAML anchors, aliases, explicit tags | Unsupported; no unsafe mutation |
| Huge integer, `.nan` or `.inf` in `custom` | YAML type preserved; JSON never silently coerced |
| Parser resource limit exceeded | Diagnostic, no writes |
| Symlink/multiple hardlinks or unsupported security metadata | Reject mutation |
| External save before final conflict check | Reject detected conflict |
| External save within final-check/replace window | Residual race; snapshot may miss editor save |
| Fractional seconds or leap-second `:60` in `due` | Invalid in v1 |
| Invalid UTF-8, missing delimiter, malformed YAML | Diagnostic; no destructive repair |
| Unknown future `schema_version` | Do not validate as v1 or mutate without compatibility |

Byte-for-byte mutation tests, complex YAML edge cases, project-scoped discovery, and concurrency tests are separately owned by KAD-006, KAD-007, KAD-022, KAD-025, and KAD-030.

## 9. Task completion and handoffs

- [x] Required discriminator and fields frozen.
- [x] Optional/reserved metadata, null semantics, and version handling defined.
- [x] Status and priority defaults/config extension defined.
- [x] ID and tag syntax, case policy, custom YAML typing, and Unicode key policy defined.
- [x] Reference integrity, dependency readiness, and override policy recorded.
- [x] UTF-8, frontmatter boundaries, and conservative-write invariants recorded.
- [x] Valid/invalid fixture expectations identified for KAD-007.
- [ ] **KAD-003:** Config syntax, status/priority extensions, time zone, task root, lock file location.
- [ ] **KAD-004:** Durable used-ID record, non-reuse, Git-merge collision repair and filename rules.
- [ ] **KAD-005:** Parent graph semantics (scalar type fixed here), dependencies and deletion.
- [ ] **KAD-006:** YAML grammar, parser resource limits and mutation failure rules.
- [ ] **KAD-007:** Store actual fixture corpus and executable expectations.

- [ ] **KAD-026/KAD-029/KAD-030:** File security metadata, link safety, writer coordination and recovery.
- [ ] **KAD-050:** Lossless JSON handling for YAML-only numeric scalars.

**Completion criterion:** KAD-002 is finished as a **design/specification** task. No parser, CLI behavior, automated fixtures, or tests are claimed implemented.
