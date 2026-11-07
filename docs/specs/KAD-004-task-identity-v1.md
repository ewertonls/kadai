# KAD-004: task identity and used-ID history v1

> **Status:** Accepted specification, not implemented.
> **Milestone:** v0.1. **Owner task:** KAD-004. **Recorded:** 2026-11-07.
> **Depends on:** [KAD-001 product scope](KAD-001-v0.1-scope.md), [KAD-002 task frontmatter v1](KAD-002-frontmatter-v1.md), and [KAD-003 project configuration v1](KAD-003-project-config-v1.md).
> **Scope:** Stable task identity, automatic ID allocation, durable per-ID history, collision quarantine and explicit reference-aware repair, and default filenames.

## 1. Identity and collection boundary

- A task's sole logical identifier is the `id` field in its Markdown frontmatter. Filename, directory, title, content hash, Git path and inode are **not** its identity. Moving or renaming a task does not change its ID, references or logical parent.
- The namespace is the **effective collection** selected by KAD-003, not a Git repository or the entire project. Collection-specific history lives under that collection's physical `<tasks.root>/.kadai/`. Distinct, even overlapping, collections have independent histories and ID allocation.
- IDs follow KAD-002's ASCII grammar: `[A-Za-z0-9]` at both ends and `[A-Za-z0-9_.-]` internally, with no schema-level length cap. The first and last character must be alphanumeric. ASCII-only case folding defines the lookup key: `KAD-004` and `kad-004` are the same identity. Preserve the original spelling in task files.
- This is **not** a globally unique ID scheme. Separate worktrees, branches, clones, collections or machines can independently issue the same ID. No Git integration, registry service or cross-collection identity reconciliation is assumed.
- The CLI must not change `id` through generic metadata `set`/`unset`. CLI-driven re-ID uses a dedicated, reference-aware operation. Direct Markdown editing remains permitted; later scans honor the resulting ID and diagnose any conflicts.

## 2. Generated IDs and allocation

An omitted/null `ids.prefix` generates `0001`, `0002`, etc. A configured prefix such as `KAD` generates `KAD-0001`, `KAD-0002`, etc. Preserve the configured prefix's spelling; compare all IDs and prefixes case-insensitively using ASCII folding.

The suffix is an unsigned decimal integer with a minimum display width of four digits. After `9999`, it grows naturally (`10000`). There is **no persisted next-number counter**.

Under the effective collection lock, an allocator must:

1. Scan the effective collection using KAD-003's exclusions and KAD-002's task-recognition rules. Index every confidently extracted, syntactically valid ID from current task candidates, including invalid candidates/unsupported schemas when the ID itself is unambiguous. Do not treat ordinary Markdown as a task.
2. Load and verify the complete applicable used-ID history. Compare all live and recorded IDs by their ASCII-folded keys.
3. For the effective prefix, find the greatest **numeric suffix** in live IDs and history IDs having exactly the generated form (`<prefix>-<digits>`, or `<digits>` for no prefix), matching the prefix case-insensitively. Leading zeroes do not affect numeric value: `KAD-9` and `KAD-0009` both contribute `9`. Other IDs do not affect that prefix's sequence. A changed prefix starts or resumes its own sequence.
4. Choose the first allocatable integer **greater** than that maximum; render with at least four decimal digits. Check the full candidate ID against all live/history keys and the default destination pathname. A physically occupied destination is never overwritten: advance to the next suffix when using the default path. Explicitly requested occupied destinations fail instead of being silently moved.
5. Durably create the per-ID reservation marker **before** creating the Markdown task. Recheck relevant filesystem identities/paths under the lock. Only then create the task using no-replace semantics.

Use decimal-string or equivalent overflow-safe arithmetic for comparison/increment. Never wrap a bounded integer or silently clip a suffix. If a generated ID cannot be safely represented, stored or created within operational limits, fail without creating a task (KAD-006/KAD-026).

**Examples:** If live IDs include `KAD-0002` and recorded history includes `KAD-0017`, the next generated `KAD` ID is `KAD-0018`. If history contains `KAD-9` and there is no greater value, generate `KAD-0010`. A manual ID `other-0100` does not advance `KAD`. With no prefix, `0014` advances the unprefixed sequence to `0015`, not the `KAD` sequence.

Do not reuse an automatically issued ID while its history remains intact, even if its task has been deleted. A failed/interrupted creation after successful reservation may leave a gap, which is valid.

