# lean-zlib

**Thin Lean 4 FFI bindings to system [zlib](https://zlib.net/).**

Whole-buffer and streaming compression/decompression for the zlib (RFC 1950),
gzip (RFC 1952), and raw DEFLATE (RFC 1951) formats, plus CRC-32 and Adler-32
checksums. This is the fast, ubiquitous C baseline; if you want the formally
verified pure-Lean DEFLATE codec instead, see
[lean-zip](https://github.com/kim-em/lean-zip).

Extracted from [lean-zip](https://github.com/kim-em/lean-zip)
(`pre-split` tag), where these bindings served as the conformance reference
for the verified codec.

## Using it

Add to your `lakefile.lean`:

```lean
require "kim-em" / "lean-zlib"
```

### Compression

```lean
import Zlib

-- Zlib format
let compressed ← Zlib.compress data
let original ← Zlib.decompress compressed

-- Gzip format (compatible with gzip/gunzip)
let gzipped ← Gzip.compress data (level := 6)
let original ← Gzip.decompress gzipped

-- Raw deflate (no header/trailer, used internally by ZIP)
let deflated ← RawDeflate.compress data
let original ← RawDeflate.decompress deflated
```

All decompression entry points default to a 1 GiB output cap; pass
`maxDecompressedSize := 0` to opt into unlimited mode (bomb-unsafe for
untrusted input). See [SECURITY.md](SECURITY.md).

### Streaming

For data too large to fit in memory:

```lean
-- Stream between IO.FS.Streams (64KB chunks, bounded memory)
Gzip.compressStream inputStream outputStream (level := 6)
Gzip.decompressStream inputStream outputStream

-- File helpers
let gzPath ← Gzip.compressFile "/path/to/file"         -- writes /path/to/file.gz
let outPath ← Gzip.decompressFile "/path/to/file.gz"   -- writes /path/to/file
```

### Low-level streaming state

```lean
let state ← Gzip.DeflateState.new (level := 6)
let compressed ← state.push chunk1
let compressed2 ← state.push chunk2
let final ← state.finish  -- must call exactly once
```

### Checksums

```lean
let crc := Checksum.crc32 0 data         -- CRC-32
let adler := Checksum.adler32 1 data     -- Adler-32
-- Incremental: pass previous result as init
let crc2 := Checksum.crc32 crc moreData
```

## Requirements

- Lean toolchain per [`lean-toolchain`](lean-toolchain) (via
  [elan](https://github.com/leanprover/elan))
- system zlib and `pkg-config` (Ubuntu: `apt install libz-dev pkg-config`;
  macOS: ships with the SDK; NixOS: `nix-shell` uses the provided
  [`shell.nix`](shell.nix))
- To override probing: set `ZLIB_CFLAGS` / `ZLIB_LDFLAGS`

## Building and testing

```
lake build
lake exe test
```

`scripts/sanitize-ffi.sh` rebuilds the FFI under ASan + UBSan and runs the
test suite; `scripts/check-c-allocations.sh` is an advisory trip wire for new
allocation sites in `c/zlib_ffi.c` (see [SECURITY.md](SECURITY.md)).

## License

Apache 2.0. Test fixtures from other projects are used under their own
licenses; see [testdata/LICENSES.md](testdata/LICENSES.md).
