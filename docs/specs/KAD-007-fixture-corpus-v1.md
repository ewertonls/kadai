# KAD-007: fixture corpus v1 contract

> **Status:** Accepted fixture contract; declarative corpus is checked in. The Odin runner and product behavior are not implemented or verified by this status.
> **Milestone:** v0.1. **Owner:** KAD-007. **Recorded:** 2026-11-08. **Architecture amendments:** 2026-11-08.
> **Depends on:** [KAD-002](KAD-002-frontmatter-v1.md), [KAD-003](KAD-003-project-config-v1.md), [KAD-004](KAD-004-task-identity-v1.md), [KAD-005](KAD-005-hierarchy-dependencies-v1.md), [KAD-006](KAD-006-yaml-compatibility-mutation-v1.md).
> **Artifact:** [Fixture corpus](../../tests/fixtures/v1/README.md).
> **Agent rule:** [Section 7: minimum necessary tests](#7-agent-rule-minimum-necessary-tests) applies to implementation tasks throughout the roadmap.

## 1. Decisions and purpose

KAD-007 is a **language-independent behavioral test-data contract**, not an Odin test framework or a CLI implementation.

1. Fixtures are declarative: real small input files, per-scenario JSON manifests, golden output files when exact bytes are the contract.
2. Every executed scenario owns a clean sandbox and is independently reproducible and parallelizable. No shared mutable filesystem or dependency on another test's execution order.
3. Special filesystem objects are constructed from manifest operations in a temporary directory. Unsupported host capabilities are reported separately from product failures and passing tests.
4. Manifests assert semantic outcomes and diagnostic categories, not prematurely frozen stdout, stderr, JSON response shapes, machine error codes or exit statuses (KAD-016/KAD-050/KAD-051).
5. Large inputs may have deterministic recipes instead of checked-in huge files. Such recipes are optional reference data, not a requirement to build heavyweight tests or a generic generator framework.

Fixtures live in `tests/fixtures/v1/`. They do not override KAD-002 through KAD-006. Correct a wrong expectation instead of changing valid product behavior to satisfy it. Product contract changes require an explicit amendment to the owning specification.

The existing **192 indexed scenarios are a reference catalog, not a target test count or a requirement to execute every manifest at every layer**. A contributor may cover several entries with one parameterized test. Tests are selected by the distinct required behavior/risk, under Section 7. Inventory completeness, schema validity, semantic review and passing execution are different claims; counting unique IDs proves only inventory consistency.

## 2. Layout and isolation

```text
tests/fixtures/v1/
  README.md
  index.json                # catalog of scenario IDs and manifest paths
  schema.json               # structural validation of manifests
  cases/<category>/<name>/
    manifest.json
    input/                  # literal bytes beneath sandbox root
      project/.kadai.yaml
      project/tasks/...
    expected/               # byte-exact proposed/committed outputs, when needed
```

For an executed scenario, create an **empty unique sandbox**, copy `input/` as bytes, then apply the declared `setup`. The subject is `project/` or the explicit scenario CWD/project selection. Never run a mutation against the versioned fixture source tree. Shared helper code and immutable test tables are allowed; shared mutable test state is not.

Setup/literal input paths and `cwd` are sandbox-relative with `/` separators. `action.project` resolves against `cwd`; relative `action.tasks_root` resolves against the selected project, as in KAD-003. Expected document/diagnostic paths and action `params.path`, `keep_path` and reassignment paths are selected-project-relative. Golden references are scenario-directory-relative. The adapter translates collection-relative product paths rather than freezing the CLI's eventual representation.

Reject absolute/NUL-containing setup destinations and traversal outside the sandbox. A symlink target is relative to the link's parent. It may be outside the **selected project** for containment tests, but must remain inside the sandbox. Verify physical containment through existing ancestors, not just string prefixes. Never follow links while copying inputs or comparing/cleaning filesystem inventories. This setup safety does not sanitize away a deliberately invalid path supplied to the product under test; the test action may address only sandbox-owned resources.

Native capability tests declare `requires`. Missing capability yields `unsupported_host` with a reason, not a pass. A product bug or an unavailable test adapter is not an unsupported host. Release checks must actually exercise supported platform-specific safety mechanisms on a capable host; do not obtain a green result by skipping all of them.

**Raw-byte checkout:** the Kadai repository's `.gitattributes` disables text conversion only for literal fixture inputs and golden files. This preserves LF, CRLF, BOM and mixed endings in development checkouts. It does not let the Kadai product modify a user's `.gitignore`, `.gitattributes` or tracking policy. KAD-004 separately documents raw-byte requirements for user-versioned ID markers.

## 3. Manifest v1

Manifests are UTF-8 JSON. `fixture_version` is the internal test-data format version, not the task/config schema version or a public CLI API. Keep the supported operation set small; do not implement a generic interpreter merely because the catalog lists future domain actions.

- Identification: `fixture_version: 1`, unique `id` (`category/name`), `contracts`, `description`, `cwd`, `tier`, optional `requires`.
- `setup`: ordered `mkdir`, `symlink`, `hardlink`, `chmod`, `write_bytes` (base64), `generate_file` or `generate_family`. Operation-specific required fields and types are validated by `schema.json`; shell commands and custom scripts are not accepted.
- `action`: one semantic `op` (`scan`, `validate`, `resolve_config`, `add`, `set`, `delete`, `link`, `repair_id`, `plan_patch`), optional project/root/exclusion/limit overrides and operation-specific `params`. These are test inputs, not CLI grammar.
- `expect.result`: `ok`, `diagnostic`, `refused`, `scan_incomplete`, `unsupported_schema`, `config_error`, or the narrowly scoped `safe_patch_or_refusal` described below. `expect.scan_complete` refers to task inventory completeness when asserted, not automatically to history/recovery validation.
- `expect.documents`: exact unordered set of observed document records, keyed by selected-project-relative path. Each record has classification (`valid`, `invalid_candidate`, `unsupported_schema`, `non_task`) and a usable ID only when justified. Excluded files do not appear. An omitted `documents` makes no assertion about that set.
- `expect.diagnostics`: required category/path/field/target conditions. With `diagnostic` or `refused`, extra independent diagnostics are allowed unless `allow_additional_diagnostics: false`; `ok` prohibits unexpected errors. A listed warning does not authorize an unrelated error. `ordered_diagnostics`, when present, is the exact ordered diagnostic sequence and takes precedence over additional-diagnostic allowance.
- `readiness`: unique ID/result assertions for listed tasks, not a claim that other tasks are absent. `fields` is always an object keyed by the exact fixture task ID, whose value maps field names to expected decoded JSON values. Preserve order in sequence-valued fields. `custom_types` addresses a top-level custom key in the sole identified task; multi-task cases must use explicit keyed assertions rather than guess a task.
- `roots`, `ready_selection`, `quarantined_ids`, `warnings` and `history_markers` are exact unordered sets when present. `relationships.parents` is an unordered set of `{child,parent}` records and `relationships.prerequisites` of `{task,target}` records. `cycle_members.parent` and `.dependency` are sets of sets of participant IDs, not enumeration-order expectations. Distinguish written ID case from case-folded identity; the adapter must not silently normalize stored values.
- `goldens` maps destination paths to scenario-relative expected files for actual committed outputs. `proposed_goldens` does the same for the returned bytes of read-only `plan_patch`, which still requires `no_writes: true`. Do not create goldens for incidental formatting or whole terminal output.
- `unchanged` lists files that must remain byte-identical; `absent` lists paths that must not exist afterward. `unchanged_spans` is limited to top-level field names and `body` in a single-file patch case, never an unconstrained expression language. Compare original raw spans and verify the intended target change; do not treat the subject's own reported success as the oracle.
- `next_id` asserts the ID actually allocated/created by `add`, not a prediction returned without creating a task. Successful mutating adapters must also check valid resulting source, required durable ID records and preservation of unrelated files/bytes. Omitted goldens are not permission for destructive writes.

**No-write assertions follow KAD-006 Section 6.** Reads, validation and `plan_patch` require identical preexisting contents and object inventory, with no newly created state. Ignore access timestamps caused by reading. For a mutating invocation rejected during preflight, user files, config, history and recovery must be unchanged; only its documented stable coordination infrastructure may have been created while acquiring locks. The persistence adapter enumerates that narrow allowance, never a blanket `.kadai/` exemption. Do not unlink/recreate live locks to pass an assertion. Tests of failure after persistence starts must assert the allowed reservation/recovery effects instead of setting `no_writes: true`. A post-commit output failure must not be reported as an effect-free rejection.

**Optional patch coverage:** `safe_patch_or_refusal` is allowed only with `plan_patch` for the optional source layouts in KAD-006 Section 5.2. A refusal must preserve source/state and match the declared refusal diagnostic. A success must produce the requested semantic change, preserve all unrelated bytes/comments and reparse safely; refusal-only diagnostics do not apply to a successful branch. Mandatory simple patches still require `ok`; intrinsically invalid operations still require `refused`. This single assertion does not authorize a generic alternative-workflow engine or weakening preservation. Implement these optional-layout tests only when their risk is not already covered or when adding that layout support.

Unknown fields, misspelled operations, missing required parameters and unsupported assertions in a **selected** test are fixture/adapter failures, not ignored checks. `schema.json` catches structure; path containment, catalog uniqueness and assertion semantics need only small ordinary validation helpers. A full JSON Schema engine need not be embedded in the product or duplicated in Odin.

Every manifest is cataloged once in `index.json`; paths must exist and IDs must agree. Fixing an incorrect expectation under its cited owning contract is allowed without inventing a new product requirement. New scenario semantics require a reviewed change or a new ID. Goldens may never be silently regenerated from the implementation's observed output.

## 4. Deterministic generation and limit checks

The minimum tests use **small limits through the existing invocation overrides**, not production-sized inputs. For each distinct counter, exercise `N` and `N+1` through its real accounting path; an in-range override can reuse those cases. Check default/ceiling constants and invalid overrides in a compact parameter table. Invalid limit flags fail before project/config/task access. An aggregate case must stay below unrelated per-document limits, or explicitly raise those unrelated limits for that invocation. Use few files rather than hundreds of thousands.

Production budgets remain in KAD-006; reducing test size does not reduce product safety. A per-document resource failure that prevents accounting for a candidate also makes the collection scan incomplete. Unreadable non-excluded entries have the same completeness consequence. A fully read invalid task is different. Internal-state validation uses its own bounded counters as specified by KAD-006 and must not accept a partial history maximum.

`generate_file` recipes have `path`, `kind` and positive integer `target`:

- `task_source_bytes`: valid small task header plus ASCII body padding to the exact whole-file byte count.
- `yaml_header_bytes`: valid small task and a `custom.padding` scalar, padded with ASCII `x` to the exact header byte count, excluding delimiter lines.
- `yaml_node_count`: valid task with `custom.items` scalar elements to reach the exact node count, including mapping keys and collections.
- `yaml_depth`: valid task with nested `custom`, root mapping at depth 1.
- `regular_file`: exact byte length, optional literal UTF-8 `prefix`, then repeated `repeat_byte` (default ASCII `x`).

`generate_family` has `path`, `kind` and `count` (`entries`, `markdown_candidates`) or `total` (`yaml_bytes_total`, `yaml_nodes_total`). Entries use flat, stable ASCII filenames; candidates are ordinary `.md` files without a frontmatter opener. Aggregate generators use unique IDs and obey unrelated **effective invocation** limits. A target too small for the required valid document is a fixture error. The adapter may use direct small builders instead of implementing every recipe in the catalog.

Generators use explicit UTF-8/LF, stable indexed names and deterministic contents, never clocks, randomness, locale or platform newline conversion. Before invoking Kadai, verify the claimed `assert_generated` count/bytes/depth with the builder's arithmetic or a trusted check independent of the code under test. A generator failure is not an expected product rejection. Hash literal bytes only when needed for a preservation or repeatability assertion; do not require expensive whole-corpus hash inventories for each ordinary test.

Historical production-sized recipes remain reference examples. `tier: heavy` is opt-in and not a release gate. `tier: normal` is a cost label, not an instruction to implement or execute all entries. No scheduled heavy suite, throughput benchmark or stress harness is required without a named performance failure, scaling requirement or maintainer request. Small-boundary tests supersede the earlier requirement to materialize every production default and default+1.

## 5. Coverage requirements

Cover the distinct accepted behaviors, not every combination or presentation variation:

- Recognition/schema: ordinary Markdown, valid/invalid/partial/future tasks, required keys and Kadai-specific scalar resolution, including known string fields versus `custom` numbers.
- Preservation: mandatory scalar/key/list edits, BOM/newlines/comments/body retained, directed repair and intrinsically unsafe/invalid edits refused.
- Discovery/identity: effective CWD/config/overrides, exclusions and link boundaries, complete inventory, case-insensitive collision quarantine and durable allocation non-reuse.
- Graphs: separate parent/dependency rules, cycle detection, three-state direct readiness and deletion/reference safety.
- Resources: small parser/scan/state-counter boundaries, valid/invalid overrides and no normal partial result after an incomplete inventory.
- Persistence: actual storage tests for no overwrite, metadata/link safety, conflicting decisions (including different written files), interruption/recovery that preserves later edits, and phase-specific failure reporting.
- CLI: a representative file-backed workflow and extra cases only for distinct CLI parsing/output behavior not covered below it.

Native locks, rename/durability, journals, ACLs/xattrs, crash injection and final output serialization belong to their implementing tasks, not a prebuilt universal KAD-007 framework. They must be tested when implemented because those mechanisms can lose data; do not replace them with parser-only mocks. Reuse the same coverage rather than replaying the whole catalog on every OS or layer. Pure domain cases can be table-driven; native code paths need relevant capable-host coverage.

## 6. Acceptance and downstream ownership

KAD-007 records the corpus, its necessary corrections and the agent policy. Index/schema checks are not evidence that semantic expectations are correct, byte goldens have been exercised, or the CLI passes. KAD-011 implements only the setup/adapters required by the first selected tests. KAD-013 through KAD-030 and KAD-039 through KAD-054 bind the necessary cases to real code as it exists.

A documented choice not to implement a redundant catalog entry is not a missing product requirement when another test covers the same risk. An unimplemented unique safety requirement remains pending; never mark it passed or silently skipped. Keep that distinction in task/release reports instead of using fixture count as progress.

No Kadai command creates or edits a user's Git tracking policy. Development-repository attributes protecting fixture bytes are separate. No parser, writer, heavy generator execution, native recovery or cross-platform runtime behavior is claimed complete by this specification.

## 7. Agent rule: minimum necessary tests

**Implement only necessary, indispensable tests. This rule applies to all subsequent Kadai tasks.**

1. Add a test only for an accepted requirement not already covered, a distinct failure mechanism, or a concrete regression. Before adding it, inspect existing tests and extend a parameter table or assertion when that covers the risk. State the requirement/risk briefly in the task or PR; do not create another test-planning framework.
2. Test observable behavior at the lowest level that genuinely verifies it. Do not duplicate the same scenario across unit, integration and CLI tests unless the additional layer exercises a different risk. Use real storage/concurrency tests where mocks cannot establish the safety guarantee.
3. Prefer small deterministic inputs and existing invocation limit overrides. Check `N`/`N+1` boundaries without generating production-sized trees/files. Large load/stress suites require a demonstrated scaling risk or an explicit maintainer request.
4. Do not create generic test frameworks, unused fixture operations, elaborate mock hierarchies, combinatorial matrices, test-count targets or coverage-percentage gates. Do not reproduce the upstream YAML library's full conformance suite. Test Kadai's parsing policy and integration instead.
5. Use golden files only for exact-byte contracts. Avoid broad snapshots of terminal output, internal implementation details or whole repositories. Test stable semantic results and targeted preservation invariants.
6. Keep indispensable checks for data-loss prevention, allocation/history integrity, discovery boundaries, conflicting writers and recovery. Reduce duplicated cases and scaffolding, not the safety guarantees or their only meaningful test.
7. Never change an expected result merely to make the implementation pass. Resolve the owning contract, fixture and implementation disagreement first. Optional-layout support may improve safely; it is not a permanently mandated refusal.
8. Stop when the accepted behavior and distinct risks are covered. Do not invent optional cases or new infrastructure to make a suite look more complete. Existing catalog entries are reusable evidence inputs, not a quota. Report only checks actually run, plus any remaining unique requirement or unavailable native capability.
