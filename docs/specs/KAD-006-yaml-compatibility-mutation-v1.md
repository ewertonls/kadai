# KAD-006: YAML compatibility, resource limits and source-safe mutation v1

> **Status:** Accepted specification. KAD-014 implements the task document boundary rules in Section 2.3.
> **Milestone:** v0.1. **Owner task:** KAD-006. **Recorded:** 2026-11-07.
> **Depends on:** [KAD-001 product scope](KAD-001-v0.1-scope.md), [KAD-002 task frontmatter v1](KAD-002-frontmatter-v1.md), [KAD-003 project configuration v1](KAD-003-project-config-v1.md), [KAD-004 task identity v1](KAD-004-task-identity-v1.md), and [KAD-005 hierarchy and dependencies v1](KAD-005-hierarchy-dependencies-v1.md).
> **Scope:** Accepted YAML representations, task recognition under parse failures, scalar interpretation, deterministic parser/scan budgets, eligibility for byte-preserving edits and their failure behavior.

## 1. Principles and boundaries

Kadai reads user-owned Markdown and configuration files; parsing does not grant permission to rewrite them. Preserve source bytes unless a separately authorized CLI mutation identifies an exact, safe patch. No read, discovery or validation operation rewrites a document, repairs YAML, creates internal state or changes the ID history.

Distinguish five gates:

1. **Boundary extraction:** find the task's YAML frontmatter without interpreting Markdown as YAML.
2. **Syntax and resource validation:** parse a bounded YAML document, rejecting unsupported constructs and ambiguous keys.
3. **Document/schema interpretation:** identify the discriminator and schema version, decode fields under KAD-002/KAD-003 and classify the task.
4. **Domain integrity:** resolve IDs, statuses, hierarchy and prerequisites from the effective collection.
5. **Mutation eligibility:** establish an unambiguous source span, expected semantic change, coordination/identity checks and safe filesystem replacement.

Passing an earlier gate never implies passing a later one. A successfully parsed document may be read-only because its representation cannot be patched without collateral changes.

**Precedence:** KAD-002 governs task fields, typing and defaults; KAD-003 governs project configuration and collection selection; KAD-004/KAD-005 govern identity/graph safety. KAD-006 supplies the narrower syntax, limits and source-mutation mechanics without changing those contracts. Atomic storage, metadata preservation, durable journals and cross-collection coordination belong to KAD-026/KAD-029/KAD-030. KAD-007 Section 7 governs minimal test implementation, not product semantics.

Kadai v1 uses the LibYAML event parser for task frontmatter and project configuration. LibYAML 0.2.5 is the syntax baseline. Sections 2 and 4 further restrict the accepted input. Kadai resolves scalar types from the event text and style under Section 3.1, including YAML 1.2 Core types for `custom`. [KAD-013 parser decision](../development/yaml-parser.md).

## 2. Supported YAML syntax

### 2.1 Accepted representations

Within the resource limits, accept the following LibYAML representations in task frontmatter and `.kadai.yaml`.

- Block and flow mappings and sequences, including nested combinations and empty collections (`{}`, `[]`).
- Plain, single-quoted and double-quoted scalars, escapes supported by LibYAML, and literal and folded block scalars (`|` and `>`) with their indentation and chomping indicators.
- Quoted mapping keys, Unicode scalar content, blank lines, inline and standalone comments, and ordinary indentation.
- One document with a mapping root, subject to the schema's key rules.
- Optional UTF-8 BOM only at the beginning of task source; LF or CRLF line endings. Preserve original bytes, including mixed LF/CRLF, when reading or patching. A lone CR line break is unsupported.

In a flow sequence, write `custom: {labels: [":start"]}` for a list containing the string `:start`. LibYAML rejects the unquoted spelling `[:start]`.

A YAML representation can be syntactically accepted but fail field validation: e.g. a multiline `title`, an object where `status` must be a scalar, an unknown v1 top-level key, or a non-string nested `custom` key.

### 2.2 Rejected or unsupported constructs

Reject, with diagnostics and no mutation:

- Anchors (`&name`), aliases (`*name`), explicit tags (`!x`, `!!str` and verbatim tags) anywhere, including otherwise unrelated `custom` data. Do not expand aliases or infer merge semantics.
- YAML directives (`%YAML`, `%TAG`), multiple documents, complex/non-scalar mapping keys, and malformed syntax.
- Indentation using tabs, unsupported line breaks, invalid UTF-8, and duplicate mapping keys at any depth.
- A root other than a mapping or any mapping key that does not satisfy the enclosing schema's string-key requirement.

Check the bounded YAML bytes for unsupported line breaks before parsing. Reject a bare CR and literal U+0085, U+2028 or U+2029, including inside quoted scalars. LibYAML treats these characters as line breaks and can fold U+0085 into a space. A double-quoted escape such as `"a\u0085b"` preserves that code point where the field permits it. This check applies only to the YAML header or configuration file. The Markdown body stays opaque.

The literal key `<<` is **not** a merge directive under the v1 contract; where schema-permitted, it is just a string key. Quoted `"<<"` is likewise a string key. No implicit merging is performed. Anchors/aliases that often accompany YAML merge patterns remain unsupported.

Do not treat an unsupported feature as an empty value, silently skip it, or let a parser library expand it before validation. A future schema version does not authorize these constructs in v1 tooling.

### 2.3 Document boundaries

Task documents follow KAD-002: an optional UTF-8 BOM, then an opening `---` delimiter line, a YAML header, a closing `---` delimiter line, then arbitrary Markdown body (possibly empty). Delimiters must be complete lines, using LF/CRLF or EOF where appropriate; they are not YAML fields.

- Match exactly three ASCII hyphens starting in column one, without spaces or comments. The delimiter range includes its LF or CRLF when present. A closing delimiter at EOF leaves an empty body.
- If the initial `---` is immediately followed by a bare CR, U+0085, U+2028 or U+2029, report an unsupported line break. This also applies after a leading UTF-8 BOM.
- Adjacent opening and closing delimiter lines enclose a zero-byte header. Extraction succeeds; the absent discriminator makes the Markdown a non-task.
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
- `custom` values follow **YAML 1.2 Core Schema**: strings, arbitrary-precision integers, floats (including `.nan` and infinities), booleans, null, sequences and nested maps. `yes`/`no`/`on`/`off` are strings, not YAML 1.1 booleans. Plain `0007` under `custom` is the decimal integer `7`, while quoted `"0007"` is a string. Do not apply YAML 1.1 timestamp resolution, implicit octal based only on a leading zero, or sexagesimal-number rules.
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

Invalid candidates must remain diagnosable by path, with classification confidence made explicit; they are never silently promoted to valid tasks or automatically rewritten. An incomplete scan due to **resource exhaustion or unreadable/unresolved filesystem entries** is separately fatal to collection completeness (Section 4), even if task recognition cannot finish. Lack of readable bytes is not proof of a non-task.

### 3.3 Schema-version handling

- Absent/null `schema_version` means task/schema v1 as defined by KAD-002/KAD-003; other supported values must have the declared integer shape.
- A future task schema version, when confidently identified with `kadai: task` and a unique supported discriminator/version shape, is **unsupported-schema**, read-only. Preserve its bytes; do not run v1 unknown-field validation against it or infer that it can be rewritten safely.
- Only KAD-002's stable recognition envelope may provide an unsupported document's ID for collision/allocation checks. That envelope is not permission to read status or graph semantics from future schemas. Unverifiable syntax/identity remains unavailable to dependent operations.
- Unknown `.kadai.yaml` schema versions are fatal to effective configuration loading as required by KAD-003. CLI overrides cannot bypass structural, duplicate-key, syntax or version errors. New reserved fields require an explicit schema-evolution policy; absent/null never silently changes meaning.

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

**CLI configuration:** Every budget above must have an explicit command-line override path in v0.1, either an individual flag or a documented, unambiguous `--limit`-style grammar decided by KAD-047. Defaults apply when absent. Values must be positive integers in the appropriate unit and cannot exceed hard ceilings; invalid flags fail before project/config/task file access. An override applies **only to that invocation**, is not stored in `.kadai.yaml`, and must not change the selected collection's identity. The same parsed limits govern discovery and any re-scan/revalidation under locks. Higher caps do not authorize unsafe syntax, whole-file normalization or skipped validation.