## 3. Durable used-ID markers (format v1)

One persistent marker represents one ASCII-folded ID, whether the ID came from automatic creation or a manual file. The marker is a reservation/observation record **only**. It does not assert that a task currently exists, store task state or claim ownership of an existing file.

Versioned layout, relative to the effective collection root:

```text
.kadai/
  used-ids/
    v1/
      ab/
        <64-lowercase-hex-sha256>.id
```

- Let `key` be the full ASCII-folded ID encoded as ASCII bytes. The filename is lowercase hexadecimal `SHA-256(key)` plus `.id`. The two-character fan-out directory is its first two hexadecimal characters. This keeps path components short even for very long valid IDs, works on case-insensitive filesystems and avoids unsafe filename characters.
- Marker content is exactly two LF-terminated ASCII lines:

  ```text
  kadai-used-id-v1
  <ascii-folded-id>
  ```

- This format is deterministic. No timestamps, local paths, numeric counters, process IDs or machine-specific fields belong in a marker. Two branches that record the same ID independently produce identical marker bytes.
- A marker must have the correct version header, ID grammar, canonical lowercasing, final newline, pathname and SHA-256 digest. Two different IDs must never be accepted under one digest path. Unknown formats, corrupt markers, hash mismatches, unreadable records and unsafe state paths produce diagnostics and **block ID-allocation and other writes requiring history**. Never silently overwrite, discard or regenerate a corrupt marker.
- First-time marker creation must use safe, no-replace file creation and durable file/directory synchronization as defined by KAD-029/KAD-030, while the collection lock is held. An already existing correct marker is idempotent. A partially created or ambiguous marker is **not** accepted as a successful reservation.
- Reads, `list`, `show`, `tree`, `ready` and `validate` must never initialize or mutate this directory. `validate` should inspect present history, including malformed records, and report inconsistencies. Ordinary queries may read history as needed but cannot repair it.
- `kadai init` does not create operational history files. An uninitialized, no-config project gets this directory when the first write needs to record an ID.
- Only these markers are authoritative for allocation history; any in-memory index is disposable. Directory presence is not a task database. A missing entirely new history directory is allowed, but cannot prove that old history was never deleted. Detectably inconsistent existing state fails closed; lost markers that leave no evidence cannot be reconstructed with certainty from live tasks.

Users choose whether to track any `.kadai/` state in Git. Kadai never manages `.gitignore` or requires Git tracking. Moving a collection without its `.kadai/` history weakens non-reuse guarantees, as documented by KAD-003.

## 4. Manual IDs, observation and reappearance

- Users may create tasks by writing Markdown files directly, with arbitrary valid IDs. The history is **not** a prerequisite for recognizing or reading them.
- On operations that mutate a collection, and while holding its exclusive lock, observe all confidently recognized task IDs with unambiguous valid grammar. Persist missing markers for these live IDs before completing a successful task mutation, including IDs that originated in hand-edited files. A candidate with unrelated field errors still contributes its ID if the discriminator and ID are unambiguous; it remains invalid for normal task operations.
- Malformed/ambiguous candidate IDs that could represent a task cannot be guessed or silently skipped for new-ID allocation. Report the ambiguity and refuse allocation until it is clarified. Never mint an ID solely by trusting an incomplete scan.
- Read-only commands do not record even valid manual IDs. Consequently, a manually created ID that is deleted **before any Kadai write observes it** cannot be remembered.
- If a historical ID reappears in one valid Markdown file, accept that file normally if no other live file has the same folded ID. This supports Git restores and manual editing. A marker prevents **automatic** reallocation; it is not a prohibition on manual reappearance. The system cannot infer whether the reappearance is a restoration or deliberate reuse.
- Removing a task never removes its marker. Similarly, changing `id` manually leaves any previous marker intact. A later write records the new observed ID; existing `parent`/`depends_on` references are not automatically edited when a human changes an ID.

## 5. Duplicate IDs and quarantine

Detect conflicts on every full collection scan, regardless of whether Git was involved. If two or more distinct discovered task files have the same folded ID, **all** are quarantined. Neither alphabetical path order, last modification time, Git history nor marker presence selects a winner.

