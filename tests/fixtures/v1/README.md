# KAD-007 fixture corpus v1

**Status:** Declarative test inputs and expected behavior. The Odin fixture runner and Kadai CLI do not exist yet. The corpus is data, not proof that any behavior has passed.

Owner contract: [KAD-007](../../../docs/specs/KAD-007-fixture-corpus-v1.md). Underlying semantics: KAD-002 through KAD-006.

## Inventory

The checked-in `index.json` enumerates **192 independent scenarios**:

| Group | Cases | Main concern |
| --- | ---: | --- |
| Recognition | 21 | Discriminator, malformed/partial tasks, BOM, Unicode, encoding |
| YAML | 30 | Schema, scalar typing, unsupported constructs, invalid source |
| Config | 40 | CWD, overrides, exclusions, symlinks, nested collections |
| Identity | 13 | Used-ID records, allocation, collisions, repair |
| Graph | 25 | Parents, prerequisites, cycles, readiness, deletion |
| Patch | 25 | Byte-exact proposed output, directed repair, unsafe refusals |
| Limits | 38 | All eight KAD-006 budgets, ceilings and incomplete scans |

## Directory convention

```text
index.json
schema.json
cases/
  recognition/basic/
    manifest.json
    input/project/tasks/KAD-1.md
  patch/scalar-status-comment/
    manifest.json
    input/project/tasks/T.md
    expected/T.md
  limits/scan_yaml_bytes_default_plus_one/
    manifest.json        # heavyweight input is generated, not stored
```

Each manifest has a unique `category/name` ID and a sandbox-local `cwd`, default `project`. Each input path is prefixed by `input/`; runtime paths in expectations and semantic action parameters are relative to the **selected physical project** unless the contract explicitly calls for the sandbox root. A relative `action.project` is resolved against the scenario CWD. The runner translates result paths from its public API to this project-relative form for comparisons, rather than asserting a future CLI output path convention.

Input files are copied as bytes into a **fresh, empty, unique sandbox** per scenario. No fixtures share mutable state. Do not run commands against the versioned `input/` files.

## Runner execution order (KAD-011)

1. Validate `index.json` against `schema.json` for each manifest. Enumerate all manifest paths under `cases/`: reject missing, unlisted or duplicated cases. Validate relative paths and that setup cannot escape the sandbox.
2. Create a unique temporary sandbox and copy each literal `input/` file byte-for-byte, retaining BOM/CRLF/Unicode and exact final newline behavior.
3. Apply `setup` recipes in order. For `symlink` and `hardlink`, resolve relative targets only within the sandbox; never materialize an external target. Set permissions only on declared fixture nodes.
4. Generate heavy inputs deterministically from the v1 generator grammar. Before invoking Kadai, assert declared counts/sizes/depth/nodes, compute SHA-256 per generated file and a sorted-path SHA-256 inventory. Generator failure is a fixture failure, not a Kadai failure or skip.
5. Run one semantic `action` against the selected effective project/collection, or bind it to a domain-level API where a CLI grammar has not yet been decided. An `op: plan_patch` produces proposed bytes **without writing**. An `op: set` or `op: add` exercises actual writes only after those modules exist.
6. Compare `expect` semantic categories, document classes/IDs, readiness, paths, fields, warning categories and diagnostics; do not demand unstable stdout or error codes. For `proposed_goldens`, compare generated proposed bytes to `expected/` byte-for-byte. For `goldens`, compare actual committed outputs. For `no_writes`, hash and compare the entire sandbox contents and filesystem object inventory (including absence of new recovery/history), not just the task file.
7. Clean up the sandbox. Report pass, failure, or `unsupported_host` separately; print an explicit reason for every unsupported host capability. A missing capability is never counted as a successful test.

A fully completed runner must run normal tests by default and heavy tests only when explicitly selected (`tier: heavy`). CI should run the full heavy suite on scheduled/opt-in jobs once the runner exists. Execution timeouts and cleanup thresholds are implementation concerns, not permission to skip required tests silently.