The separate configuration document is protected by the **per-YAML-document** byte/node/depth limits before KAD-003 applies effective field overrides. The collection-wide totals apply to task collection scans, not to the standalone config parse.

For ordinary Markdown without an initial frontmatter delimiter, discovery can classify it as non-task after a bounded prefix check, without reading its complete body or applying the task-file-size budget. For files whose task candidacy cannot be ruled out safely, size/byte-budget failures are diagnostics, not silently ignored non-tasks. Ignored paths from KAD-003's mandatory/user exclusions never consume a candidate-parse budget; directory traversal still accounts for entries examined before exclusion.

A scan that exceeds a budget before proving complete discovery is **incomplete**, including a per-file/header/depth/node limit that prevents safely accounting for a candidate. The same rule applies to inability to enumerate a non-excluded directory, read a potentially relevant file, or resolve an observed disappearance/identity change with a bounded retry (KAD-003 Section 6). Never return a normal `list`, `show`, `tree`, `ready`, dependency result, allocation, deletion or mutation based on its partial index. `validate` may report reliably observed errors together with a prominent **scan-incomplete** diagnostic; it must not claim full validation. Do not choose winners from an incomplete ID set or infer absence of inbound references. All collection writes stop. Raising an invocation-local limit, resolving the I/O problem, or explicitly narrowing the effective collection/exclusions is the recovery path.

A complete scan may still contain ordinary invalid task candidates or graph errors. Those are **not automatically incomplete-inventory failures**; KAD-002/KAD-005's diagnostic-only reads and targeted, proven-safe operations remain possible. Do not turn one fully read malformed task into an unconditional block on unrelated safe collection operations. Completeness of directory enumeration alone does not prove a malformed task's identity/reference content is usable for allocation or deletion.

A predictable traversal order and deterministic diagnostic ordering are required so limit-boundary tests and failures do not depend on filesystem enumeration order. Scanning never writes cache or recovery state. This is not a promise of an atomic snapshot against uncoordinated external editors.

### Bounded internal-state reads

`.kadai/` is excluded from **task discovery**, not from operational resource protection. History and journal readers reuse existing invocation budgets with independent counters; this adds no new CLI flags or storage format:

- A used-ID marker or journal/control record's raw bytes are bounded by the per-document byte budget. Structured control records also use the per-document node and depth caps before unbounded allocation.
- Entries examined in an internal-state validation pass, including directories and links, are bounded by the filesystem-entry budget. Total control-record bytes read are bounded by the aggregate scan-byte budget; structured nodes use the aggregate node cap.
- Recovery snapshot contents are streamed, bounded per source by the task-source byte budget and by the aggregate byte budget for snapshots actually read in that recovery invocation. Ordinary allocation need not read all old snapshot contents.
- Exceeding a cap or failing to read required state makes **that state validation incomplete** and blocks operations relying on it. Report the state path and limiting dimension; never accept a partial history maximum, reset history, delete markers or guess a safe recovery state. A task-only read that does not depend on this state need not load it. `validate` must identify incomplete history/recovery validation separately from a complete task inventory.

### Testing these limits

Verify each distinct counter's `N`/`N+1` boundary using a small positive invocation-local limit and the real parsing/traversal path. Test override range validation with a compact parameter table and check production defaults/ceilings as constants. Large production-sized trees/files are not required to prove these rules. Do not require the same boundary at unit, integration and CLI layers; KAD-007 Section 7 governs necessary coverage.

## 5. Source-preserving patch contract

### 5.1 Mutation approach

Validate YAML with a real parser. Maintain a separate source-aware patch plan grounded in original **raw byte offsets**, not character indices or reserialized YAML output. Parser-provided line/column/character offsets must be converted and verified against the original UTF-8 bytes before patching.

For an authorized mutation:

1. Establish KAD-003's applicable writer coordination and a complete trustworthy collection scan when the command requires one; resolve a unique eligible task/target and the exact file identity. A read-only patch planner may return proposed bytes without committing; actual apply must revalidate under coordination.
2. Parse the original bytes, validate supported syntax, schema/version and the targeted source structure, and compute an immutable in-memory hash/source snapshot for conflict checks.
3. Locate one unambiguous top-level field (or explicitly supported sequence item) and produce a bounded set of ordered, nonoverlapping byte-range replacements/insertions/deletions.
4. Apply the patch **in memory**. The only changed bytes must belong to the requested field or minimal syntax needed to insert/remove its entry or item. Preserve all unrelated raw bytes, Markdown body, BOM, comments, whitespace, newline spelling, key ordering and unrelated YAML scalar lexemes.
5. Reparse the **complete proposed output**, enforce the same limits, verify intended semantic change and compare unrelated decoded fields and bytes. Reject if the changed field is invalid, a new schema error appears, any unrelated semantic value changes, or a formerly present unrelated comment disappears/moves. Preflight the chosen response format so a predictable unsupported JSON value is rejected before persistence.
6. Only after successful preflight, hand verified bytes to KAD-029/KAD-030 for durable history observation/reservation where needed, snapshots, coordinated read-set/identity/hash recheck, durable same-filesystem staging and atomic replacement. Never write a partially prepared document. Persistence failures follow Section 6, not the no-effect preflight-rejection contract.

No whole-header reserialization fallback, canonical formatter, implicit key sort, line-ending conversion, quote normalization of unaffected nodes or blanket comments removal is allowed.

### 5.2 Operations and source-style rules

| Operation | Permitted patch | Must refuse when |
| --- | --- | --- |
| Replace known top-level scalar (`title`, `status`, `priority`, `parent`, etc.) | Replace only its scalar token, retaining key, separator, leading/trailing trivia and attached inline comment. Preserve scalar style where it can represent the new value. | Value/span is ambiguous, unsupported, folded across unsafe source regions, or cannot be encoded and validated without collateral changes. |
| Insert a missing top-level key | Insert a minimal new mapping entry at an unambiguous source boundary, retaining the existing key order and line endings. | Root style, comments, delimiter placement or spacing prevent a provably isolated insertion. |
| Remove an optional top-level key | Remove only the entry's owned bytes, including necessary syntax/line separator adjustment, without deleting or relocating comments. | Comment ownership, flow separators, block scalar layout or document structure is ambiguous. Do not remove required keys from an otherwise valid task. |
| Add/remove `tags` or `depends_on` item | Patch only sequence item and minimal comma/dash/separator syntax, retaining other values, order and comments. Works with supported flow or block sequences when boundaries are provable. | A comment belongs to the removed item and cannot be preserved in place, separators are ambiguous, or preserving existing formatting would require reformatting the entire sequence. |
| Targeted repair of invalid field | Apply one supported, safely located corrective patch that removes the targeted field error without introducing new errors. | Identity/discriminator is ambiguous, YAML syntax cannot be parsed, schema version is unsupported, or patch safety cannot be proven. |

**Strict preservation does not prohibit replacing the requested scalar's own lexeme.** For example, changing a plain scalar to a minimally quoted scalar may be necessary to express `: ` or `#` safely; this is allowed only when the *scalar itself* is the isolated target and all surrounding syntax/comments remain byte-identical. When the current scalar style can express the new value, retain it. A need to rewrite the whole property's layout or to move its comment is not a reason to silently normalize; refuse.

An existing flow sequence can safely change only its list contents while preserving the original inline comment bytes, including its language:

```yaml
# before
tags: [backend, cli] # categorias
# after
tags: [backend, cli, docs] # categorias
```

A multi-line sequence with individual item comments must refuse removal if no precise, comment-preserving ownership rule can be proven. The patcher may support more source patterns later, but **never** relax the preservation invariant through whole-value serialization. Accepting a YAML form for reads is independent of patch coverage.

Mixed LF/CRLF inputs remain valid for reading; when inserting new lines, copy the unambiguous local line-ending convention, never normalize preexisting lines. If the insertion location has no reliable convention, refuse that patch. Preserve a trailing newline (or its absence) in unrelated source.

