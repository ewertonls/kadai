# Odin toolchain

> KAD-008. This is an **advisory reference**, not an enforced compiler-version requirement.

## Reference release

- **Tag:** [`dev-2026-11a`](https://github.com/odin-lang/Odin/releases/tag/dev-2026-11a)
- **Commit:** [`9a6991685ddf663956d9836602eb421e141fc443`](https://github.com/odin-lang/Odin/commit/9a6991685ddf663956d9836602eb421e141fc443)
- **Published:** 2026-11-03.
- **Upstream note:** Hotfix to `dev-2026-11` correcting a BNG/LZ4 enum clash.

This is the recommended compiler for contributors and the pinned compiler for [CI](../../.github/workflows/ci.yml). Contributors may use other Odin versions. Compatibility with those versions is unverified.

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
- When changing the baseline, update the tag, commit, links and SHA-256 values here. Keep the version and checksums in the [shared setup action](../../.github/actions/setup-odin/action.yml) in sync.
- Contributors manage their own compiler installation. If tooling detects a version mismatch, it may warn and continue.

Upstream: [official Odin installation guide](https://odin-lang.org/docs/install/).

## Native development workflow

Run these commands from the repository root. `-collection:kadai=src` resolves imports such as `kadai:task`. `-collection:third_party=third_party` resolves the vendored bindings used by the [YAML parser probe](yaml-parser.md).

For editor support, open the repository root as the workspace. [ols.json](../../ols.json) gives the Odin Language Server (OLS) the same collections. Direct `odin` commands take the flags shown below.

### Check a package

```sh
odin check src/app -collection:kadai=src -collection:third_party=third_party -no-entry-point -vet
```

Replace `src/app` with the package directory you are working on. Odin checks that package and its imports. Use `-no-entry-point` for library packages and `-vet` to enable vetting. A successful check exits with status 0.

### Run tests

Run the full suite from the repository root. On Windows, append `-define:ODIN_TEST_THREADS=1` because the tests share the system-wide writer mutex.

```sh
odin test tests -all-packages -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=true
```

`-all-packages` runs tests in the packages imported by the [test entrypoint](../../tests/all.odin). When adding tests to a new package, add its import there.

For a product test, place a `*_test.odin` file in the package it exercises. Use `#+test`, import `core:testing`, and mark the procedure with `@(test)`. For a focused run, target the package directly. For example, `odin test src/cli -collection:kadai=src -collection:third_party=third_party` tests CLI dispatch and error handling. The [YAML test commands](yaml-parser.md#run-the-probe) include the native linker flags for each target.

The integration test selects `recognition/crlf-bom` from the [fixture catalog](../../tests/fixtures/v1/README.md), prepares its literal inputs in a fresh temporary directory, and verifies that the staged task preserves the source bytes, including the BOM and CRLF. Its `scan` action awaits the scanner.

### Build the CLI

Kadai's default build explicitly selects static LibYAML with `-define:YAML_STATIC=true`. The binding itself defaults to dynamic linking when this flag is omitted. Run the build from the repository root.

```sh
odin build cmd/kadai -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=true
./kadai --help
```

On Windows, run `.\kadai.exe --help`. Use `--version` to print the version. The CLI uses Odin's `core:flags` Unix-style parser. Running without arguments or with `-h` also prints help. These invocations write to stdout and exit with status 0. Invalid arguments or multiple options produce a diagnostic on stderr and exit with status 2. A failed stdout write returns 7 for a read or 6 after a successful mutation. See the [exit-code contract](cli.md#exit-codes-and-streams).

Run `kadai init` to initialize the selected project. The CLI uses LibYAML to validate project configuration.

On macOS ARM64, the binding expects `third_party/odin-yaml/lib/macos/aarch64/libyaml.a`. If your checkout lacks that archive, copy it from an ARM64 Homebrew installation of LibYAML 0.2.5 before building packages that use YAML.

```sh
brew install libyaml
mkdir -p third_party/odin-yaml/lib/macos/aarch64
cp "$(brew --prefix libyaml)/lib/libyaml.a" third_party/odin-yaml/lib/macos/aarch64/
```

To build with dynamic LibYAML on macOS, install `libyaml` with Homebrew and supply its library directory to the linker. Executables that use YAML then need the Homebrew dylib at runtime.

```sh
odin build cmd/kadai -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=false -extra-linker-flags:"-L$(brew --prefix libyaml)/lib"
```

### Build for a release tag

Local builds default to `kadai 0.1.0-dev`. For packaging, pass the tag name to the [release version script](../../.github/scripts/release_version.py). It accepts a lowercase `v` followed by a [SemVer 2.0.0 version](https://semver.org/spec/v2.0.0.html) and prints the version, including any prerelease and build metadata. An invalid tag exits with an error before the build.

```sh
tag=v0.1.0-rc.1
version=$(python3 .github/scripts/release_version.py "$tag") &&
  odin build cmd/kadai -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=true "-define:KADAI_VERSION=$version" &&
  ./kadai --version
# kadai 0.1.0-rc.1
```

In a tag-triggered GitHub Actions job, use `GITHUB_REF_NAME` as the tag input. The same Python script works on Windows with `python`. In PowerShell, check `$LASTEXITCODE` after validation and stop on failure before invoking Odin.

### Rehearse release packaging

In GitHub Actions, open **Release → Run workflow**, select the branch and enter a version tag such as `v0.1.0-rc.1`. The branch selects the commit to build. The tag input sets the binary version. Pushing a `v*` tag runs packaging on the tagged commit after the version passes validation.

The [release workflow](../../.github/workflows/release.yml) runs the full suite on Linux AMD64, Linux ARM64, Windows AMD64 and macOS ARM64. Each runner extracts its finished package, compares the executable and the three license notices with their inputs, checks `--version` and inspects the executable for a shared LibYAML dependency.

The **Artifacts** section offers the four tested packages as direct downloads, such as `kadai-0.1.0-rc.1-darwin-arm64.tar.gz` and `kadai-0.1.0-rc.1-windows-amd64.zip`, plus `SHA256SUMS`. The workflow run identifies the commit shared by all four packages. Each package contains the executable and Kadai's `LICENSE` at its root. The `licenses/` directory contains the LibYAML 0.2.5 and Odin bindings notices. [Upstream LibYAML notice](https://github.com/yaml/libyaml/blob/0.2.5/License)

### Publish a release

Rehearse the intended tag on the commit to distribute. Review the four package contents and notices, check for exposed credentials, and follow the [binary installation instructions](../../README.md#install-a-release-binary). With all five artifacts from that run in one directory, run `sha256sum --check SHA256SUMS`.

The maintainer then tags the reviewed commit and pushes that tag. For the first prerelease, substitute its full Git commit SHA before running:

```sh
git tag -a v0.1.0-rc.1 REVIEWED_COMMIT_SHA -m "Kadai v0.1.0-rc.1"
git push origin refs/tags/v0.1.0-rc.1
```

A tag push rebuilds and tests all four packages. After the checksum job succeeds, the publication job verifies the tag still points to the tested commit and attaches the four archives and `SHA256SUMS` to a GitHub Release. A SemVer prerelease suffix selects **Pre-release**. The job downloads all five release assets again and checks the package digests against the manifest. Its summary records the release URL and commit. Manual runs stop after producing the rehearsal artifacts.
