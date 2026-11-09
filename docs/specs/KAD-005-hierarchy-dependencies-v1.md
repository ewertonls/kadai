# KAD-005: hierarchy and dependencies v1 contract

> **Status:** Accepted specification, not implemented.
> **Milestone:** v0.1. **Owner task:** KAD-005. **Recorded:** 2026-11-07.
> **Depends on:** [KAD-001 product scope](KAD-001-v0.1-scope.md), [KAD-002 task frontmatter v1](KAD-002-frontmatter-v1.md), [KAD-003 project configuration v1](KAD-003-project-config-v1.md) and [KAD-004 task identity v1](KAD-004-task-identity-v1.md).
> **Scope:** Independent parent and prerequisite graphs, graph integrity, derived readiness, safe relationship mutations and deletion with inbound references. CLI syntax, on-disk YAML patch mechanics, JSON schemas and transactional recovery details belong to later tasks.

## 1. Model and invariants

Kadai derives **two independent directed graphs** from the current Markdown task files in one effective collection:

1. **Hierarchy:** a child may declare one `parent: ID`; this makes it a child of that task. Its primary purpose is organization.
2. **Prerequisites:** a task may declare an ordered `depends_on: [ID, ...]`; each entry means that referenced task must be completed before the declaring task can be considered ready.

No implicit relationship exists because of directory nesting, filename, task status, or matching text in Markdown bodies. Moving a file within the discoverable effective collection changes neither graph; CLI moves into excluded paths or outside that collection are refused under KAD-003 Section 6.

The graphs are independent. The same two tasks may be related in both graphs, even in opposite directions. A cycle created by *combining* parent and prerequisite edges is not an error unless one individual graph contains a cycle. A hierarchy edge neither adds a prerequisite nor imposes any status constraint.

Relationships contain IDs only, with KAD-004's effective-collection scope and ASCII case-insensitive comparison. Preserve the author's original ID spelling and the source representation when editing unrelated data. Cross-collection links are unsupported; no automatic fallback to a surrounding collection or other worktree occurs.

A completed parent may have incomplete children; a completed child may have an incomplete parent. Neither automatically updates the other. A parent task is not an aggregate or container status.

## 2. Edge direction and target resolution

| Relationship | Stored in | Logical edge | Meaning |
| --- | --- | --- | --- |
| Parent | Child `C` has `parent: P` | `P -> C` | `P` is the logical parent of `C` |
| Dependency | Task `B` has `depends_on: [A]` | `A -> B` | `B` requires `A` |
| Reverse dependency | Derived only | `A -> B` | `B` is a dependent of `A` |

The reverse dependency index and children lists are **derived**; neither is persisted to other task files or cached as authoritative state. An absent/null `parent` means a hierarchy root. An absent/null/empty `depends_on` means no prerequisites, per KAD-002.

Use a complete scan of the effective collection for identity resolution. For every reference:

- **Resolved:** exactly one identified task has that folded ID and is schema-valid and supported for the operation.
- **Missing:** no identified task has the folded ID in a complete inventory. A read/enumeration failure is not proof that a target is absent.
- **Ambiguous:** multiple task candidates have that folded ID; KAD-004 quarantines all of them and no target wins.
- **Invalid/unsupported target:** an identifiable but malformed, incompatible-schema, or otherwise unusable task exists; report the specific condition rather than assuming it is a valid target.
- **Invalid reference value:** the field's type, ID grammar, duplicate values, or YAML syntax violate KAD-002; report a schema diagnostic. Do not fabricate edges from values that cannot be interpreted unambiguously.

A reference to an invalid candidate with an identifiable unique ID is **not** resolved simply because a usable `id` or `status` can be extracted. A recognized unsupported-schema candidate cannot silently be treated as a v1 node. The validator may inspect confidently parsed supported edges for diagnostics; recognition of a future schema's ID alone does not authorize reading its relationship layout or prove it has no inbound references.

Unknown IDs and colliding IDs are not automatically repaired, pruned, or rebound. A restored task with the same unique ID can satisfy a previously missing reference on the next scan, consistent with KAD-004. No mutation occurs during reads.

