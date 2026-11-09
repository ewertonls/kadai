# Odin package boundaries

Each directory under `src/` is an independent Odin package. The CLI calls `app` for queries and mutations. A future UI can call the same operations. Arguments, terminal output, JSON rendering, and exit codes belong to `cli`.

## Package responsibilities

The last column lists allowed direct imports within Kadai. Add an import when an implementation needs it.

| Package | Responsibility | May import |
| --- | --- | --- |
| `cli` | Translate arguments into operations and present their results | `app` |
| `app` | Own the application version and coordinate queries and mutations, including the lock scope across discovery, validation, and persistence | `project`, `task`, `document`, `storage`, and eventually `graph`, `identity` |
| `task` | Define task fields, status rules, ID syntax, and single-task validation in memory | None |
| `document` | Locate Markdown frontmatter and body, decode task fields, and patch supported fields while preserving unrelated bytes | `yaml`, `task` |
| `yaml` | Own YAML parsing, events, and source spans for both project config and task documents. See the [KAD-013 parser comparison](yaml-parser.md). | None |
| `project` | Resolve config and roots, discover documents, and build the transient collection index | `yaml`, `storage`, `document`, `task` |
| `storage` | Handle physical path safety, file I/O, locks, atomic replacement, and recovery using paths and bytes | None |

Two additional boundaries are defined now. Create their directories when the corresponding contracts are first implemented.

| Future package | Responsibility | May import |
| --- | --- | --- |
| `graph` | Resolve references, check hierarchy and dependency cycles separately, and derive readiness from in-memory collection data | `task` |
| `identity` | Allocate IDs, maintain durable used-ID markers, and plan reference-aware repairs. The application coordinates applying a repair across files. | `task`, `storage` |

For a status change, `cli` passes the ID and requested status to `app`. The operation uses `storage` for coordination, `project` to find the current task, and `task` and `graph` to validate the change. Then `document` prepares the edited bytes and `storage` persists them under the same coordination. Only `cli` chooses how to present the result.

## Imports and checks

Use the `kadai` collection rooted at `src/`, for example `import "kadai:task"` inside `app`. The entrypoint in `cmd/kadai/main.odin` passes arguments and output streams to `cli.run` and uses its return value as the process exit code. See the [native development workflow](toolchain.md#native-development-workflow) for package checks, tests, and the CLI build command.

Place product tests in `*_test.odin` files beside the implementation, with the same package declaration, `#+test` at the top of the file, and `@(test)` on each test procedure. This gives tests access to package-private declarations. Declarations marked `@(private="file")` are visible only within their defining file.

`tests/fixtures/v1/` holds shared inputs and expectations. `tests/fixture_runner/` provides reusable fixture helpers and keeps its own tests beside those helpers.