**Minimum required v0.1 patch coverage:** support single-line plain/single-quoted/double-quoted known scalar replacement in an ordinary block root, including a preserved inline comment and necessary scalar quoting; isolated optional-key insertion/removal without ambiguous comment ownership; and add/remove in simple flow or block string sequences without comments attached to the removed item. Support directed scalar repairs on these same layouts. BOM, an unrelated body/final newline, Unicode and existing LF/CRLF bytes are not grounds for refusing an otherwise isolated scalar replacement.

**Additional layouts:** root-flow edits, complex comment attachment, block-scalar rewrites and insertions at mixed-newline boundaries are not blanket mandatory failures. They may be declined when safe patching is unsupported, or accepted when the same byte/semantic invariants are proven. Tests must distinguish required success, intrinsically invalid operations that must be refused, and optional layout support. An implementation gaining safe support must not fail merely because an old fixture encoded a previous layout refusal. No broad implementation of optional patterns is required for v0.1.

### 5.3 Invalid fields and explicit repair

Decision for v1: **permit directed repair** of a schema-invalid but syntactically parseable task, subject to the same byte safety and domain restrictions.

- Require an unambiguous task discriminator and usable unique ID, a supported schema version, a fully parsed input and a uniquely targetable invalid/missing field.
- A supported CLI mutation may correct an invalid `status`, `title`, `priority`, missing required field, or other explicitly supported field. It cannot use the repair allowance to modify an unrelated field on an otherwise schema-invalid task.
- Post-patch validation must establish that the target's relevant error is resolved (or strictly reduced for a well-defined supported repair) and no new errors are introduced. Unrelated preexisting field errors remain visible; no normalization or opportunistic repair.
- Relationship repair still follows KAD-005: no speculative edges, cycles or unsafe deletions. Identity collisions/ID repair follow KAD-004's explicit path-based protocol; a duplicate or malformed `id` is **not** bypassed with an ordinary metadata update.
- Read-only commands can diagnose tasks beyond write eligibility. No auto-repair during `list`, `show` or `validate`.

Example: a unique task with `status: pending` and no configured `pending` status may receive a targeted `status: todo` patch. It does not gain permission to rewrite an unrelated `custom` mapping.

## 6. Failure, diagnostics and concurrency

Failures are **fail-closed and non-destructive**, with effects described by phase rather than an inaccurate promise that every failed invocation left no state:

1. **Planning/preflight rejection:** parse, semantic, unsafe-patch and predictable response-encoding failures leave task source, config, used-ID history and recovery records unchanged. Read-only planners/queries create no state. A mutating invocation acquiring coordination may create only documented stable lock infrastructure; that narrow exception is not permission to reserve IDs or create recovery snapshots before preflight succeeds. Do not unlink/recreate live locks merely to make a no-write test pass.
2. **Persistence started but incomplete:** durable reservations/observation markers remain, numbering gaps are valid, and necessary snapshots/journals remain for recovery. Report an incomplete operation with its known effects; do not call it a no-effect rejection or recycle reserved IDs. A detected conflict before source replacement can still leave these permitted records.
3. **Commit completed, response failed:** a broken output pipe or later delivery error does not undo committed state. Report committed state on stderr when possible; do not auto-retry the mutation or rollback because response delivery failed. KAD-050/KAD-051 must distinguish this from preflight rejection. Lack of a delivered response is not proof of lack of effects.

The actual persistence/commit point and crash-state representation belong to KAD-029/KAD-030. KAD-047/KAD-050/KAD-051 must preserve these distinctions. JSON conversion or formatting errors predictable from the planned result must be checked before durable history/source changes, not discovered after a successful write.

Use distinct machine-diagnostic classes for:

- Invalid UTF-8/frontmatter boundary; YAML syntax; unsupported YAML construct.
- Duplicate mapping key; invalid root/key type; invalid schema field/value; unsupported schema version.
- File/header/node/depth limit; collection-entry/candidate/aggregate limit; unreadable/unstable inventory; incomplete scan or incomplete internal-state validation.
- No unambiguous source span; comment/style-preservation conflict; unsafe patch; proposed-output validation failure.
- Detected on-disk source identity/hash conflict; storage/lock/recovery failure; recovery conflict with a later edit; incomplete persistence or post-commit output failure.