## 3. Hierarchy integrity

A valid hierarchy is a directed forest: each task has at most one parent, no task is its own parent, and no chain of `parent` links returns to a previously visited task.

- `parent` must be null/absent or a single syntactically valid ID; arrays and multiple parent fields are invalid under KAD-002.
- Reject self-parenting, including differently cased spellings of the same ID.
- Report missing, ambiguous, invalid/unsupported parents and parent cycles.
- A cyclic component has no legitimate root; never arbitrarily break the cycle or designate a cycle participant as root.
- When displaying trees, traverse safely without infinite loops. Surface broken-parent nodes and cycles explicitly instead of silently treating them as normal roots. Descendants of a problematic node are not themselves labeled cycle members unless they belong to the actual cycle.
- Descendants are derived from reverse `parent` edges. Moving/renaming files, modifying status and changing `depends_on` never reparent tasks.
- Setting/replacing a parent must not introduce a parent-cycle. Removing or replacing a parent changes only that task's `parent` field, never its children or dependencies.

A hierarchy issue is a graph-integrity diagnostic, **not a dependency-readiness input**. For example, a task whose `parent` points to a missing ID can still be `ready`.

## 4. Dependency integrity

The prerequisite graph may be any directed acyclic graph, including shared prerequisites and dependencies on logical parents, children, or siblings.

- `depends_on` is ordered, without duplicates by ASCII-folded ID, and each element follows the KAD-002 ID grammar.
- Reject a self-dependency and any CLI change introducing a prerequisite cycle. This includes an indirect cycle closed by the proposed edge.
- Detect cycles from existing Markdown edits using graph traversal or strongly connected components (SCC). An SCC with more than one node, or a one-node SCC with a self-loop, is cyclic. Report the members and relevant edges deterministically.
- Missing, ambiguous or invalid/unsupported targets and malformed references generate distinct diagnostics.
- An existing cycle makes **its own participants** `unresolved`. It does not automatically taint the readiness of all tasks that reach the cycle.
- Validation may report a transitive problem through a chain, but readiness remains strictly direct (Section 5).
- A mixed parent/prerequisite cycle is not independently prohibited; validate each graph on its own.

A prerequisite's canonical status category comes from KAD-002/KAD-003, including user-defined status mappings. Only canonical `done` satisfies a prerequisite. Canonical `canceled` is unsatisfied, not equivalent to `done`.

## 5. Readiness, status and validation

Readiness is computed on demand and **never stored** in task frontmatter. It is distinct from persisted `status`, including a manually assigned `status: blocked`.

For a schema-valid, uniquely identified task `T`:

1. If `T` participates in a dependency cycle, its derived readiness is `unresolved`.
2. If any **direct** prerequisite is missing, ambiguous, invalid/unsupported, has an unusable status/category, or is otherwise not safely resolvable, readiness is `unresolved`. This takes precedence even if another direct prerequisite is incomplete.
3. Otherwise, if at least one direct prerequisite has a canonical category other than `done`, readiness is `blocked`.
4. Otherwise, readiness is `ready`, including when `depends_on` is absent, null or empty.

An external task `C` depending on `A`, where `A` is `done` but is itself in a dependency cycle with `B`, may still be `ready` if all `C`'s own direct prerequisites are valid and `done`. Only `A` and `B` are `unresolved` from that cycle. Equally, a `done` prerequisite whose own prerequisite is `todo` satisfies its caller's **direct** readiness rule; `validate` reports the transitive inconsistency separately.

Example:

```yaml
# KAD-010
status: done
depends_on: [KAD-011]
# KAD-011 has status: todo
```

KAD-010 remains `done` in the Markdown source. Its own readiness is `blocked`. `validate` reports that it is marked complete with unmet prerequisites, but does not rewrite the status. If another task directly depends on KAD-010, it sees KAD-010's canonical `done` and can be `ready`.

### Status transitions

