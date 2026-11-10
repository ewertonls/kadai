# Local filesystem operations

Explicit project, config and collection selections resolve to physical paths. Recursive discovery skips links. Task mutations accept regular files with exactly one hard link. Directory components must remain real directories. Case and normalization follow the filesystem when resolving existing selections. Glob matching uses case-sensitive Unicode scalar values.

On macOS and Linux, storage walks from an open root directory with `openat(O_DIRECTORY | O_NOFOLLOW)`. Creation and publication use descriptor-relative system calls. On Windows, storage pins drive-letter path components using directory handles, rejects reparse points, and denies write and delete sharing on the pinned directories. Unsupported path forms fail closed.

First-time publication stages a complete file in its destination directory, syncs the file, then publishes with a native no-replace rename. POSIX also syncs the parent directory. Windows uses a write-through move. An occupied destination, including a link or ordinary Markdown file, prevents publication.


Replacement and deletion require an independent pre-write image in a private recovery directory. Kadai retains that image after rollback. A replacement and its rollback image have distinct, pre-recorded file identities. Each step checks the expected device, inode or Windows file ID, SHA-256 and security metadata before changing a name. A crash between rename and directory sync can be retried by checking the recorded post-image and syncing again.

On macOS, descriptor-based metadata copying preserves ownership, permissions, ACL and extended attributes. Kadai compares these values and BSD flags on the staged file. Linux copies ownership, mode and extended attributes, including POSIX ACLs, and verifies the resulting set. Unsupported metadata or failed verification stops publication. POSIX recovery directories require owner-only permissions and no extended ACL.

On Windows, new files use a protected owner-rights DACL. Recovery directories require the protected owner-only inheritable DACL. Replacement supports regular files whose security descriptor and backup security stream match the staged file. Alternate streams, extended attributes, unsupported file attributes and differing security descriptors cause refusal. This includes externally created files with an ACL that the staged file cannot reproduce.

Transaction images and their destinations must support same-filesystem rename. Kadai refuses a change across mount points. Staging or sync failures after persistence starts can retain recovery material. Automatic pruning is deferred.


## Coordination and restart

`app.mutate_collection` acquires the native writer-domain lock before loading config and holds it while its planner scans, validates, and commits. POSIX uses an exclusive `flock` on the namespace root directory. Windows uses a global named mutex and a process mutex to prevent recursive acquisition. Domain acquisition times out after two seconds. Each writer then locks the collection's stable `.kadai/writer.lock` with `flock` or `LockFileEx`. Process exit releases the handles. Init uses the domain lock and creates no collection lock file.

This serializes decisions across overlapping collections in the same local OS namespace, including decisions about different task files. The cost is that unrelated writers may also wait. Network filesystems, independent mount namespaces and independent clones are outside the coordination boundary. External editors can change a source after its final check and before rename. Readers can observe individual steps of a multi-file operation.

Before publishing a change, storage syncs an immutable plan under `.kadai/recovery/<operation-id>/`. Two intent records point to its ID and SHA-256. Either surviving record blocks a new mutation. Writers check ancestors and descendant collection roots for intent, including descendants excluded from task discovery. A missing, conflicting or oversized required record causes refusal. A preparation failure before intent publication can leave unused private images. After publication, a failure may leave some changes applied.

`app.recover_collection` resumes or rolls back an interrupted operation under the same locks. It validates the plan and verifies each affected path before proceeding, then rechecks each step as it runs. Rollback proceeds in reverse and records its direction durably. A later edit, a recreated destination or a corrupt snapshot stops recovery. Successful completion records a synced receipt before clearing intent. An explicit rollback of a committed operation requires its ID, receipt and matching on-disk state.


A directory move uses one no-replace rename. The journal records the tree's relative paths, file identities, byte hashes and security metadata, including ordinary files and empty directories. Preparation saves individual pre-move file images. Resume and rollback verify the tree at the expected source or destination and refuse to move a tree containing a later edit. Nested repositories, operational state, excluded paths, links, special files, and trees beyond the invocation budgets are ineligible.

Directory moves also record a checksum of the sorted recovery image names and file versions. This lets `validate` detect a missing or altered image after the live tree changes. Earlier directory journals used only a checksum based on the original relative paths. Validation reports an incomplete recovery check if those paths can no longer be reconstructed from the source or destination.
