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
| macOS ARM64 | Static archive at `lib/macos/aarch64/libyaml.a` in the binding package, or dynamic LibYAML from Homebrew. | Parser tests ran with static and dynamic LibYAML 0.2.5. The dynamic executable records the Homebrew install path. |
| macOS x86_64 | Vendored static archive or system `libyaml`. | Static test ran under Rosetta without a LibYAML dylib dependency. |
| Linux x86_64, ARM64 | Static archive supplied for each target. Dynamic linking needs the distribution's LibYAML development package at build time and the shared library at runtime. | Bindings type-checked for both targets. Native link and execution untested. |
| Windows x86_64 | `yaml.lib` for static linking. Dynamic linking uses `yamld.lib` and needs `yaml.dll` on the executable's DLL search path. | Bindings type-checked. Native link and execution untested. |

### Task document decoding

`document.decode_task` borrows the original Markdown and returns the decoded fields, field errors and ordered YAML nodes. Each node carries a half-open byte range relative to the header. An unknown v1 key produces a field error and keeps its key, value and surrounding source available for editing. A future schema exposes only its version and verifiable ID. Release the result with `document.destroy`. [Task decoder](../../src/document/decode.odin).

Known string fields use the decoded scalar text. Under `custom`, nodes carry their resolved type and decoded text. Integer digits and radix are available without narrowing, and floats retain their exact spelling. [Scalar implementation](../../src/yaml/scalar.odin), [YAML 1.2.2 Core Schema](https://yaml.org/spec/1.2.2/#1032-tag-resolution).

### Preserving the Markdown body

`document.compose_header_edit` builds candidate Markdown in memory from a decoded task, one header-relative byte range and its replacement. It copies the original bytes outside the range and checks that the original closing delimiter still separates the header from the body. The candidate keeps the body's line endings, whitespace and final newline exactly as written. The field planner must verify the target span and reparse the candidate to check the intended field change before persistence. [Source composition](../../src/document/header_edit.odin), [byte-preservation tests](../../src/document/header_edit_test.odin).

On success the caller owns the candidate string and the error is `nil`. A rejected edit returns a `yaml.Diagnostic`, which the caller releases with `yaml.destroy_diagnostic`. Candidate allocation errors propagate as `runtime.Allocator_Error`. An allocator that supplies no storage for the candidate yields `.Out_Of_Memory`.

### Replacing a task scalar

`document.plan_scalar_patch(source, .Title, "New title")` returns owned candidate Markdown with the same error and ownership contract as `compose_header_edit`. It supports existing single-line plain, single-quoted and double-quoted tokens for `title`, `status`, `priority`, `parent` and `due` in a block root. Pass `nil` to set an optional field to YAML null. A text value such as `"null"` keeps its string meaning. Missing fields, empty implicit values, multiline tokens and flow roots are refused by this operation.

The planner reparses the entire candidate with the supplied vocabulary and limits. It checks the new value and its byte range, every unrelated YAML entry, and the remaining field errors. A schema-invalid task with a usable ID and a supported version permits repair of its invalid target field. Collection-level identity, relationship checks and persistence belong to the caller. [Scalar planner](../../src/document/scalar_patch.odin), [source-preservation tests](../../src/document/scalar_patch_test.odin).

### Inserting and removing task fields

Use `document.plan_key_patch` for a whole top-level entry in a block mapping. It uses the same vocabulary, limits, candidate ownership and error handling as `plan_scalar_patch`.

```odin
added := document.plan_key_patch(source, .Priority, document.Insert_Field{value = "high", after = "status"}) or_return
defer delete(added)
restored := document.plan_key_patch(added, .Priority, document.Unset_Field{}) or_return
defer delete(restored)
```

Insertion appends by default. Set `after` to an existing decoded key to insert before the next entry. The new line uses the root indentation and the local line ending. A string is scalar text, `nil` inserts YAML null, and `document.Inline_Collection{"[cli, docs]"}` supplies a single flow collection checked against the field schema. Inserting a missing `title` or `status` can repair a task with a valid ID.

An explicit unset removes an existing optional entry, including its line ending. Required fields, duplicate insertions and unsets of missing fields produce diagnostics. The planner also refuses edits with ambiguous comment ownership or conflicting line endings at the insertion point. Every proposal is reparsed to check the field change, the order and values of the other entries, and any remaining schema errors. [Key planner](../../src/document/key_patch.odin), [byte-preservation and refusal tests](../../src/document/key_patch_test.odin).

### Diagnostics

Pass the known filename to `document.decode_task(source, path = "tasks/example.md")`. Each entry in `doc.diagnostics` carries the supplied path, a stable code, the field when identifiable, and a message explaining how to correct the problem. A duplicate mapping key names its full path, such as `custom.nested.x`. A duplicate tag points to the repeated list item. LibYAML syntax errors retain the parser's explanation. [Diagnostic tests](../../src/document/decode_test.odin).

Diagnostic spans are half-open byte offsets into the original Markdown. Lines and Unicode code-point columns start at one, and an initial BOM occupies no display column. An EOF location has a zero-width span. A missing required field has no token to point to and leaves the location unset (line zero).

Limit errors name the budget and include the observed value and configured limit. When header extraction stops at the first excess byte, the observed count is a lower bound. Direct callers of `yaml.parse_mapping` can pass a fresh `report` and `path` to obtain locations relative to the YAML input. Release that report with `yaml.destroy_diagnostic`. For a task document, `document.destroy` releases all its diagnostics.

`yaml.parse_mapping_checked` exposes the allocator error when building the tree fails. A caller of `document.decode_task` can capture its optional second return value to propagate that error. Allocation failure leaves the document in the `Allocation_Error` state with its partial tree released.

### Run the probe

Run from the repository root. Use the same static LibYAML setting as the [standard CLI build](toolchain.md#build-the-cli) on macOS and Linux (x86_64 or ARM64) and Windows x86_64.

```sh
odin test src/yaml -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=true
odin test src/document -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=true
```

To test dynamic linking on macOS with Homebrew:

```sh
brew install libyaml
odin test src/yaml -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=false -extra-linker-flags:"-L$(brew --prefix libyaml)/lib"
odin test src/document -collection:kadai=src -collection:third_party=third_party -define:YAML_STATIC=false -extra-linker-flags:"-L$(brew --prefix libyaml)/lib"
```