- Creating or transitioning a task **into** canonical `done` through the CLI is rejected by default when that task's readiness is `blocked` or `unresolved`. An explicit override (such as `--force`; exact syntax belongs to KAD-047) may permit the status transition, but it cannot bypass file safety, identity ambiguity or graph-structure validation for relationship changes.
- Editing `depends_on` **on an already `done` task** is allowed even if the edit makes its derived readiness `blocked`. The status stays `done`, and `validate` reports the inconsistency. Do not require force just because the task was previously completed.
- Changing a prerequisite's status may immediately change the readiness of dependent tasks on the next read. Never mutate dependents automatically.
- Parent/child statuses impose no transition restrictions. A broken parent link does not prevent a transition to `done` merely because of the hierarchy defect.
- Direct Markdown edits are always respected on the next scan and diagnosed, not reverted.

### `kadai ready` default selection

The default ready-task query selects **only** ordinary valid, uniquely identified tasks whose derived readiness is `ready` and whose *persisted status category* is `todo` or `in_progress`. Custom statuses mapped to those categories are included. Status categories `blocked`, `done` and `canceled` are excluded even if derived readiness is `ready`.

Other read/validate operations may expose derived readiness for any otherwise readable valid task, regardless of persisted category. Exact filtering, display order and JSON fields belong to KAD-047/KAD-048/KAD-050. Invalid candidates remain diagnostic-only as in KAD-002.

## 6. Relationship mutations

Mutations use source-aware YAML patches, not whole-file normalization, and follow KAD-002/KAD-004's coordination, identity, history, snapshot and filesystem safety requirements.

For adding or replacing `parent` and adding `depends_on` entries, the CLI must verify before writing:

1. The source task is a unique, supported, eligible task.
2. Each new target resolves uniquely to an eligible task in the **same effective collection**.
3. No self-link or duplicate dependency is introduced.
4. The proposed change does not introduce a cycle in its **own** graph.
5. Source spans, filesystem paths, file identity, read-set/predicate coordination and write recovery satisfy the safe-mutation contracts.

Removing a link only removes the chosen relationship. In particular, a parent change never rewrites child links, and a dependency change never updates statuses or hierarchy.

A CLI mutation must not silently repair unrelated pre-existing graph errors; errors in unrelated components do not automatically prohibit proven-safe mutations. If an existing error or incomplete scan prevents determining whether the **proposed relationship** is safe, reject that change with a diagnostic. Targeted repair/removal of malformed relations requires an explicitly supported, safely patchable operation; normal mutation must not guess at ambiguous YAML.

Case-insensitive lookup is used for identity and duplicate checks; do not normalize stored ID case incidentally. Unknown/incompatible schemas cannot be modified by assuming v1 layout. Exact duplicate-add/no-op behavior, subcommands and output conventions belong to KAD-047, without weakening the no-duplicate invariant.

## 7. Deletion and inbound references

Deleting a task never deletes its descendants or dependents by implication. An absent task file must not make the CLI silently erase incoming references.

### Default removal

For an explicitly requested deletion of task `X`:

1. Resolve `X` uniquely and verify its eligible file identity.
2. Scan the effective collection for **all** incoming `parent: X` and `depends_on` occurrences, using ASCII-folded IDs, including references in the same file and any confidently parsed supported candidate.
3. If any incoming references exist, **block by default**. Report each referring task/path, field and relationship. Do not delete `X` or change other task files. Preflight rejection and stable lock artifacts follow KAD-006 Section 6.
4. If no incoming references are found and the scan is trustworthy for that decision, remove the task through KAD-037/KAD-029's secure deletion and recovery rules; **keep** KAD-004's used-ID marker. Protect the absence-of-inbound-references predicate through commit, not only the file being deleted.
5. If a relevant candidate, ambiguous ID or unsupported/malformed source makes it impossible to establish the incoming-reference set, refuse rather than claiming the task is unreferenced. Unreadable non-excluded paths and truncated discovery also prevent that claim.

The outbound `parent` and `depends_on` links *inside* `X` do not prevent deletion by themselves; removing `X` removes those outgoing edges. Existing structural defects elsewhere are diagnostics, not license to ignore a possible incoming reference.

### Explicit detach-and-remove

A separate, explicit destructive mode may **detach references then remove `X`**:

