# KAD-002: task frontmatter v1 contract

> **Status:** Accepted specification, not implemented.
> **Milestone:** v0.1. **Owner task:** KAD-002. **Recorded:** 2026-11-06.
> **Depends on:** [KAD-001 product scope](KAD-001-v0.1-scope.md).
> **Scope:** On-disk task recognition, reserved keys, validation, defaults, YAML types, and the decisions that constrain later implementations.

## 1. Principles and recognition

- A task is a project-local `.md` file whose initial YAML frontmatter contains the exact discriminator `kadai: task`. The body is unrestricted Markdown, including an empty body. The file path never determines task identity or logical hierarchy.
- The frontmatter must start on the first line, except for an optional UTF-8 BOM. Opening and closing delimiter lines are `---`. Only LF and CRLF are supported. A missing closing delimiter is an error.
- Input is strict UTF-8. Invalid byte sequences fail with a diagnostic; they are not replaced or silently repaired. Preserve BOM, line endings, and all unrelated bytes.
- The frontmatter document's root must be a YAML mapping with string keys. A valid YAML file without `kadai: task`, or with another `kadai` value, is not a task. It must not be imported implicitly.
- A recognized task with a valid, unique ID may remain partially indexed when another known field has a validation error. YAML syntax errors, ambiguous/duplicate `kadai` or `id` keys, and invalid IDs prevent usable task indexing. They still produce diagnostics for identified task candidates.
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
| `due` | No | Date/datetime string or null | Absent/null means no deadline |
| `custom` | No | Mapping or null | Absent/null means no custom metadata |

The four primary required fields are `kadai`, `id`, `title`, and `status`. No required field may be YAML null.

**`parent` is reserved for KAD-005**, which owns the logical hierarchy contract. It is not arbitrary custom metadata. Its full type, validation, and inclusion in the final v1 schema must be resolved in KAD-005 before v0.1 is released. Until then, implementations must not silently accept it as an unknown custom field or invent parent semantics.

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
- Unconfigured status/priority values are errors. The shape of `.kadai.yaml` belongs to KAD-003. No automatic status transitions are implied by this field.

### Tags

- `tags` is an ordered YAML sequence of nonempty slugs containing only `a-z`, `0-9`, `-`, `_`, `.`, and `/`.
- No spaces or uppercase letters. Examples: `backend`, `v0.1`, `cli/parser`.
- Exact duplicate tags are schema errors. Preserve order, case and source formatting. Do not auto-correct.

### Dependencies

- `depends_on` is an ordered sequence of IDs. Duplicates, including differently cased spellings, are schema errors.
- Missing targets, ambiguous ID targets, self-links, and dependency cycles generate integrity diagnostics. Manual malformed references stay visible for repair; the CLI must not create new invalid edges.
- The direction of a prerequisite edge and parent/dependency independence belong to KAD-005. See ``5`` for derived readiness rules already decided in KAD-002.

### Deadline

`due` accepts either:

1. An actual calendar date `YYYY-MM-DD`, e.g. `"2026-11-15"`.
2. An RFC 3339 timestamp with seconds and explicit zone offset, e.g. `"2026-11-15T18:30:00-03:00"` or UTC `"2026-11-15T21:30:00Z"`.

Invalid dates and malformed offsets are errors. YAML values are logically strings; quoting is recommended to prevent host library type inference. Date-only deadlines become overdue when the current calendar date is **later** than the due date in the project's configured IANA time zone. Without configured time zone, use the machine's local time zone. A timestamp is an absolute instant and does not use that fallback.

### Custom metadata

- `custom`, when not null, must be a YAML mapping. Its values may be strings, integers, floats, booleans, null, sequences, and nested mappings.
- All mapping keys, at every nesting level, must be nonempty Unicode strings without control characters. Spaces, punctuation, and accents are allowed.
- Keys are case-sensitive and compared by their exact Unicode codepoint sequences. No NFC/NFD normalization; canonically equivalent but differently encoded keys remain distinct.
- Duplicate keys are errors at every nesting level. Anchors, aliases, and explicit YAML tags are outside the supported contract.
- Implicit scalar types in `custom` follow YAML 1.2 **Core Schema**, resolved explicitly rather than relying on a parser's implicit YAML 1.1 conversions. For example, `true` is a boolean, `no` is a string, `3` is an integer, `1.2` is a float, and `2026-11-15` is a string.
- The CLI preserves custom values and their types during unrelated edits. Generic custom-field mutations are a later roadmap item (KAD-066).

## 4. YAML scalar interpretation and versioning

- Known fields are typed by the Kadai schema. For a required string field, a plain scalar like `id: 0001` is interpreted as the text `0001`, preserving leading zeros; `title: 123` is text `123`. This rule does **not** turn YAML null into a valid required value.
- An explicit null in an optional field is equivalent to absence. Preserve `null` versus omission versus `[]` in the source while making their documented domain meanings equivalent where appropriate. Within `custom`, null remains an actual custom value.
- `schema_version` must be a positive integer if present and not null. Missing or null means schema v1.
- A future schema version unknown to the running CLI may be surfaced as a partially readable unsupported document. Do not apply v1 unknown-field rules to it or mutate it without proven compatibility. No silent version migration.

## 5. Dependency readiness and status invariants

Persist the author's declared `status` unchanged. Prerequisites produce a **derived** in-memory dependency result, never another persisted status:

