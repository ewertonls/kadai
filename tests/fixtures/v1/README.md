# KAD-007 fixture corpus v1

**Status:** The Odin integration test uses `recognition/crlf-bom` to check catalog selection and byte-preserving sandbox preparation. Product actions, including this fixture's `scan`, await their implementations. Run the unit and integration checks from the repository root using the [native test commands](../../../docs/development/toolchain.md#run-tests).

Owner: [KAD-007](../../../docs/specs/KAD-007-fixture-corpus-v1.md). All test implementation follows [Section 7: minimum necessary tests](../../../docs/specs/KAD-007-fixture-corpus-v1.md#7-agent-rule-minimum-necessary-tests). KAD-002 through KAD-006 own product semantics.

## Catalog, not a test quota

`index.json` catalogs 192 scenarios: 21 recognition, 30 YAML, 40 config, 13 identity, 25 graph, 25 patch and 38 limit examples. This is not a requirement to build 192 tests, run each as CLI integration, or implement a generic manifest interpreter. Choose the smallest set of table-driven tests that covers distinct requirements and data-loss risks. Do not use catalog count as evidence of correctness.

The historical production-sized limit recipes are optional reference data. Test actual counter boundaries with small invocation overrides instead. `normal` and `heavy` describe cost, not mandatory coverage. No scheduled heavy suite or performance harness is required without a concrete need.

## Layout

```text
index.json
schema.json
cases/<category>/<name>/
  manifest.json
  input/project/...
  expected/...              # only when exact bytes are asserted
```

A selected scenario runs in a fresh sandbox. Copy literal inputs byte-for-byte, then apply declared setup. Never mutate the checked-in fixture files. The repository's `.gitattributes` prevents text conversion for `input/` and `expected/`; do not normalize CRLF, BOM, Unicode or final newlines.

Setup paths and `cwd` are sandbox-relative. `action.project` resolves against `cwd`; relative task roots resolve against the selected project. Expected document/diagnostic paths and action file parameters are selected-project-relative. Golden references are scenario-relative. Link targets are relative to the link's parent and must stay inside the sandbox even when testing escape from the selected project.

## Small execution adapter

1. Validate selected manifests against `schema.json` or equivalent ordinary structural checks. Separately verify index membership, unique IDs and existing paths. `schema.json` validates **manifests**, not the index itself. Unknown selected operations/assertions must fail instead of silently disappearing.
2. Create an isolated sandbox, copy literal inputs without transformations and apply only the setup operations needed by those tests. Verify physical containment without following links during inventory/cleanup.
3. Build small generated inputs when necessary. Check claimed sizes/counts independently of the product counter. No universal generator framework or per-run inventory of every possible large recipe is required.
4. Bind one semantic action to the relevant domain/API or CLI implementation. `plan_patch` returns proposed bytes without persistence. Implement adapters incrementally, only as the selected product behavior exists.
5. Compare the explicit semantic expectations and preservation invariants. Check committed outputs for mutations, not merely a reported ID or success value. Use goldens only for byte-level contracts.
6. Clean up the sandbox. Report actual pass/failure, unimplemented selected behavior or `unsupported_host` with a reason separately. An unselected reference example is not a passing test; missing product code is not a host-capability skip.

Native mechanisms must run on a capable supported platform when they are release requirements. Pure schema/graph cases do not need a duplicated platform-specific corpus.

## Expectation rules

KAD-007 Section 3 is authoritative. In particular:

- `documents` and present selection/root/history sets are exact unordered sets. `readiness` and keyed `fields` assert the listed tasks. Sequence-valued fields preserve order. `fields` always maps **task ID -> field/value map**, including single-task cases.
- Diagnostic category/path/field conditions are required matches, not final public error codes. Additional independent diagnostics are allowed for negative cases unless explicitly disallowed. `ordered_diagnostics` is an exact ordered sequence. `ok` prohibits unexpected errors.
- `proposed_goldens` compares read-only patch output; `goldens` compares committed files. Neither is automatically regenerated from the implementation.
- `safe_patch_or_refusal` applies only to optional `plan_patch` layouts. A refusal leaves source/state unchanged and matches its declared refusal diagnostic. A success must make the requested change and preserve every unrelated byte/comment. Mandatory simple patches cannot use this allowance.
- `no_writes` is strict for reads and planners. A preflight-refused mutating command may create only documented stable lock infrastructure, never history or recovery records. Persistence failures and post-commit output failures have different allowed effects under KAD-006 Section 6; do not label them effect-free refusals.
- Paths, file types, link targets and contents are part of no-write checks; access timestamps caused by reading are not. No blanket exemption for `.kadai/`, and no deleting/recreating live locks to satisfy a test.

## Generation and ownership

KAD-007 Section 4 defines the small deterministic builders and optional legacy recipes. Use explicit UTF-8/LF, stable indexed names and fixed contents. Aggregate cases must stay within unrelated **effective invocation** caps. A builder/count mismatch is a fixture error, not a successful product rejection.

KAD-011 owns the minimal setup/runner. Parser and storage tasks own the necessary implementation tests, including actual locks, atomic replacement and safe recovery. Graph/domain tasks own table-driven semantics. CLI tasks add only behavior specific to command parsing/output and one representative end-to-end workflow. Do not implement each catalog entry again in every layer.

Kadai never manages user Git tracking. The development repository's raw-byte fixture attributes do not change that rule. Preserve the underlying contracts; remove redundant testing work rather than weakening safety.