- Report the ID and **all** conflicting paths. Include parseable invalid candidates and compatible/identifiable unsupported-schema candidates in collision detection; never hide a duplicate merely because another field is invalid.
- Normal ID-based reads, updates, deletion, relationship operations and automatic reference resolution for the ambiguous ID must fail. Path-based diagnostic inspection remains available. Unrelated uniquely identified tasks may still be handled when the operation does not resolve the collided ID; generated-ID allocation additionally requires a trustworthy collection scan/history.
- A marker does not distinguish two live files using the same ID: both correspond to the same marker. The fact that a marked ID is present in a single file is **not** a collision.
- Validation reports the complete collision set and every `parent`/`depends_on` reference whose target is ambiguous. Readiness and other graph results follow KAD-002/KAD-005's `unresolved` rules, never a guessed target.
- Git merges may cause live collisions even when identical per-ID marker files merge cleanly. Detection is independent of Git, and neither scan nor validation silently edits files.

## 6. Explicit, reference-aware repair

Repair of a colliding ID is a dedicated user-directed operation, not an implicit side effect of `list`, `validate`, `add` or generic `set`. Exact command syntax/JSON belongs to KAD-047/KAD-050.

Required plan-and-apply semantics:

1. Identify all files carrying the collided ID by **concrete collection-relative paths and verified file identity**, not by the ambiguous ID alone. Show the full collision set and explicit diagnostics.
2. The user selects exactly one file to **retain the original ID** and supplies or accepts fresh, non-colliding IDs for the other files. Generated replacements use the same locked, durable allocator and reservation rules. Never assign a replacement that currently exists under another live task; automatically generated IDs never reuse a historical marker.
3. Enumerate each inbound reference occurrence in reserved `parent` and `depends_on` fields of all confidently parsed tasks in the collection, including references inside the conflicting files. For **every ambiguous occurrence**, the user must explicitly select its intended target (the keeper or a reassigned file). A bulk decision is allowed, but retaining the old ID is not an implicit choice. Include references whose written case differs from the collided ID.
4. Preview the complete changes: each file whose ID changes, each reference field/source span to edit, and any unresolved, unsupported or unsafe file. Never rewrite arbitrary Markdown body text, custom fields or coincidental ID strings.
5. Before apply, validate the selected targets, new IDs, graph integrity (KAD-005), source identity/hashes, mutation eligibility, link/path safety and required snapshots. Re-scan/recheck after acquiring locks; if the plan is stale, refuse and require regeneration. Refuse to finalize while a relevant reference remains ambiguous or cannot be safely patched.
6. Reserve every new CLI-issued ID durably **before** committing its task changes. Apply only targeted, source-aware edits that preserve unrelated YAML/Markdown bytes and supported filesystem metadata (KAD-006/KAD-029). Keep original ID markers permanently.

A repair may touch multiple files; multiple filesystem replacements are **not one atomic rename**. KAD-029/KAD-030 must provide a durable repair journal, pre-write recovery material and restart handling for such workflows. An interrupted repair is explicitly diagnosed, prevents unsafe conflicting mutations and supports verified resume/rollback; never claim a half-written operation succeeded. Other readers, especially external editors, may see intermediate filesystem states. Do not promise an atomic whole-collection snapshot without implementing one.

If a relevant candidate or unsupported-schema file cannot be safely understood or modified, stop and require explicit manual correction; never guess its references or silently omit it. Relationship validation and deletion rules remain the responsibility of KAD-005.

A user can change IDs directly in Markdown without invoking this operation. The next scan must diagnose broken references/collisions; Kadai must not silently rewrite them.

## 7. Paths and default filenames

- A new task generated by plain `kadai add` is placed in the effective task root using **`<ID>.md`** as its default basename, e.g. `tasks/KAD-004.md`. If a command explicitly selects an allowed subdirectory, the same basename convention applies there. Exact CLI placement flags belong to KAD-047.
- Do **not** generate filenames from the title or append slugs. The ID is an allocation key, not a requirement that an existing filename match it.
- A filename is not validated against the frontmatter ID. Handwritten tasks may use any safe, supported `.md` filename in any eligible nested directory. Moving or renaming files preserves IDs. Changing a title, status or ID never implicitly renames an existing file, including during duplicate repair.
- A destination occupied by any file, non-task, directory or link is never overwritten. Default generated names may advance to the next ID to find an unused destination; an explicit destination collision is an error. Recheck the destination before secure creation. No unsafe symlink traversal or pathname race is allowed (KAD-026/KAD-029).
- Directory nesting is physical organization only. It never supplies `parent` or dependency relationships.

