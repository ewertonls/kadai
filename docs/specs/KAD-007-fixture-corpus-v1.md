# KAD-007: fixture corpus v1 contract

> **Status:** Accepted fixture contract; corpus is checked in, CLI/parser implementation is not.
> **Milestone:** v0.1. **Owner:** KAD-007. **Recorded:** 2026-11-08.
> **Depends on:** [KAD-002](KAD-002-frontmatter-v1.md), [KAD-003](KAD-003-project-config-v1.md), [KAD-004](KAD-004-task-identity-v1.md), [KAD-005](KAD-005-hierarchy-dependencies-v1.md), [KAD-006](KAD-006-yaml-compatibility-mutation-v1.md).
> **Artifact:** [Fixture corpus](../../tests/fixtures/v1/README.md).

## 1. Decisions and purpose

KAD-007 is a **language-independent behavioral test-data contract**, not an Odin test harness or a CLI implementation.

1. Fixtures are declarative: real small input files, per-scenario JSON manifests, golden output files for byte-preserving patches.
2. Every scenario owns a clean sandbox and is independently reproducible and parallelizable. No implicit shared base filesystem or mutation order.
3. Special filesystem objects (symlinks, hardlinks, permissions, etc.) are constructed from manifest operations in a temporary directory. Test outcomes distinguish unsupported host capabilities from product failures; no unreported skip counts as passing.
4. Manifests assert semantic outcomes and diagnostic **categories**, not prematurely frozen stdout, stderr, JSON response shapes, machine error codes, or exit statuses (KAD-016/KAD-050/KAD-051).
5. Large/boundary scenarios use declarative, deterministic file generators. Their byte/count contracts are checkable without versioning huge files.

Fixtures live in `tests/fixtures/v1/`. They do not silently override KAD-002 through KAD-006. If a disagreement is found, correct the fixture or explicitly amend the owning specification.

## 2. Layout and isolation

```text
tests/fixtures/v1/
  README.md                 # authoring and runner instructions
  index.json                # closed list of scenario IDs and manifest paths
  cases/<category>/<name>/
    manifest.json           # one scenario, exactly one semantic action
    input/                  # checked-in, literal bytes under sandbox root
      project/.kadai.yaml   # only when scenario requires configuration
      project/tasks/...
    expected/               # checked-in byte-exact post-action goldens (if applicable)
```

Every scenario is provisioned from an **empty unique sandbox**. Copy `input/` without text transformations; then run `setup` steps. The test subject is the resulting `project/` (or the explicit relative CWD/project selection). The runner must not execute from the source fixture tree. It checks input hashes/lengths before invoking the subject and verifies post-action files as bytes. A scenario may declare an alternative `cwd` within the sandbox for project-selection tests.

Paths are portable sandbox-relative strings with `/` separators. Reject absolute paths, NUL, traversal above sandbox, and duplicate destination declarations in fixtures. Symbolic-link targets may be lexically relative and point **outside the selected project** but must remain inside the sandbox; never let a fixture setup escape its sandbox. Test symlink behavior with existing containment rules; do not follow links while copying inputs. Tests involving native permissions, metadata, or links must declare `requires` and report `unsupported_host` with an explicit reason when a prerequisite is unavailable. A skip cannot be mistaken for the expected Kadai refusal.

## 3. Manifest v1

Each `manifest.json` is UTF-8 JSON with the following stable vocabulary:

- `fixture_version: 1`, `id` (unique `category/name`), `contracts` (KAD identifiers), `description`, `cwd` (sandbox-relative, default `project`), optional `requires`.
- `setup` is a sequence of declarative filesystem operations. Versioned input files are copied first. Permitted operations: `mkdir`, `symlink`, `hardlink`, `chmod`, `write_bytes` (base64), `generate_file`, `generate_family`. No executable shell commands or custom scripts in manifests.
- `action` is **semantic**, with `op` from `scan`, `validate`, `resolve_config`, `add`, `set`, `delete`, `link`, `repair_id`, `plan_patch`; optional `project`, `tasks_root`, `exclude`, `limits`, `params`. An action is not literal CLI syntax: KAD-011 and later integration tests will bind it to the domain API or CLI without changing expectations.
- `expect.result` is one of `ok`, `diagnostic`, `refused`, `scan_incomplete`, `unsupported_schema`, `config_error`. `expect.scan_complete` is a boolean where asserted; `expect.documents` names recognized document paths, classifications (`valid`, `invalid_candidate`, `unsupported_schema`, `non_task`) and stable IDs where safe; `expect.diagnostics` is a list of semantic categories with optional path, field or target ID. `expect.readiness` contains ID/result pairs (`ready`, `blocked`, `unresolved`).
- `expect.no_writes: true` requires identical sandbox bytes and path existence for all preexisting files, plus no new persistent operational files; use for reads, failed patch plans and refusals. `expect.goldens` maps post-action destination paths to `expected/` files with exact byte comparisons. `expect.absent` lists destinations expected absent; `expect.next_id` optionally checks generated-ID allocation.

An omitted expectation is **not an assertion**. Expected diagnostics assert the listed conditions; additional independent diagnostics may be allowed only when the manifest sets `allow_additional_diagnostics: true` with an explicit reason. Deterministic semantic ordering is checked where the scenario declares `ordered_diagnostics`; exact serialized diagnostic codes and offsets are separate tests after KAD-016/KAD-050/KAD-051.

The `index.json` IDs are unique and refer to existing manifest paths; every discovered manifest must be indexed exactly once. Scenario IDs and manifest shape are versioned; changing a scenario's meaning requires a new ID or an explicit reviewed contract change. Goldens are immutable expectations, not outputs generated by the Kadai implementation under test.