| Derived result | Meaning |
| --- | --- |
| `ready` | No prerequisites, or all direct prerequisites have canonical category `done` |
| `blocked` | At least one valid direct prerequisite is not `done` and no unresolved integrity problem takes precedence |
| `unresolved` | Missing/ambiguous references or cycles prevent reliable resolution; takes precedence over `blocked` |

- Only canonical `done` satisfies a dependency, including custom statuses mapped to `done`. `canceled` does not satisfy it.
- Blocking uses direct prerequisites. Do **not** recursively block on incomplete prerequisites of an already completed direct dependency.
- Nonetheless, validation detects and reports transitive inconsistencies, such as a task marked `done` while its own prerequisites are incomplete, and graph cycles.
- Manual `status: blocked` describes an author's state, separate from derived `blocked`.
- CLI transitions into a `done` category must fail by default when dependency result is `blocked` or `unresolved`. An explicit override such as `--force` may permit the transition without removing any links. The CLI must still refuse unsafe structural file writes. Manual edits are never silently reverted.
- Exact graph diagnostics, direction, invalidation, and command syntax belong to KAD-005/KAD-047/KAD-051.

## 6. Validation and conservative mutation

### Read contract

- YAML syntax errors or unsafe structural ambiguity produce diagnostics, not best-effort YAML repair.
- Duplicate YAML mapping keys are errors everywhere. No first/last occurrence wins. An ambiguous field is unavailable for targeted mutation. Duplicate `kadai` or `id` prevents reliable task identification.
- If `kadai: task` and a valid unique `id` are identifiable, unrelated field errors do not prevent partial indexing/reading.
- Each diagnostic should carry a stable machine category, file path, field (if known), and line/column or source span when available. Exact error codes and JSON shape are assigned to KAD-016, KAD-050, and KAD-051.
- Invalid/unsupported candidates must never be rewritten during discovery or validation.

### Write contract

- Change **only** the requested metadata span. Preserve comments, key order, spacing, quote style where safe, BOM, line endings, body, and all unrelated bytes.
- Use a YAML parser for validation and a separate source-aware patching mechanism for local edits; never fall back silently to whole-header reserialization.
- If a field's representation cannot be updated safely, fail without modifying the file. Edits fixing individual invalid fields are allowed only when they do not introduce additional errors.
- Use atomic replacement and concurrent-edit detection. Those concrete OS/filesystem mechanisms are implemented by KAD-006, KAD-029, and KAD-030, not by this specification.

## 7. ID generation and concurrent creation (cross-task constraints)

The following decisions are accepted but belong primarily to KAD-004 and KAD-030:

- Manual IDs remain flexible. Automatic IDs are sequential, with optional project prefix, and at least four digits: `JOOJ-0001` or `0001`. The numeric field grows past `9999` as needed.
- With the same configured prefix, choose one greater than the largest extant numeric suffix (no persisted counter). Deleted maximum IDs may be reused in future.
- Prefixes have independent sequences. Check IDs across the whole project case-insensitively and never overwrite an existing file.
- Automatic creation uses a project-scoped exclusive **native OS lock**: a kernel-backed lock (e.g. `flock` or equivalent on macOS/Linux, `LockFileEx` on Windows). Hold it across ID scan, allocation, and file creation. External editor changes still require collision/conflict checks.
- Lock file location, timeouts, stale state semantics, ID filename conventions, and precise error/retry policy are delegated to KAD-003, KAD-004, and KAD-030.

## 8. Examples for fixtures and diagnostics

KAD-007 should record golden files for these cases; examples here are **contracts**, not proof of implementation.

| Fixture | Expected outcome |
| --- | --- |
| Minimal four-field task with empty Markdown body | Valid |
| Optional fields omitted or explicitly null | Valid; domain defaults applied |
| ID `0001` without quotes | Valid text ID with leading zeros |
| UTF-8 BOM; LF and CRLF inputs | Valid; unrelated bytes retained |
| Unicode one-line title and nested `custom` | Valid |
| `custom: {enabled: true, archived: no}` | Boolean `true`, string `no` |
| Unicode custom keys that differ only by normalization form | Distinct keys, each preserved |
| Duplicate `status` or duplicate nested custom key | Error; no first/last-wins behavior |
| Missing `title` or `status` | Error; partial read allowed when ID is identifiable |
| `status: in-progress` or `priority: urgent` without config | Error (unknown value) |
| Unknown top-level `sprint: 2` | Error; preserve source |
| `tags: [backend, backend]` | Error |
| `depends_on: [KAD-001, kad-001]` | Error |
| Missing dependency, self-link, cycle, duplicate project IDs | Integrity diagnostic, unresolved where applicable |
| Direct dependency done but its dependency todo | Ready for direct caller; transitive inconsistency diagnostic |
| Transition to done with blocked/unresolved prerequisites | Reject absent explicit override |
| YAML anchors, aliases, explicit tags | Unsupported; no unsafe mutation |
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
- [ ] **KAD-004:** Final ID allocator, prefix rules, collision handling, path/filename rules.
- [ ] **KAD-005:** Final `parent` contract, relationship graph, and deletion policy.
- [ ] **KAD-006:** Supported YAML surface syntax and safe patching failure modes.
- [ ] **KAD-007:** Store actual fixture corpus and executable expectations.

**Completion criterion:** KAD-002 is finished as a **design/specification** task. No parser, CLI behavior, automated fixtures, or tests are claimed implemented.
