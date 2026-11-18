# KAD-054 native test coverage

## Native CI results

All three jobs passed on commit `4200448290fb35187975488da690fc89285f4c6d` on 2026-11-18 UTC. Each job verified the reference Odin archive, ran `odin check -vet`, built the CLI with static LibYAML, ran the full suite, and invoked `--help` and `--version` on the new binary. All three reported `kadai 0.1.0-dev`. [CI run 44207577562](https://github.com/ewertonls/kadai/actions/runs/44207577562)

| Check | Native runner | Full suite |
| --- | --- | --- |
| Linux x64 | Ubuntu 24.04.5, `ubuntu-24.04` | [77 tests passed](https://github.com/ewertonls/kadai/actions/runs/44207577562/job/134477379858) |
| macOS ARM64 | macOS 15.8.2, `macos-15` | [77 tests passed](https://github.com/ewertonls/kadai/actions/runs/44207577562/job/134477380227) |
| Windows x64 | Windows Server 2025, build 26100, `windows-2025` | [80 tests passed](https://github.com/ewertonls/kadai/actions/runs/44207577562/job/134477380248) |

The active `Kadai CI on main` ruleset requires these three checks from the GitHub Actions app before a PR can merge into `main`. GitHub's effective branch rules returned all three check names with integration ID `15368`. [Repository ruleset](https://github.com/ewertonls/kadai/rules/27509073) · [Effective rules for main](https://api.github.com/repos/ewertonls/kadai/rules/branches/main)

## Filesystem coverage

Each cell describes assertions exercised by the passing native suite on that host. The Windows runner used one test worker. The competing writer still ran in a separate process. [Suite entry point](../../tests/all.odin)

| Risk and executable test | Linux x64 | macOS ARM64 | Windows x64 |
| --- | --- | --- | --- |
| UTF-8 filenames and path separators — [`cli.task_command_workflow`](../../src/cli/workflow_test.odin) | Move to `work/計画.md` and check the original ID and exact path in `show` and `list` JSON. | Same move and readback on the native filesystem. | Supply `work\計画.md` to `move` and expect `work/計画.md` in both JSON results. |
| Symlinks during discovery — [`project.scan_ignores_file_and_directory_symlinks`](../../src/project/scan_test.odin) | A real file link and a directory link point to an existing task and its directory. A complete scan returns only the physical task path. | Same assertions with native symlinks. | Same assertions with [Win32 symbolic links](../../src/project/scan_windows_test.odin). A setup failure reports the Win32 error. |
| Unsafe mutation targets — [`storage.occupied_destinations_and_unsafe_links`](../../src/storage/files_test.odin) | Refuse an occupied destination, mutation through a hardlink and directory creation through a symlink. | Same filesystem checks. | Check the occupied destination and hardlink. Separately, [`windows_pinned_directory_blocks_redirection`](../../src/storage/files_windows_test.odin) installs a junction and verifies that child creation, traversal and publication are refused. |
| Permissions, ACLs and extended attributes — [`storage.atomic_replace_preserves_metadata_and_verified_rollback`](../../src/storage/atomic_test.odin) | Compare metadata after replacement and rollback with a real mode, POSIX ACL and user xattr. | Compare mode, an extended ACL and a user xattr after the same operations. [POSIX test setup](../../src/storage/xattr_test.odin) | Compare an inherited DACL on staged images and after replacement and rollback. [Windows metadata tests](../../src/storage/metadata_windows_test.odin) also exercise refusal of an alternate data stream, a hidden attribute and incompatible DACLs. |
| Competing writers and recovery — [`storage.overlapping_writers_and_interrupted_transaction`](../../src/storage/journal_test.odin) | A second process times out on the writer lock. After a child exits mid-transaction, resume completes the work. Rollback preserves a later edit and succeeds after the expected bytes are restored. | Same assertions with native locks and filesystem operations. | Same assertions with native locks and NTFS operations. |

The CLI workflow passed with and without `init`. On Windows the scanner created both a file symlink and a directory symlink. The separate junction test installed a mount-point reparse point and verified that Kadai refused writes through it.

The recovery tests cover process interruption. Power-loss durability, arbitrary NTFS extended attributes and auditing SACLs remain unverified. The Windows metadata evidence covers the supported DACLs and the specific refusal cases above. [Earlier Windows 11 validation and limits](windows-validation.md)

## Local baseline

On 2026-11-17 the five tests named in the first column and the full 77-test suite passed on Linux x64 with Odin `dev-2026-11-nightly:9a69916` and static LibYAML. The sandbox blocked setting the POSIX ACL on a temporary file. Both runs passed outside it. The tests also compiled to object files for macOS ARM64 and Windows x64.
