# KAD-006: YAML compatibility, resource limits and source-safe mutation v1

> **Status:** Accepted specification, not implemented.
> **Milestone:** v0.1. **Owner task:** KAD-006. **Recorded:** 2026-11-07.
> **Depends on:** [KAD-001 product scope](KAD-001-v0.1-scope.md), [KAD-002 task frontmatter v1](KAD-002-frontmatter-v1.md), [KAD-003 project configuration v1](KAD-003-project-config-v1.md), [KAD-004 task identity v1](KAD-004-task-identity-v1.md), and [KAD-005 hierarchy and dependencies v1](KAD-005-hierarchy-dependencies-v1.md).
> **Scope:** Accepted YAML representations, task recognition under parse failures, scalar interpretation, deterministic parser/scan budgets, eligibility for byte-preserving edits and their failure behavior. This is a behavioral contract, not a choice of parser implementation.

## 1. Principles and boundaries

Kadai reads user-owned Markdown and configuration files; parsing does not grant permission to rewrite them. Preserve source bytes unless a separately authorized CLI mutation identifies an exact, safe patch. No read, discovery or validation operation rewrites a document, repairs YAML, creates internal state or changes the ID history.

Distinguish five gates:

1. **Boundary extraction:** find the task's YAML frontmatter without interpreting Markdown as YAML.
2. **Syntax and resource validation:** parse a bounded YAML document, rejecting unsupported constructs and ambiguous keys.
3. **Document/schema interpretation:** identify the discriminator and schema version, decode fields under KAD-002/KAD-003 and classify the task.
4. **Domain integrity:** resolve IDs, statuses, hierarchy and prerequisites from the effective collection.
5. **Mutation eligibility:** establish an unambiguous source span, expected semantic change, coordination/identity checks and safe filesystem replacement.

Passing an earlier gate never implies passing a later one. A successfully parsed document may be read-only because its representation cannot be patched without collateral changes.

**Precedence:** KAD-002 governs task fields, typing and defaults; KAD-003 governs project configuration and collection selection; KAD-004/KAD-005 govern identity/graph safety. KAD-006 supplies the narrower syntax, limits and source-mutation mechanics without changing those contracts. Atomic storage, metadata preservation, durable journals and cross-collection locking belong to KAD-026/KAD-029/KAD-030.