## Manifest interpretation

- `action.op` is a semantic operation, **not CLI argument syntax**. KAD-047/KAD-050/KAD-051 define the eventual command grammar/output and error codes.
- `expect.result`: `ok`, `diagnostic`, `refused`, `scan_incomplete`, `unsupported_schema`, or `config_error`.
- `expect.diagnostics[].category` is descriptive and remains unmapped to the final machine codes. Fields and paths identify conditions, not frozen line/column encoding.
- `expect.documents[].classification` is `valid`, `invalid_candidate`, `unsupported_schema`, or `non_task`; only attach a usable ID where supported.
- `expect.no_writes: true` applies to source tasks, config, used-ID history, recovery files and other persistent artifacts. It is required for read-only operations and refusals.
- `expect.proposed_goldens` tests `plan_patch`'s returned candidate bytes while still forbidding writes. `expect.goldens` compares post-mutation files after actual writes. `expected/` relative paths are relative to the **scenario directory**.
- `expect.allow_additional_diagnostics` is false by default. Declared diagnostic categories must match by path/field where given; error presentation/codes are not fixed.
- `assert_generated` checks the intended measured budget dimension before running any Kadai code. The generator also checks that other limits stay below their defaults, avoiding accidentally testing a different limit.
- `action.limits` values are invocation-only overrides; invalid overrides are rejected before filesystem inspection. Incomplete scans must not expose normal partial query results.
- `requires` is a capability prerequisite list, not an OS name filter. A host without symlink support may mark just those scenarios `unsupported_host`, not all filesystem tests.

## Generator v1 contract

Generation must be independent of OS, clock, locale, filesystem enumeration order and random numbers. Use UTF-8, LF and fixed ASCII filler unless the recipe explicitly requests otherwise. Generated names are stable lexically ordered numeric sequences, with distinct IDs. File sizes count **raw bytes**, not decoded characters, and YAML node/depth counters follow KAD-006.

- `task_source_bytes`: valid minimal task frontmatter followed by deterministic ASCII body padding to exact **total source bytes**.
- `yaml_header_bytes`: valid minimal task with one plain `custom.padding` scalar padded with ASCII `x` to the requested byte length **between** frontmatter delimiter lines.
- `yaml_node_count`: valid task with `custom.items` containing sufficient one-scalar elements to make an exact event/node count, including mapping keys and collections.
- `yaml_depth`: valid task with a single nested `custom` chain, root mapping depth 1.
- `regular_file`: exact byte count; use optional `prefix` followed by repeating `repeat_byte` (default `x`).
- `entries`: create `count` unique non-task files beneath the effective root; include every file/directory/link visited under the KAD-006 counting model; no extra nested directories.
- `markdown_candidates`: create exactly `count` ordinary .md files with no opening frontmatter delimiter.
- `yaml_bytes_total`: create deterministic task files whose summed YAML header bytes equal `total`; no single header exceeds 256 KiB by default, and collection files/nodes remain under unrelated defaults.
- `yaml_nodes_total`: create deterministic task files whose YAML node counts sum to `total`; individual documents remain at or below 10,000 nodes and 256 KiB unless overridden for the specific dimension.

For family generators, distribute target counts/totals in descending maximum-sized documents and then a smaller final document, adjusting the last two documents if the remainder would be below the smallest valid task. Do not use random content, arbitrary parser-dependent extra nodes or OS-specific line endings. A separate KAD-011 implementation must make this grammar executable and record its canonical generated SHA-256 inventory. No heavy/generated case is claimed executed in KAD-007.

## Coverage ownership

The corpus gives KAD-011 concrete expectations for setup, parser and cross-platform tests. Actual parser/writer/security/lock tests belong to KAD-013 through KAD-030, graph behavior to KAD-039 through KAD-046, and CLI JSON/diagnostics to KAD-047 through KAD-054.

Do not generate or edit `.gitignore`. Tests do not require Git-tracked user task files. Keep checked-in inputs and goldens immutable; never auto-regenerate expected files from outputs under test.
