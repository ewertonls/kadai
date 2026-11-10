# Local filesystem operations

Explicit project, config and collection selections resolve to physical paths. Recursive discovery skips links. Task mutations accept regular files with exactly one hard link. Directory components must remain real directories. Case and normalization follow the filesystem when resolving existing selections. Glob matching uses case-sensitive Unicode scalar values.

On macOS and Linux, storage walks from an open root directory with `openat(O_DIRECTORY | O_NOFOLLOW)`. Creation and publication use descriptor-relative system calls. On Windows, storage pins drive-letter path components using directory handles, rejects reparse points, and denies write and delete sharing on the pinned directories. Unsupported path forms fail closed.

First-time publication stages a complete file in its destination directory, syncs the file, then publishes with a native no-replace rename. POSIX also syncs the parent directory. Windows uses a write-through move. An occupied destination, including a link or ordinary Markdown file, prevents publication.


Replacement and deletion require an independent pre-write image in a private recovery directory. Kadai retains that image after rollback. A replacement and its rollback image have distinct, pre-recorded file identities. Each step checks the expected device, inode or Windows file ID, SHA-256 and security metadata before changing a name. A crash between rename and directory sync can be retried by checking the recorded post-image and syncing again.

On macOS, descriptor-based metadata copying preserves ownership, permissions, ACL and extended attributes. Kadai compares these values and BSD flags on the staged file. Linux copies ownership, mode and extended attributes, including POSIX ACLs, and verifies the resulting set. Unsupported metadata or failed verification stops publication. POSIX recovery directories require owner-only permissions and no extended ACL.

On Windows, new files use a protected owner-rights DACL. Recovery directories require the protected owner-only inheritable DACL. Replacement supports regular files whose security descriptor and backup security stream match the staged file. Alternate streams, extended attributes, unsupported file attributes and differing security descriptors cause refusal. This includes externally created files with an ACL that the staged file cannot reproduce.

Transaction images and their destinations must support same-filesystem rename. Kadai refuses a change across mount points. Staging or sync failures after persistence starts can retain recovery material. Automatic pruning is deferred.
