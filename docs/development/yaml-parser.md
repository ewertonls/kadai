# KAD-013 YAML parser spike

Kadai v1 uses LibYAML's event API through the vendored Odin bindings. It exposes scalar text, quoting style, anchors, tags and source marks before constructing a mapping. The high-level `oyaml.decode` helper loses source marks, inserts keys into an Odin map and coerces values such as `yes` to booleans. Kadai needs the events to detect duplicate keys, count nodes and depth, and resolve known fields and `custom` values under their respective schemas. [LibYAML event API](https://pyyaml.org/wiki/LibYAML), [KAD-006](../specs/KAD-006-yaml-compatibility-mutation-v1.md).

### Source marks

The probe reads a UTF-8 comment, CRLF, a quoted scalar containing both Unicode and a YAML escape, and a trailing comment. Its scalar event contains a decoded newline. Its marks enclose the quoted source spelling and exclude the trailing comment. The opening quote has index 15 and byte offset 16. LibYAML counts Unicode code points, including CR and LF individually. Line and column start at zero. [Odin probe](../../src/yaml/libyaml_test.odin).

A patcher needs to translate these marks to byte offsets in the original UTF-8 header and add the header's file offset. Count code points in the original bytes, including both characters of CRLF. Keep the source for comments and whitespace. For a supported edit, verify the target bytes and reparse the proposed patch. [LibYAML scanner](https://github.com/yaml/libyaml/blob/0.2.5/src/scanner.c).

### YAML 1.2 compatibility

libfyaml provides a maintained C alternative with a streaming YAML 1.2 parser and token marks. On the same ARM64 host, its 0.9.6 `fy-tool --yaml-1.2 --testsuite -` decoded the quoted scalar in the probe. Adopting it would require Odin bindings for its C API and a libfyaml build or package per target. Upstream documents CMake builds for Linux, macOS and Windows. [libfyaml API](https://github.com/pantoniou/libfyaml/blob/v0.9.6/include/libfyaml/libfyaml-core.h), [upstream build and platform documentation](https://github.com/pantoniou/libfyaml#installation).

Two inputs exercise YAML 1.2 syntax that matters for Kadai's reader.

| YAML input | LibYAML 0.2.5 | libfyaml 0.9.6 in YAML 1.2 mode |
| --- | --- | --- |
| `custom: {labels: [:start]}` | Fails at the colon with `did not find expected node content` | Reads a sequence containing the string `:start` |
| A quoted `custom.label` value containing the UTF-8 bytes `61 C2 85 62` (a, U+0085, b) | Returns `a b` | Preserves U+0085 in the string |

Both differences arise in the scanner. Kadai accepts the quoted spelling `[":start"]`. Its reader must reject unsupported literal line breaks before invoking LibYAML to prevent silent changes to field values. A double-quoted `"a\u0085b"` delivers the intended value. LibYAML 0.2.5 also parsed all 48 literal task headers identified as valid in the fixture manifests. This checked syntax only. [KAD-006 supported syntax](../specs/KAD-006-yaml-compatibility-mutation-v1.md#2-supported-yaml-syntax), [YAML 1.2 line-break changes](https://yaml.org/spec/1.2.2/ext/changes/#changes-in-version-12-revision-120-2009-07-21).

### Licensing and linking

LibYAML and libfyaml use MIT licenses. Include the applicable copyright and permission notice with copies. The Odin bindings use the zlib license. Retain its source notice and mark local alterations. Odin requires unique declared package names even when the import is aliased. The local bindings and their generator use `odin_yaml`, so the Kadai package can remain `yaml` and use `import oyaml "third_party:odin-yaml"`. [LibYAML license](https://github.com/yaml/libyaml/blob/0.2.5/License), [binding license](../../third_party/odin-yaml/LICENSE), [libfyaml license](https://github.com/pantoniou/libfyaml/blob/master/LICENSE).

| Target | LibYAML link options | Verified here |
| --- | --- | --- |
| macOS ARM64 | System `libyaml` (Homebrew). The vendor tree has no ARM64 macOS archive. | Test ran with Homebrew's 0.2.5 dylib. The binary records its Homebrew install path. |
| macOS x86_64 | Vendored static archive or system `libyaml`. | Static test ran under Rosetta without a LibYAML dylib dependency. |
| Linux x86_64, ARM64 | Static archive supplied for each target. Dynamic linking needs the distribution's LibYAML development package at build time and the shared library at runtime. | Bindings type-checked for both targets. Native link and execution untested. |
| Windows x86_64 | `yaml.lib` for static linking. Default dynamic linking uses `yamld.lib` and needs `yaml.dll` on the executable's DLL search path. | Bindings type-checked. Native link and execution untested. |

### Task document decoding

`document.decode_task` borrows the original Markdown and returns the decoded fields, field errors and ordered YAML nodes. Each node carries a half-open byte range relative to the header. An unknown v1 key produces a field error and keeps its key, value and surrounding source available for editing. A future schema exposes only its version and verifiable ID. Release the result with `document.destroy`. [Task decoder](../../src/document/decode.odin).

Known string fields use the decoded scalar text. Under `custom`, nodes carry their resolved type and decoded text. Integer digits and radix are available without narrowing, and floats retain their exact spelling. [Scalar implementation](../../src/yaml/scalar.odin), [YAML 1.2.2 Core Schema](https://yaml.org/spec/1.2.2/#1032-tag-resolution).

### Run the probe

Run from the repository root. On macOS ARM64, use Homebrew's library path.

```sh
brew install libyaml
odin test src/yaml -collection:kadai=src -collection:third_party=third_party -extra-linker-flags:"-L$(brew --prefix libyaml)/lib"
odin test src/document -collection:kadai=src -collection:third_party=third_party -extra-linker-flags:"-L$(brew --prefix libyaml)/lib"
```

On macOS x86_64, Linux x86_64 or ARM64, and Windows x86_64, select the matching vendored static library.

```sh
odin test src/yaml -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=true
odin test src/document -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=true
```
