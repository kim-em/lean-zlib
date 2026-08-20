# lean-zlib

Thin Lean 4 FFI bindings to system zlib (zlib/gzip/raw-deflate formats,
CRC-32/Adler-32). Extracted from kim-em/lean-zip.

## Build and Test

    lake build
    lake exe test

Run from the project root. Tests require `testdata/`. Needs system zlib +
pkg-config; on NixOS use `nix-shell` (shell.nix provides both). Lake caches
`run_io` link flags in `.lake/` — after environment changes, `lake -R build`
or `rm -rf .lake`.

## Standards

- This is trusted C, not verified Lean: any change to `c/zlib_ffi.c` that
  adds or alters an allocation site requires updating the audit table in
  `SECURITY.md` (trip wire: `scripts/check-c-allocations.sh`).
- Run `scripts/sanitize-ffi.sh` (ASan + UBSan) after touching the C.
- All decompression entry points default to a 1 GiB output cap; keep new
  entry points consistent and add a compile-time default probe in the tests.
- Match the style of existing `c/*.c` code; check allocation failures and
  use overflow guards.