Diagnostics should include collection-relative path where known, field/key or related ID where reliable, actual and configured limit on resource failures, and raw byte span plus line/column when available. Do not invent a line or field when parsing failed before it could be established. Exact serialized codes, JSON shape, stdout/stderr and exit statuses belong to KAD-016/KAD-050/KAD-051; preserve these diagnostic distinctions when assigning them.

**Conflict boundary:** Kadai writers coordinate complete decisions, protecting relevant read sets, namespace/graph predicates and physical files across overlapping collections (KAD-003 Section 9), verify identity/hash immediately before replacement, and require private immutable pre-write recovery material. An external editor ignoring those locks can still save in the gap between final verification and atomic rename. This residual race remains real: do not claim universal lost-update prevention. KAD-029/KAD-030 specify durability, journals and platform-specific supported metadata.

For multi-file detach/delete and duplicate-ID repair, a successful per-file YAML patch **does not** make the set of replacements a single atomic transaction. Follow KAD-004/KAD-005's preflight, journal, restart/resume/rollback and coordination requirements. Pending operations must not be bypassed via another overlapping collection. Automatic recovery verifies the expected current per-step state, including identity/content and presence/absence; if a later edit or recreated path diverges, preserve current data and recovery material and require explicit resolution. Never restore snapshots unconditionally or claim a stale/partially applied plan completed.

## 7. Fixtures, acceptance and handoffs

KAD-007 represents these distinct behaviors with compact parameterized cases and byte-exact goldens only where bytes are the contract:

1. Block/flow mappings and sequences; nested `custom`; quoted keys, Unicode and mixed LF/CRLF; BOM; empty body; comments; literal/folded block scalars.
2. YAML 1.2 Core scalar edge cases: `yes`/`no`, numbers with signs/bases/leading zeros, large integers, exponents, `.nan`/`.inf`, quoted numeric strings, null forms and plain date-like strings. Compare known-field typing with `custom` typing rather than duplicating the upstream parser's full conformance suite.
3. Duplicate top-level keys across quoted/plain spelling, nested duplicate `custom` keys, Unicode normalization variants, non-string mapping keys and unsupported anchors/aliases/tags/directives/multiple documents.
4. Valid `kadai: task` marker with malformed later YAML, quoted discriminator, commented marker, nested marker, block-scalar marker, duplicated discriminator, missing closing delimiter, false marker after the Markdown boundary and invalid UTF-8.
5. The minimum required source patches from Section 5.2, preserved comments and exactly unchanged Markdown body. Intrinsically invalid operations must refuse; optional layouts may safely succeed or refuse without normalization. Do not freeze an implementation limitation as a permanent product rule.
6. Small-limit `N`/`N+1` checks for each distinct resource counter, an in-range override, compact invalid-limit/default/ceiling checks, aggregate exhaustion and no normal partial result. Enumeration/read failures also make the relevant inventory incomplete. Production-sized fixtures and scheduled heavy suites are not mandatory.
7. Targeted `status: pending` -> `todo` repair when uniquely identified; refusal on invalid YAML, ambiguous IDs, unsupported schema and unrelated attempted edits.
8. Golden tests for intended byte spans and a small number of real persistence tests for phase-specific effects. Native tests in KAD-029/KAD-030 cover atomic replacement, metadata, conflicting decision read sets and recovery that preserves later edits. Reuse this coverage rather than duplicating the corpus at every layer.

**Acceptance for KAD-006 (design only):**

- [x] LibYAML syntax baseline, accepted forms and unsupported constructs defined.
- [x] Strict scalar/key semantics, version handling and conservative malformed-task recognition defined.
- [x] Numeric parser/scan budgets, bounded internal-state reads and CLI-only override policy specified.
- [x] Incomplete-inventory failure, minimum/optional source patch coverage, directed repair and phase-specific failure conditions defined.
- [x] Necessary implementation tests delegated to KAD-007, KAD-013 through KAD-030, KAD-047 and KAD-050/KAD-051 under KAD-007's minimal-testing policy.

KAD-013 verified the Odin bindings and scalar source marks. KAD-015 owns field decoding and the reader's check for unsupported literal line breaks. Its tests should distinguish a raw U+0085 in YAML from an escaped U+0085 in a permitted string value.
