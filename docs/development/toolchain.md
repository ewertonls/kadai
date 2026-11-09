# Odin toolchain

> KAD-008. This is an **advisory reference**, not an enforced compiler-version requirement.

## Reference release

- **Tag:** [`dev-2026-11a`](https://github.com/odin-lang/Odin/releases/tag/dev-2026-11a)
- **Commit:** [`9a6991685ddf663956d9836602eb421e141fc443`](https://github.com/odin-lang/Odin/commit/9a6991685ddf663956d9836602eb421e141fc443)
- **Published:** 2026-11-03.
- **Upstream note:** Hotfix to `dev-2026-11` correcting a BNG/LZ4 enum clash.

This is the recommended compiler for contributors and the future CI baseline. Contributors may use other Odin versions. Compatibility with those versions is unverified.

## Official artifacts

| Host | Download | SHA-256 |
| --- | --- | --- |
| macOS ARM64 | [`odin-macos-arm64-dev-2026-11a.tar.gz`](https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/odin-macos-arm64-dev-2026-11a.tar.gz) | `fa10eee280c8786758e3ff0b8fdd9355e1c9447b1f0b8c72764e25ee4ebc3e22` |
| Linux AMD64 | [`odin-linux-amd64-dev-2026-11a.tar.gz`](https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/odin-linux-amd64-dev-2026-11a.tar.gz) | `65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618` |
| Linux ARM64 | [`odin-linux-arm64-dev-2026-11a.tar.gz`](https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/odin-linux-arm64-dev-2026-11a.tar.gz) | `5bdba22447ea46a99765235e401c2ad83930f967f987aab1531ed76c3aa7ea3b` |
| Windows AMD64 | [`odin-windows-amd64-dev-2026-11a.zip`](https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/odin-windows-amd64-dev-2026-11a.zip) | `259effedf2997293c8fa4a5e497496f8ebce9f826652d9dd353a9dd2113c31fd` |

These SHA-256 values are from the official release's GitHub asset metadata.

## Installation

1. Install host prerequisites:
   - **macOS:** Xcode Command Line Tools (`xcode-select --install`).
   - **Linux:** Clang for linking (for example, `sudo apt install clang` on Debian/Ubuntu).
   - **Windows:** Visual Studio / Build Tools with **Desktop development with C++**, MSVC and Windows SDK. Use a configured developer command prompt if linking tools cannot be found.
2. Download the archive matching your OS and CPU from the table.
3. Check SHA-256 **before** extraction and compare against the table:

   macOS:
   ```sh
   shasum -a 256 odin-macos-arm64-dev-2026-11a.tar.gz
   ```

   Linux (use the ARM64 filename when applicable):
   ```sh
   sha256sum odin-linux-amd64-dev-2026-11a.tar.gz
   ```

   Windows PowerShell:
   ```powershell
   Get-FileHash .\odin-windows-amd64-dev-2026-11a.zip -Algorithm SHA256
   ```

4. Extract the archive to a persistent directory. Keep the Odin executable next to its `base/`, `core/`, and `vendor/` directories. Do not move only the executable without configuring `ODIN_ROOT`.
5. Add the directory **containing** `odin` (`odin.exe` on Windows) to `PATH`. For the current Unix shell:

   ```sh
   export PATH="/absolute/path/to/extracted/Odin:$PATH"
   ```

   For the current PowerShell session:

   ```powershell
   $env:Path = "C:\path\to\extracted\Odin;$env:Path"
   ```

   Persist the setting in your shell profile or Windows environment variables.
6. Verify availability with `odin version`. Compare the reported version/revision against this document. If the displayed version is less precise than the release tag, the verified archive hash identifies the exact prebuilt asset.

**macOS Intel:** This release does not provide a macOS AMD64 binary. Build from the reference commit following the [official source-build instructions](https://odin-lang.org/docs/install/#macos), including LLVM and Git LFS requirements.

**macOS quarantine:** Unsigned downloads may be blocked by macOS. Consult [Odin's release notes](https://odin-lang.org/docs/install/#release-requirements-notes) for its targeted quarantine-removal command, after verifying the SHA-256.

## Ownership and update policy

- The reference is **advisory**, not a minimum supported version or compatibility gate.
- When changing the baseline, update the tag, commit, links and SHA-256 values together.
- Contributors manage their own compiler installation. If tooling detects a version mismatch, it may warn and continue.

Upstream: [official Odin installation guide](https://odin-lang.org/docs/install/).

## Native development workflow

Run these commands from the repository root. The flag `-collection:kadai=src` resolves imports such as `kadai:task` against `src/`.

### Check a package

```sh
odin check src/app -collection:kadai=src -no-entry-point -vet
```

Replace `src/app` with the package directory you are working on. Odin checks that package and its imports. Use `-no-entry-point` for library packages and `-vet` to enable vetting. A successful check exits with status 0.

### Run tests (KAD-011)

Once KAD-011 adds tests, run `odin test` on the directory containing the `@(test)` procedures. For example, to run unit tests in `src/task` or the planned fixture runner, respectively:

```sh
odin test src/task -collection:kadai=src
odin test tests/fixture_runner -collection:kadai=src
```

Each invocation runs tests in the selected package. The fixture runner will read the corpus in `tests/fixtures/v1/`.

### Build the CLI (KAD-012)

Once KAD-012 adds the executable entrypoint in `cmd/kadai/`, build it with:

```sh
odin build cmd/kadai -collection:kadai=src
```