## 8. Locking, failures and history limits

- All cooperating writers in one effective collection use the native collection lock across **scan → observation/reservation → task mutation**, including deletion and repair. Shared-file modifications across overlapping collections also require KAD-003/KAD-030's physical-file coordination. Locking is local; two independent clones/worktrees are not synchronized.
- Reservation is durable **before** creation, not part of a nonatomic best-effort file write. If task creation fails afterward, retain the marker and accept a numbering gap. Never roll it back merely to reuse the number.
- A partial write, corrupt history record, unverifiable filesystem state, interrupted repair journal, or inability to persist history must fail closed for affected writes. Repairs of operational state are explicit; no silent "reset history" or inferred full reconstruction from current files.
- The guarantee is conditional on retaining the history: deleting the collection or its marker files, not sharing history across branches/clones, and losing unobserved manual IDs can all allow the same historical ID to be issued elsewhere. This is a documented boundary, not a promise of universal uniqueness.
- A source editor not cooperating with locks retains the KAD-001/KAD-002/KAD-030 last-check/atomic-replacement race. Require safe snapshots and conflict checks but do not claim absolute prevention of lost edits.

## 9. Required fixture/acceptance scenarios

KAD-007 and the implementation tests must cover:

| Scenario | Expected result |
| --- | --- |
| Fresh no-config collection; first `add` | Creates `0001.md` and a durable `0001` marker; no implicit `.kadai.yaml` |
| Configured prefix `KAD`, then switched prefix, then switched back | Per-prefix high-water values derived from live/history; no counter |
| Historical highest ID deleted | Next generated suffix remains above recorded maximum |
| Recorded manual ID, then file deleted | No automatic reuse of that ID |
| Manual ID read only, then deleted before any write | No false guarantee that it was recorded |
| Same historical ID restored as sole live task | Accepted, with original marker retained |
| `KAD-0009`, `KAD-9`, `KAD-10000` | Numeric comparison ignores zero padding; sequence moves to `KAD-10001` |
| Extremely large decimal suffix | Safe decimal comparison/increment or explicit resource-limit error; no wrap |
| `KAD-0001` vs `kad-0001` in different paths | Both quarantined; no winner |
| Merge of two branches allocating the same ID | Deterministic identical marker, live-file collision diagnosed |
| Duplicate ID referenced by multiple `parent`/`depends_on` edges | Every ambiguous reference requires explicit repair destination |
| Interrupted reservation before task creation | Durable marker retained and never automatically reallocated |
| Interrupted multi-file repair | Journal detected; no false success; safe recovery required |
| Invalid/hash-mismatched marker or unknown history version | Diagnose and fail affected writes; do not overwrite state |
| Filename `KAD-0001.md` already occupied by a non-task | No overwrite; default allocator advances safely |
| Manual rename/move and title change | ID unchanged; references remain ID-based |
| Same physical collection selected through an internal symlink | Same history/lock identity; symlink warning (KAD-003) |
| Two different or overlapping collection roots | Independent ID histories; shared-file writer coordination |
| User does not track history in Git | Works locally; explicit limited non-reuse guarantee across clones |
| `validate` or any read | Never creates or repairs history |

Fixtures must also exercise CRLF/YAML source preservation, partial/unsupported-schema candidates, malformed/ambiguous IDs, case-sensitive filesystem differences and directory/file symlink safety as assigned to KAD-006/KAD-007/KAD-026.

## 10. Completion and handoffs

- [x] Canonical case-insensitive, collection-local and path-independent identity specified.
- [x] Prefix-based, no-counter sequential allocation and durable reservation specified.
- [x] Versioned **one-marker-per-ID** history with manual-ID observation and restoration semantics specified.
- [x] Duplicate quarantine and explicit per-reference repair specified.
- [x] ID-only default filenames, move/rename independence and collision safety specified.
- [x] Failure, Git, locking and recovery boundaries made explicit.

**Follow-ups:** KAD-005 owns graph and deletion integrity; KAD-006 YAML/patch behavior and parser limits; KAD-007 fixtures; KAD-026 filesystem identities/links; KAD-029/KAD-030 durability, coordination and interrupted repairs; KAD-037 deletion; KAD-047 exact CLI grammar; KAD-050/KAD-051 JSON and diagnostics. The specification is complete as a design artifact; no implementation or executable tests are claimed.