- Generate a complete preview of every affected collection-relative file, referencing ID, relation type and source span, plus the task file to delete. Provide a dry-run/plan path for scripts; do not require an interactive prompt. Exact grammar belongs to KAD-047/KAD-052.
- For each direct child with `parent: X`, unset that parent, making the child a logical root. **Do not** reparent to `X`'s parent and **do not** delete descendants.
- For each dependent, remove only the occurrences of `X` from `depends_on`, retaining every other dependency and its relative order. The resulting empty list and omission are semantically equivalent; safe patch representation belongs to KAD-006/KAD-020.
- Leave each surviving task's `status`, Markdown body, unrelated YAML, custom metadata, file path and other relationships unchanged. No cascading status transitions or readiness edits.
- Re-scan and recheck the plan under the required read/predicate coordination immediately before applying. If a required reference cannot be confidently identified and safely patched, or the plan is stale, **abort without claiming successful deletion**. Validate predictable output encoding before persistence.
- This may modify several files and then delete one: the operation is **not filesystem-atomic as a group**. Require KAD-029/KAD-030's durable multi-file operation journal, immutable pre-write recovery material, verified restart/resume/rollback and coordinated locks (including overlapping collections). An interrupted apply must be surfaced and prevent conflicting follow-on writes through any overlapping root until resolved.
- Automatic resume/rollback must verify each step's expected path/file identity, bytes/hash, supported security metadata and presence/absence (KAD-004 Section 6). A later edit or recreated destination causes a recovery conflict; preserve the current file, snapshot and journal rather than restoring blindly.
- A deletion's used-ID marker remains untouched, even when the task file is removed. No cross-collection reference cleanup is attempted. Cross-collection coordination protects physical operations, not a global graph.

Do not offer a cascade-delete mode in v0.1. A user may also explicitly remove references through ordinary relation commands before using default deletion.

## 8. Read/query and validation contracts

The collection scan builds an in-memory `id -> task` lookup (quarantining duplicates), a parent index, derived children index, prerequisites index and reverse dependents index. The graph view is rebuilt on reads; no graph database, sidecar graph or persisted readiness is required.

- `tree` uses parent links and a stable task ordering. It must terminate on malformed graphs and distinguish genuine roots from broken-parent nodes/cycles.
- Dependency inspection exposes immediate prerequisites and immediate reverse dependents, with an explicitly documented edge direction. Transitive graph views are deferred to KAD-082.
- `validate` examines the effective collection without creating, rewriting, reserving IDs or repairing anything. Report all detectable parent and dependency self-links, missing/ambiguous/invalid targets, cycles, duplicate IDs and status/readiness inconsistencies.
- Graph-integrity issues in otherwise schema-valid tasks should remain visible in normal listings, with derived readiness reflecting **dependency** problems only. Malformed/unsupported task candidates follow KAD-002's diagnostic-only/unsupported-schema policy; collided IDs remain quarantined.
- Distinguish actionable graph errors (missing reference, self-link, cycle, ambiguity, invalid target) from non-blocking consistency warnings (e.g. `done` with incomplete direct or transitive prerequisites). Overrides and manual edits may legitimately leave such warnings.
- Diagnostics identify relationship kind, source ID/path and relevant target ID/path, plus cycle membership/path when available. Use deterministic ordering; avoid duplicate cycle spam and never rely on directory traversal order for a winner.
- Diagnostic codes, exit statuses, complete JSON structures, parser resource limits and performance budgets belong to KAD-006/KAD-050/KAD-051. Never invent recovered edges or drop unreadable candidates silently.

## 9. Collection boundaries and concurrency

All edges are resolved within the **effective collection** from KAD-003. Independent collections can overlap physically and give the same file different graph neighbors depending on the selected root/exclusions; a task found only in another collection is missing in the current one.

A change made through one collection is not an automatic global repair of other independent collections that might also scan the same physical file. KAD-030 must protect the decision's read set and namespace/graph predicates through commit, as required by KAD-003 Section 9. Checking only hashes of written files cannot detect another cooperating writer changing a different prerequisite or adding a new referencing file.

