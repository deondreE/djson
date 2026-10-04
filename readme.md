## Designated JSON


### Language
- [ ] Make every valid JSON file valid djson (`{"a":1}` currently fails because `:` only separates a key when followed by whitespace, a bracket or a quote)
- [x] Multi-line and raw strings (`"""..."""` or backtick blocks)
- [x] More number forms: hex/binary/octal literals, `_` separators, `u64` range
- [ ] Lone scalar documents (today `42` parses as `[42]`)
- [x] Decide the duplicate-key policy: error (current), last-wins, or merge
- [x] Write the formal grammar (EBNF) and a short spec document

### Parser
- [ ] Source spans (line, column) on every `Value`, so consumers can report their own errors
- [ ] Collect multiple errors instead of stopping at the first
- [ ] Error output with the source line and a caret under the problem
- [ ] Configurable limits (max depth, max input size, max string length)
- [ ] Streaming or incremental parsing for very large files
- [ ] Fuzz testing with `std.testing.fuzz`, plus parse/format round-trip property tests

### Serializer
- [ ] Formatter that preserves comments (`writeDjson` currently drops them)
- [ ] Options: sort keys, always-quote strings, single-line arrays, line-width wrapping
- [ ] Streaming writer API that doesn't need a full `Value` tree (MAYBE)

### Zig library API
- [x] `parseInto(T, ...)` to map straight onto Zig structs, enums and slices (like `std.json.parseFromSlice`)
- [x] `stringify(anytype, ...)` to serialize Zig values directly
- [x] Path lookup helper: `value.getPath("server.ports[0]")`
- [x] Iterators and typed getters (`getInt`, `getString`, `getBool`)
- [x] Publish as a fetchable package (`zig fetch --save`) with tagged releases
- [x] C ABI static/shared library and a WASM build

### Tooling
- [ ] Syntax highlighting: VS Code (TextMate) grammar, tree-sitter grammar
- [ ] Language server (diagnostics, formatting, hover)
- [ ] `.editorconfig` and file association for `.djson`

### Quality and housekeeping
- [ ] CI on Linux, macOS and Windows (build, test, `zig fmt --check`)
- [ ] Benchmarks against `std.json` on large files
- [ ] More tests: Windows `\r\n` input, BOM, very large documents, invalid UTF-8
- [ ] Docs site or generated API docs (`zig build docs`)
- [ ] LICENSE, CHANGELOG, CONTRIBUTING
- [ ] Clean-up: remove the unused `Io` import in `root.zig`, make `writeNewline` private, fix comment typos