The YAML syntax reference for v1 is [YAML 1.2.2](https://yaml.org/spec/1.2.2/). KAD-013 evaluates maintained parsers, including LibYAML via Odin/C FFI; v1 does **not** require writing a parser from scratch.

## 2. Supported YAML syntax

### 2.1 Accepted representations

Subject to resource limits, accept the ordinary YAML 1.2 syntax below in task frontmatter and `.kadai.yaml`:

- Block and flow mappings and sequences, including nested combinations and empty collections (`{}`, `[]`).
- Plain, single-quoted and double-quoted scalars; YAML-defined escaping; literal and folded block scalars (`|` and `>`), with their indentation/chomping indicators.
- Quoted mapping keys, Unicode scalar content, blank lines, inline and standalone comments, and ordinary indentation.
- One document with a mapping root, subject to the schema's key rules.
- Optional UTF-8 BOM only at the beginning of task source; LF or CRLF line endings. Preserve original bytes, including mixed LF/CRLF, when reading or patching. A lone CR line break is unsupported.

A YAML representation can be syntactically accepted but fail field validation: e.g. a multiline `title`, an object where `status` must be a scalar, an unknown v1 top-level key, or a non-string nested `custom` key.

### 2.2 Rejected or unsupported constructs

Reject, with diagnostics and no mutation:

- Anchors (`&name`), aliases (`*name`), explicit tags (`!x`, `!!str` and verbatim tags) anywhere, including otherwise unrelated `custom` data. Do not expand aliases or infer merge semantics.
- YAML directives (`%YAML`, `%TAG`), multiple documents, complex/non-scalar mapping keys, and malformed syntax.
- Indentation using tabs, unsupported line breaks, invalid UTF-8, and duplicate mapping keys at any depth.
- A root other than a mapping or any mapping key that does not satisfy the enclosing schema's string-key requirement.

The literal key `<<` is **not** a merge directive under the v1 contract; where schema-permitted, it is just a string key. Quoted `"<<"` is likewise a string key. No implicit merging is performed. Anchors/aliases that often accompany YAML merge patterns remain unsupported.

Do not treat an unsupported feature as an empty value, silently skip it, or let a parser library expand it before validation. A future schema version does not authorize these constructs in v1 tooling.

### 2.3 Document boundaries

Task documents follow KAD-002: an optional UTF-8 BOM, then an opening `---` delimiter line, a YAML header, a closing `---` delimiter line, then arbitrary Markdown body (possibly empty). Delimiters must be complete lines, using LF/CRLF or EOF where appropriate; they are not YAML fields.

- Do not interpret `---` inside Markdown after the closing delimiter as another YAML document.
- Do not search for a later header when the initial opening delimiter is absent.
- Detect a missing closing delimiter or malformed header; never guess that Markdown belongs to the YAML header.
- Track raw byte ranges separately for the BOM, opening delimiter, YAML header, closing delimiter and body. The body is opaque to YAML processing; a metadata-only edit never touches its bytes.
- The configured `.kadai.yaml` is one YAML mapping document, not Markdown frontmatter. It has no required `---` wrapper; an optional single YAML document-start/end marker is acceptable if the parser can verify that there is no second document or non-comment trailing content.

Use bounded extraction so missing closing delimiters and oversized headers cannot cause unbounded buffering.

## 3. Types, keys, ambiguity and versions

### 3.1 Scalar resolution

Apply schema-aware decoding to **known** task and configuration fields, not the parser library's YAML 1.1 implicit conversions:

- Known string fields use the decoded scalar text, subject to field validation. Thus `id: 0001` remains the string ID `0001` and `title: 123` is the string `123`. A plain date in `due` remains text for KAD-002's explicit date validator.
- Recognized unquoted YAML null forms (including an empty value, `null`, `Null`, `NULL` and `~`) are null; quoting them produces a string. Required task fields cannot be null. Optional task/config fields follow their existing null/omission defaults.
- Known integer fields, including `schema_version`, require an integer scalar and the field-specific range; a quoted number is not silently coerced to integer.
- `custom` values follow **YAML 1.2 Core Schema**: strings, arbitrary-precision integers, floats (including `.nan` and infinities), booleans, null, sequences and nested maps. `yes`/`no`/`on`/`off` are strings, not YAML 1.1 booleans. Do not apply YAML 1.1 timestamp resolution or sexagesimal-number rules.
- Preserve original scalar lexemes/representation for unaffected fields. Keep enough typed information to prevent lossy comparisons or JSON conversions; KAD-050 owns reversible JSON handling of large/special numbers. Do not force numbers through a binary floating-point representation merely for validation.

Quoted/escaped keys are compared after YAML string decoding. The top-level task/config schema keys are case-sensitive; `"status"` and `status` denote the same key and therefore collide if both appear. Every mapping level rejects duplicates. `custom` keys are nonempty Unicode strings without control characters, compared by exact codepoint sequence, without Unicode normalization; numeric/bool keys resolved as non-strings are invalid, not silently converted to text.

No duplicate key takes precedence, even if the repeated values are identical. Do not accept YAML merge behavior to hide or create keys.

### 3.2 Task recognition and malformed source

Use KAD-002's four categories: **non-task**, **valid task**, **invalid task candidate**, **unsupported-schema task**.

For syntactically valid YAML, identify `kadai` as a unique decoded top-level string key and `task` as its exact string value. Other/missing discriminator values make it ordinary non-task Markdown; do not automatically import it.

If syntax parsing fails, use **conservative fallback recognition** only:

1. The file has the initial frontmatter opening delimiter.
2. A bounded lexical/token-prefix scan can prove a complete top-level scalar key/value declaration equivalent to `kadai: task`, including safe quoted forms and an optional trailing comment.
3. The declaration is not inside a comment, quotation, block scalar, sequence, nested mapping or Markdown body.
4. No ambiguous discriminator or conflicting duplicate `kadai` declaration has been observed. If duplicate detection cannot be completed, identity and mutation eligibility remain unavailable.

A proven marker makes a malformed document an **invalid candidate**, never a valid task. Mere substring/regex matches such as `# kadai: task` or `description: |\n  kadai: task` are insufficient. If lexical context cannot be established, do not invent recognition. For an invalid YAML document, partial ID-based indexing is unavailable even if an `id` substring is visible; a confidently parseable schema-invalid document with a unique, well-formed ID may still have KAD-002's diagnostic-only partial read.

Invalid candidates must remain diagnosable by path, with classification confidence made explicit; they are never silently promoted to valid tasks or automatically rewritten. An incomplete scan due to **resource exhaustion** is separately fatal to collection completeness (Section 5), even if task recognition cannot finish.

### 3.3 Schema-version handling

- Absent/null `schema_version` means task/schema v1 as defined by KAD-002/KAD-003; other supported values must have the declared integer shape.
- A future task schema version, when confidently identified with `kadai: task` and a unique supported discriminator/version shape, is **unsupported-schema**, read-only. Preserve its bytes; do not run v1 unknown-field validation against it or infer that it can be rewritten safely.
- Unknown `.kadai.yaml` schema versions are fatal to effective configuration loading as required by KAD-003. CLI overrides cannot bypass structural, duplicate-key, syntax or version errors.

## 4. Parser and collection resource limits

Every relevant parser path, including validation, recognition, config loading, normal reads, mutation planning and post-patch verification, uses bounded work. Defaults are chosen for typical source repositories; they are operational budgets, **not** extra schema-level ID/title length restrictions.

| Budget | v0.1 default | Hard ceiling | Accounting |
| --- | ---: | ---: | --- |
| Task candidate's complete source | 16 MiB | 256 MiB | Raw bytes in one recognized or potentially recognized task file |
| One YAML document | 256 KiB | 4 MiB | Raw YAML header bytes or whole `.kadai.yaml` bytes |
| YAML nodes per document | 10,000 | 100,000 | Scalar, sequence and mapping nodes, including mapping key nodes |
| YAML nesting depth | 32 | 128 | Root node is depth 1; descend once for each child |
| Filesystem entries examined | 250,000 | 2,000,000 | Files, directories and links encountered beneath effective root, before entering excluded subtrees |
| `.md` files considered | 50,000 | 500,000 | Each non-excluded Markdown candidate, including ordinary non-task files |
| Total YAML bytes examined per collection scan | 256 MiB | 2 GiB | Sum of bounded candidate headers actually examined |
| Total YAML nodes per collection scan | 1,000,000 | 10,000,000 | Sum of YAML nodes across the collection |

`MiB = 1,048,576 bytes`; `KiB = 1,024 bytes`. A value **equal** to a limit passes; exceeding it fails. Use overflow-checked counters, including on 32-bit platforms. Limits apply to bytes/nodes processed, not just retained AST size. Account for map keys and rejected constructs before expanding or allocating unsafe structures; use streaming parser events or equivalent guarded construction where necessary.

**CLI configuration:** Every budget above must have an explicit command-line override path in v0.1, either an individual flag or a documented, unambiguous `--limit`-style grammar decided by KAD-047. Defaults apply when absent. Values must be positive integers in the appropriate unit and cannot exceed hard ceilings; invalid flags fail before file access. An override applies **only to that invocation**, is not stored in `.kadai.yaml`, and must not change the selected collection's identity. The same parsed limits govern discovery and any re-scan/revalidation under locks. Higher caps do not authorize unsafe syntax, whole-file normalization or skipped validation.

The separate configuration document is protected by the **per-YAML-document** byte/node/depth limits before KAD-003 applies effective field overrides. The collection-wide totals apply to task collection scans, not to the standalone config parse.

For ordinary Markdown without an initial frontmatter delimiter, discovery can classify it as non-task after a bounded prefix check, without reading its complete body or applying the task-file-size budget. For files whose task candidacy cannot be ruled out safely, size/byte-budget failures are diagnostics, not silently ignored non-tasks. Ignored paths from KAD-003's mandatory/user exclusions never consume a candidate-parse budget; directory traversal still accounts for entries examined before exclusion.

A scan that reaches a budget before proving complete discovery is **incomplete**. Never return a normal `list`, `show`, `tree`, `ready`, dependency result, allocation, deletion or mutation based on its partial index. `validate` may report reliably observed errors together with a prominent **scan-incomplete** diagnostic; it must not claim full validation. Do not choose winners from an incomplete ID set or infer absence of inbound references. All collection writes stop. Raising the applicable invocation-local limit or narrowing the effective collection/exclusions is the recovery path.

A complete scan may still contain ordinary invalid task candidates or graph errors. Those are **not automatically resource-limit failures**; KAD-002/KAD-005's diagnostic-only reads and targeted, proven-safe operations remain possible. Do not turn one malformed task into an unconditional block on unrelated safe collection operations.

A predictable traversal order and deterministic diagnostic ordering are required so limit-boundary tests and failures do not depend on filesystem enumeration order. Scanning never writes cache or recovery state.

## 5. Source-preserving patch contract

### 5.1 Mutation approach

Validate YAML with a real parser. Maintain a separate source-aware patch plan grounded in original **raw byte offsets**, not character indices or reserialized YAML output. Parser-provided line/column/character offsets must be converted and verified against the original UTF-8 bytes before patching.

For an authorized mutation:

1. Start from a complete trustworthy collection scan when the command requires one; resolve a unique eligible task/target and the exact file identity.
2. Parse the original bytes, validate supported syntax, schema/version and the targeted source structure, and compute an immutable hash/source snapshot for conflict checks.
3. Locate one unambiguous top-level field (or explicitly supported sequence item) and produce a bounded set of ordered, nonoverlapping byte-range replacements/insertions/deletions.
4. Apply the patch **in memory**. The only changed bytes must belong to the requested field or minimal syntax needed to insert/remove its entry or item. Preserve all unrelated raw bytes, Markdown body, BOM, comments, whitespace, newline spelling, key ordering and unrelated YAML scalar lexemes.
5. Reparse the **complete proposed output**, enforce the same limits, verify intended semantic change and compare unrelated decoded fields and bytes. Reject if the changed field is invalid, a new schema error appears, any unrelated semantic value changes, or a formerly present unrelated comment disappears/moves.
6. Hand verified bytes to KAD-029/KAD-030 for snapshot, lock/identity/hash recheck, durable same-filesystem staging and atomic replacement. Never write a partially prepared document.

No whole-header reserialization fallback, canonical formatter, implicit key sort, line-ending conversion, quote normalization of unaffected nodes or blanket comments removal is allowed.

### 5.2 Operations and source-style rules

| Operation | Permitted patch | Must refuse when |
| --- | --- | --- |
| Replace known top-level scalar (`title`, `status`, `priority`, `parent`, etc.) | Replace only its scalar token, retaining key, separator, leading/trailing trivia and attached inline comment. Preserve scalar style where it can represent the new value. | Value/span is ambiguous, unsupported, folded across unsafe source regions, or cannot be encoded and validated without collateral changes. |
| Insert a missing top-level key | Insert a minimal new mapping entry at an unambiguous source boundary, retaining the existing key order and line endings. | Root style, comments, delimiter placement or spacing prevent a provably isolated insertion. |
| Remove an optional top-level key | Remove only the entry's owned bytes, including necessary syntax/line separator adjustment, without deleting or relocating comments. | Comment ownership, flow separators, block scalar layout or document structure is ambiguous. Do not remove required keys from an otherwise valid task. |
| Add/remove `tags` or `depends_on` item | Patch only sequence item and minimal comma/dash/separator syntax, retaining other values, order and comments. Works with supported flow or block sequences when boundaries are provable. | A comment belongs to the removed item, separators are ambiguous, or preserving existing formatting would require reformatting the entire sequence. |
| Targeted repair of invalid field | Apply one supported, safely located corrective patch that removes the targeted field error without introducing new errors. | Identity/discriminator is ambiguous, YAML syntax cannot be parsed, schema version is unsupported, or patch safety cannot be proven. |

**Strict preservation does not prohibit replacing the requested scalar's own lexeme.** For example, changing a plain scalar to a minimally quoted scalar may be necessary to express `: ` or `#` safely; this is allowed only when the *scalar itself* is the isolated target and all surrounding syntax/comments remain byte-identical. When the current scalar style can express the new value, retain it. A need to rewrite the whole property's layout or to move its comment is not a reason to silently normalize; refuse.

An existing flow sequence such as `tags: [backend, cli] # categories` can safely become `tags: [backend, cli, docs] # categorias` **only by changing the specific list contents**, preserving the original comment bytes, including its original language. The following is the acceptable actual example:

```yaml
# before
tags: [backend, cli] # categorias
# after
tags: [backend, cli, docs] # categorias
```

A multi-line sequence with individual item comments must refuse removal if no precise, comment-preserving ownership rule can be proven. The patcher may support more source patterns later, but **never** relax the refusal behavior by whole-value serialization. Accepting a YAML form for reads is independent of patch coverage.

Mixed LF/CRLF inputs remain valid for reading; when inserting new lines, copy the unambiguous local line-ending convention, never normalize preexisting lines. If the insertion location has no reliable convention, refuse that patch. Preserve a trailing newline (or its absence) in unrelated source.

### 5.3 Invalid fields and explicit repair

Decision for v1: **permit directed repair** of a schema-invalid but syntactically parseable task, subject to the same byte safety and domain restrictions.

- Require an unambiguous task discriminator and usable unique ID, a supported schema version, a fully parsed input and a uniquely targetable invalid/missing field.
- A supported CLI mutation may correct an invalid `status`, `title`, `priority`, missing required field, or other explicitly supported field. It cannot use the repair allowance to modify an unrelated field on an otherwise schema-invalid task.
- Post-patch validation must establish that the target's relevant error is resolved (or strictly reduced for a well-defined supported repair) and no new errors are introduced. Unrelated preexisting field errors remain visible; no normalization or opportunistic repair.
- Relationship repair still follows KAD-005: no speculative edges, cycles or unsafe deletions. Identity collisions/ID repair follow KAD-004's explicit path-based protocol; a duplicate or malformed `id` is **not** bypassed with an ordinary metadata update.
- Read-only commands can diagnose tasks beyond write eligibility. No auto-repair during `list`, `show` or `validate`.

Example: a unique task with `status: pending` and no configured `pending` status may receive a targeted `status: todo` patch. It does not gain permission to rewrite an unrelated `custom` mapping.

## 6. Failure, diagnostics and concurrency

Failures are **fail-closed and non-destructive**. On parse/patch failure, no task source, config, used-ID history, recovery file or other persistent state may be changed merely as a consequence of that failed patch plan. Operations that already durably reserved a new ID under KAD-004 may leave a permitted historical allocation gap; do not roll back an issued ID by reusing it.

Use distinct machine-diagnostic classes for:

- Invalid UTF-8/frontmatter boundary; YAML syntax; unsupported YAML construct.
- Duplicate mapping key; invalid root/key type; invalid schema field/value; unsupported schema version.
- File/header/node/depth limit; collection-entry/candidate/aggregate limit; incomplete scan.
- No unambiguous source span; comment/style-preservation conflict; unsafe patch; proposed-output validation failure.
- Detected on-disk source identity/hash conflict; storage/lock/recovery failure (implemented by KAD-026/KAD-029/KAD-030).

Diagnostics should include collection-relative path where known, field/key or related ID where reliable, actual and configured limit on resource failures, and raw byte span plus line/column when available. Do not invent a line or field when parsing failed before it could be established. Exact serialized codes, JSON shape, stdout/stderr and exit statuses belong to KAD-016/KAD-050/KAD-051; preserve these diagnostic distinctions when assigning them.

**Conflict boundary:** Kadai writers use collection locks and cross-collection physical-file coordination, verify identity/hash immediately before replacement, and require private immutable pre-write recovery material. An external editor ignoring those locks can still save in the gap between final check and atomic rename. This residual race remains real: do not claim universal lost-update prevention. KAD-029/KAD-030 specify recovery, durability, journal behavior and platform-specific supported metadata.

For multi-file detach/delete and duplicate-ID repair, a successful per-file YAML patch **does not** make the set of replacements a single atomic transaction. Follow KAD-004/KAD-005's journal, preflight, restart/resume/rollback and lock requirements. If a stale or unsafe member prevents complete planning, abort without claiming completion.

## 7. Fixtures, acceptance and handoffs

KAD-007 must include checked-in, byte-exact fixtures (valid, invalid and expected patch output) for at least:

1. Block/flow mappings and sequences; nested `custom`; quoted keys, Unicode and mixed LF/CRLF; BOM; empty body; comments; literal/folded block scalars.
2. YAML 1.2 Core scalar edge cases: `yes`/`no`, numbers with signs/bases/leading zeros, large integers, exponents, `.nan`/`.inf`, quoted numeric strings, null forms and plain date-like strings. Compare known-field typing with `custom` typing.
3. Duplicate top-level keys across quoted/plain spelling, nested duplicate `custom` keys, Unicode normalization variants, non-string mapping keys and unsupported anchors/aliases/tags/directives/multiple documents.
4. Valid `kadai: task` marker with malformed later YAML, quoted discriminator, commented marker, nested marker, block-scalar marker, duplicated discriminator, missing closing delimiter, false marker after the Markdown boundary and invalid UTF-8.
5. Source patches for existing scalar, missing key, removal, flow/block sequence add/remove, preserved inline/standalone comments and exactly unchanged Markdown body. Test refusals for ambiguous source spans, unsafe item comments, invalid proposed semantics and unsupported future schemas.
6. Resource limits for each dimension: value exactly equal to default, default+1, raised CLI override within ceiling, ceiling+1 rejected, aggregate-budget exhaustion, deterministic scan ordering and no normal partial query result.
7. Targeted `status: pending` -> `todo` repair when uniquely identified; refusal on invalid YAML, ambiguous IDs, unsupported schema, unsafe source spans and unrelated attempted edits.
8. Golden tests proving that failed patches leave source bytes unchanged; existing successful patches change **only** documented spans. Separate KAD-029/KAD-030 tests cover real atomic file replacement, security metadata, symlink/hardlink safety, source conflicts and recovery.

**Acceptance for KAD-006 (design only):**

- [x] YAML 1.2 accepted forms and explicitly unsupported constructs defined.
- [x] Strict scalar/key semantics, version handling and conservative malformed-task recognition defined.
- [x] Numeric parser and collection budgets with CLI-only override policy and hard ceilings defined.
- [x] Incomplete-scan failure, source-aware byte patching, directed repair and non-destructive failure conditions defined.
- [x] Test cases and ownership of implementation work delegated to KAD-007, KAD-013 through KAD-022, KAD-025 through KAD-030, KAD-047 and KAD-050/KAD-051.

No parser, patcher, fixture corpus or cross-platform implementation is claimed complete. KAD-007 remains open. 
