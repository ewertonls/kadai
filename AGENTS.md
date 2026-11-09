# Kadai

Run the full test suite from the repository root:

```sh
odin test tests -all-packages -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=true
```

When a new package gains tests, import it in [tests/all.odin](tests/all.odin) so `-all-packages` includes it.

## Test rules

Apply [KAD-007 §7](docs/specs/KAD-007-fixture-corpus-v1.md#7-agent-rule-minimum-necessary-tests) to every task.

1. Add tests only for an uncovered requirement, a distinct failure mechanism or a concrete regression. Check existing coverage first and extend an assertion or table when sufficient. Name the risk briefly in the task or PR.
2. Test observable behavior at the lowest level that proves it. Repeat a scenario at another layer only for a different risk. Use real storage and concurrency when mocks cannot prove safety.
3. Use small, deterministic inputs and limit overrides for `N` and `N+1`. Add load or stress tests only for a demonstrated scaling risk or an explicit maintainer request.
4. Test Kadai’s YAML policy and integration. Avoid generic test frameworks, unused fixture operations, elaborate mocks, combinatorial matrices, count or coverage targets, and duplication of upstream conformance tests.
5. Reserve golden files for exact-byte contracts. Assert stable semantics and specific bytes that must survive an edit. Avoid broad snapshots of output, internals or repositories.
6. Preserve checks for data loss, allocation and history integrity, discovery boundaries, conflicting writers and recovery. Remove redundant scaffolding without losing coverage of those risks.
7. Resolve disagreements among the governing contract, fixture and implementation before changing an expectation. Optional layouts may gain support once their edits are safe.
8. Stop when the accepted behavior and distinct risks are covered. Use catalog entries as needed. Report only checks actually run, outstanding requirements and unavailable native capabilities.
