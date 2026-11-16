# Windows 11 native storage validation

KAD-085 was run on 2026-11-14, brought forward from its post-phase 6 slot while the Windows PC was available. KAD-053, KAD-054 and release publication remain separate work.

## Tested revision and environment

- Base commit: `1bd43f11f9153a408d73c58b132a3141b583c337`.
- Passing revision: `1cf3b3d8078727e708816e131c1f7796f3e08d22` (`fix(storage): validate private Windows snapshots (KAD-085)`). Its source and test tree passed the checks before commit; this record is a separate documentation commit.
- Windows 11 Pro 25H2, AMD64, build `10.0.26200.9711`; local NTFS on `C:`.
- Odin: `dev-2026-11-nightly:9a69916`, matching the advisory reference revision.
- Static LibYAML (`-define:YAML_STATIC=true`). Tests ran outside the Codex filesystem sandbox, which denied operations using the protected owner-only ACLs. No privileges are enabled by the implementation.

The unmodified base failed 21 of 71 tests natively. Failures included `SHARING_VIOLATION`, `NOACCESS`, and a fixture identity assertion that used Windows `lstat` results without file IDs.

## Fixes verified

1. Directory handles denied write sharing, conflicting with the destination-directory open performed by rename. Allowing write sharing alone permits junction redirection. Windows storage now opens and creates child components relative to directory handles, rechecks reparse attributes, and renames/deletes using handles. Delete sharing remains denied on directories.
2. The temporary byte allocator did not guarantee DWORD alignment for `GetKernelObjectSecurity`, causing `NOACCESS`. Security descriptor and backup stream buffers now have the required alignment and bounded sizes.
3. Editor-created files have inherited DACLs that differ from Kadai's new private files. Staging copies compatible backup security streams with `BackupWrite` and verifies the resulting descriptor and stream before publication; it still refuses metadata it cannot preserve.
4. Review found that copying an Everyone-read ACL made the snapshots readable despite the private recovery directory. Storage now validates the source descriptor and the actual captured descriptor before `BackupWrite`, then validates readback. Trusted owners and allow trustees are the current process user, LocalSystem and Builtin Administrators; OWNER RIGHTS requires a trusted owner. Conventional denies remain supported. Missing/null DACLs, untrusted owners/grants, malformed descriptors and unsupported ACE types are refused. Private recovery directories also require a trusted owner. This policy applies to file and tree snapshots and to existing recovery images without journal migration or permission repair.
5. The fixture independence check now obtains file identity from open handles, using the same volume/file ID representation as storage.

The native API choices follow Microsoft's [relative `NtCreateFile` contract](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile), [rename information contract](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information), and [`BackupWrite` security access requirements](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-backupwrite).

## Executed checks

```sh
odin test src/storage -collection:kadai=src
odin test tests -all-packages -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=true
odin check src/app -collection:kadai=src -collection:third_party=third_party -no-entry-point -vet
odin build cmd/kadai -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=true
```

All seven Windows storage tests and all 75 tests in the full suite passed. Static analysis, the CLI build and `git diff --check` also passed.

| Risk | Native evidence |
| --- | --- |
| Replacement or rollback loses security metadata | The atomic replacement test uses an editor-style save with a compatible inherited DACL, checks privacy and matching metadata on the original/restore/next images, compares metadata after replacement, and verifies rollback bytes and metadata. Existing creation and mutation tests cover Kadai's protected DACL. |
| Copied ACL discloses recovery contents | Native files with Everyone-read or null DACLs are refused before snapshot creation; bytes and ACLs remain intact. A distinct tree-capture test refuses a public member without copying it. |
| The descriptor changes between inspection and capture | A deterministic test passes captured security streams directly to the write gate. Public/null/missing DACLs, an untrusted owner with OWNER RIGHTS, and an object ACE are refused without changing the destination. Trusted inherited grants and conventional denies pass validation; a truncated descriptor fails. |
| Unsupported metadata is silently discarded | Windows test refuses replacement of a file with an alternate data stream and a file with the hidden attribute; original bytes and the unsupported metadata remain intact. |
| Directory redirection escapes the selected root | A pinned directory cannot be renamed. A real NTFS junction installed after the handle opens causes child creation, traversal and publication to be refused without modifying the target directory. |
| Occupied destinations or hardlinks are overwritten | Existing storage test exercises no-replace publication and single-link mutation checks. |
| A competing writer bypasses native coordination | A separate test process cannot acquire the writer domain while held by the parent. |
| Interruption corrupts recovery or loses a later edit | The child process exits after the first publication without cleanup. The parent exercises resume, and a second interrupted operation exercises rollback. A later edit blocks rollback and retains its bytes; restoring the recorded post-image allows rollback to finish and clear intent. |

A PowerShell smoke run used the rebuilt `kadai.exe` in an isolated project under the user's temporary directory: `init` twice (config hash unchanged), `add` with a UTF-8 title and a path containing spaces/accents, editor-style file replacement, `status`, `move`, `validate`, `remove --yes`, `recover rollback --yes`, `validate`, and `list --json`. All workflow commands returned 0; the restored task retained the manual title, new path and status. Native ACL inspection of six retained/staged images found only trusted owners and grants.

The same smoke run then gave an archived original snapshot Everyone-read access: rollback refused it, validation reported incomplete recovery verification, and the archive's bytes/ACL and live task remained unchanged, with no intent armed. Giving the live task Everyone-read access also caused mutation to fail without changing the task or creating a recovery operation. The temporary project was removed. The repository's own ACLs were not modified; editor saves inheriting grants to other principals are intentionally outside the supported policy.

## Limits

- This run verifies process interruption, not power loss or a kernel crash. Windows flushes staged file contents but has no directory sync in this implementation; do not infer POSIX directory-durability guarantees from passing recovery tests.
- Auditing SACLs, privileged ownership changes, extended attributes and other unsupported NTFS attributes were not exercised. Alternate streams, hidden attributes and the incompatible ACL cases above are the tested refusals. Privacy-compatible descriptors are supported only when their metadata can also be reproduced exactly; this run does not establish arbitrary ACL or privileged metadata support.
- Odin's `os.symlink` is unsupported on this Windows toolchain, so existing POSIX-only symlink tests remain excluded. Native junction and hardlink checks did run.
- FAT/exFAT, ReFS, UNC/network paths, cross-volume operations, dynamic LibYAML, and native macOS/Linux execution were not tested in this run. This does not complete KAD-054's cross-platform matrix.