For example, two writers must not both validate `A depends_on B` and `B depends_on A` against the same old graph and then commit to different files. Deletion racing a new inbound reference has the same requirement. Serialize these operations or reject one through equivalent atomic conflict detection; a coarse writer lock is sufficient for v0.1. Pending transaction protection must remain visible through different project/collection selections. Ordinary external editor saves remain subject to KAD-002's documented final-check/replace race and recovery limitation.

Reads and `validate` remain side-effect-free. A modification that can be proven safe does not require a totally error-free unrelated graph; however, no operation may rely on unknown, colliding or malformed references to claim structural integrity.

## 10. Required fixtures and acceptance

KAD-007 and the relevant implementation tasks cover the distinct behaviors below under KAD-007 Section 7. Prefer table-driven domain tests; retain native concurrency/recovery checks only where they test a different failure mechanism:

| Scenario | Expected behavior |
| --- | --- |
| Files nested under folders with no `parent` | All logical roots; no inferred hierarchy |
| Parent `P` done, child `C` todo; reverse status combination | Both allowed; no status propagation |
| Child points to missing/ambiguous/unsupported parent | Hierarchy diagnostic; dependency readiness unaffected |
| Parent points to itself or indirect parent cycle | Diagnostic; CLI refuses to introduce cycle; tree terminates |
| Mixed hierarchy/dependency cycle but neither individual graph cycles | Valid graph combination |
| `depends_on` absent/null/[] | Derived `ready` if otherwise valid |
| Dependency with `todo`, `blocked` or `canceled` category | Derived `blocked` |
| Dependency with `done` category, including custom status mapped to `done` | Satisfies direct prerequisite |
| Missing, duplicate-ID, unsupported-schema or invalid-status prerequisite | Derived `unresolved`, ahead of `blocked` |
| A <-> B dependency cycle; C depends on A (`done`) | A/B `unresolved`, C `ready` if other direct prerequisites done |
| A -> B -> C where A todo, B done, C depends on B | C `ready`; validator diagnoses inconsistent completed chain |
| Mark as `done` while `blocked` or `unresolved` | CLI denies by default, permits explicit force; never auto-fixes links |
| Add unsatisfied dependency to already `done` task | Allowed, `done` unchanged; validation warning |
| `status: blocked` without prerequisites | Derived `ready` but excluded from default `kadai ready` |
| Custom status mapped to `todo` or `in_progress` with ready prerequisites | Included in default `kadai ready` |
| Remove task with child/dependent references, default mode | No task/history changes; list all inbound references |
| Explicit detach/remove with children and dependents | Direct children become roots; specified prerequisites removed; no cascade |
| Unpatchable inbound reference during detach/remove | Abort and require correction; no false success |
| Interrupted multi-file detach/remove | Pending recovery visible across overlapping roots; later edits are not overwritten |
| Duplicate ID due to Git merge | Quarantine all collisions, no arbitrary reference target |
| Moving a file between eligible directories | Identity and graph edges preserved |
| Overlapping roots that see different task sets | Edges resolved independently, complete conflicting decisions coordinated |
| Read/`tree`/`ready`/`validate` | Never mutate tasks, histories or internal state |

## 11. Completion and handoffs

- [x] Hierarchy and prerequisites defined as independent ID-based graphs.
- [x] Parent cycles, dependency cycles, missing/ambiguous/invalid targets and read-only diagnostics defined.
- [x] Three-state direct readiness, cycle-local effect and status semantics defined.
- [x] `kadai ready` default category filter defined.
- [x] Explicit detach-and-remove and default reference-protected deletion defined.
- [x] Mutation safety, multi-file recovery needs, fixture cases and implementation ownership recorded.

**Follow-ups:** KAD-006 owns parse/patch safety and exact supported YAML representation; KAD-007 fixture files and minimal-testing policy; KAD-029/KAD-030 transaction journal/locking/recovery; KAD-037 deletion implementation; KAD-039–KAD-046 graph and validation implementation; KAD-047/KAD-048 command grammar/filter/order; KAD-050/KAD-051 JSON and diagnostics. KAD-082 owns richer graph views after v0.1. This is a completed **design** contract; no implementation or automated tests are claimed.
