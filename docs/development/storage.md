# Local filesystem operations

Explicit project, config and collection selections resolve to physical paths. Recursive discovery skips links. Task mutations accept regular files with exactly one hard link. Directory components must remain real directories. Case and normalization follow the filesystem when resolving existing selections. Glob matching uses case-sensitive Unicode scalar values.

On macOS and Linux, storage walks from an open root directory with `openat(O_DIRECTORY | O_NOFOLLOW)`. Creation and publication use descriptor-relative system calls. On Windows, storage pins drive-letter path components using directory handles, rejects reparse points, and denies write and delete sharing on the pinned directories. Unsupported path forms fail closed.

First-time publication stages a complete file in its destination directory, syncs the file, then publishes with a native no-replace rename. POSIX also syncs the parent directory. Windows uses a write-through move. An occupied destination, including a link or ordinary Markdown file, prevents publication.