## 4. Deterministic generation

A `generate_file` operation has `path`, `kind`, and kind-specific parameters:

- `task_source_bytes`: exact total source length in bytes, with a valid short UTF-8 frontmatter and deterministic ASCII Markdown padding.
- `yaml_header_bytes`: exact header byte count, including the YAML bytes between delimiters but **excluding** opening/closing delimiter line bytes.
- `yaml_node_count`: exact parser node count, including mapping keys, root and collection nodes.
- `yaml_depth`: exact root-inclusive nesting depth.
- `regular_file`: exact byte length and repeatable byte pattern.

A `generate_family` operation has `kind` from `entries`, `markdown_candidates`, `yaml_bytes_total`, `yaml_nodes_total` and a desired `count` or `total`. Generated names and task IDs are stable, ASCII, collision-free and ordered by numeric index. Each generated document must also respect **all unrelated per-document limits** unless the fixture expressly tests those limits. For the aggregate YAML kinds, distribute the exact target across as few documents as possible without exceeding the per-document default, reserving a valid minimum-size last document; do not turn the target-boundary test into a different per-file or node-limit error.

Generators must verify their own output size/count before invoking Kadai. Manifest `assert_generated` records exact byte/node/entry expectations; runtimes may additionally record SHA-256 of generated bytes for repeatability. Generators must be deterministic across OSes, using literal UTF-8, LF and fixed ASCII filler unless the case explicitly requests CRLF. No random seeds, clock values, locale, environment-dependent encodings or platform newline conversion. A generator failure is an **invalid fixture**, not a passing Kadai diagnostic.

Heavy cases are a separate opt-in `tier: heavy`; the full suite includes them. `tier: normal` runs by default. Tests with huge generated trees or limits must clean up sandboxes reliably and never create output under the working repository.

### Budget acceptance

Every KAD-006 resource dimension is covered at **default equal**, **default plus one**, **raised within hard ceiling** and **hard ceiling plus one override rejected before scanning**:

| Dimension | Default | Ceiling |
| --- | ---: | ---: |
| `task_source_bytes` | 16 MiB | 256 MiB |
| `yaml_document_bytes` | 256 KiB | 4 MiB |
| `yaml_nodes_document` | 10,000 | 100,000 |
| `yaml_depth` | 32 | 128 |
| `filesystem_entries` | 250,000 | 2,000,000 |
| `markdown_candidates` | 50,000 | 500,000 |
| `scan_yaml_bytes` | 256 MiB | 2 GiB |
| `scan_yaml_nodes` | 1,000,000 | 10,000,000 |

The declared default/equal boundary **passes**, default+1 gives `scan_incomplete` for collection totals or a file-level diagnostic for per-document limits, an in-ceiling limit override permits the intended case, and hard-ceiling+1 is rejected **before file access**. Unit names refer to bytes/nodes/counts, never human-readable rounded text.

## 5. Coverage requirements

The index groups tests for:

- Task recognition: valid, ordinary non-task, malformed candidate, unsupported schema, quoted/commented/nested/duplicated marker, missing delimiter, invalid UTF-8, BOM, Unicode, empty body, mixed CRLF/LF.
- Schema/typing: known fields, null/absence/empty lists, custom YAML 1.2 Core numbers including very large integers and non-finite floats, leading zeros and numeric-looking known strings, duplicate keys, unknown keys, anchors/tags/directives/multi-doc, malformed YAML, invalid dates, scalar/sequence/map types.
- Source edits: scalar replacement, insertion, removal, flow/block sequence changes, comments, end-of-file and body bytes, successful expected goldens, unsafe spans and unrelated-field edits refused, directed invalid-field repair.
- Identity/history: prefix high-water, manual IDs, non-reuse after deletion, case-insensitive duplicate quarantine, ambiguous inbound references, marker validation, collision with non-task filename, path independence, interrupted reservation/repair state.
- Graphs: roots independent of folder nesting, separate hierarchy/prerequisite cycles, independent mixed cycles, unresolved ahead of blocked, direct `done` readiness, invalid/unsupported/missing targets, statuses and deletion safety.
- Project discovery: exact CWD, explicit project, config/no-config, CLI root and glob overrides, nested `.git` and `.kadai.yaml`, mandatory exclusions, symlinks including roots and task-discovery boundaries, `.gitignore` ignored, nested and overlapping collections.
- Limits: all eight budget dimensions, incomplete scan/no partial reads, deterministic traversal, valid overrides and no implicit persistent state from reads.

**Deferred to implementation-specific tests**: native lock contention, transactional journals, atomic rename and fsync, ACL/xattr portability, real crash injection, compiler/runtime integration, final JSON/terminal serialization. KAD-007 declares semantic fixtures for refusal/recovery where useful but does not claim these behaviors were executed on any OS.

## 6. Acceptance and downstream ownership

KAD-007 is complete when corpus files and manifests are checked in, index consistency and literal golden bytes have been reviewed, all acceptance categories above are represented, and no runtime/CLI implementation is claimed. KAD-011 will implement the fixture setup and runner in the Odin test environment; KAD-013 through KAD-030 and KAD-039 through KAD-054 bind relevant scenarios to actual parsers, filesystem operations and CLI integration. Golden-output snapshots must be reviewed by humans; they may never be silently refreshed from Kadai's observed output.

A failing fixture is not justification for weakening a previously accepted semantic contract. Updates must cite the owning KAD spec and preserve non-destructive behavior. No `.gitignore` or Git tracking policy is created or changed by the corpus.
