# Security

This library is a thin FFI layer over system zlib: everything here is
trusted C, not verified Lean. This document records the trust boundary,
the local guardrails, and the allocation-site audit for
[`c/zlib_ffi.c`](c/zlib_ffi.c).

Status vocabulary: `guarded-locally` (protected by explicit checks and
limits), `tested-only` (covered by tests but no stronger assurance),
`upstream-risk` (trusted dependency).

## zlib via C FFI

- Components: [`c/zlib_ffi.c`](c/zlib_ffi.c)
- Status: `guarded-locally`
- Trust boundary: whole-buffer and streaming compression/decompression are
  implemented in C and depend on zlib plus libc allocation behavior. zlib's
  own internal allocations (stream state, Huffman tables, sliding window)
  sit under `upstream-risk`.
- Current local guardrails:
  - `UINT_MAX` guards on whole-buffer input sizes
  - overflow-aware buffer growth helpers (`grow_buffer`, `SIZE_MAX/2` cap)
  - explicit `max_output` check in whole-buffer decompression
  - state finalizers for streaming objects
  - [`scripts/sanitize-ffi.sh`](scripts/sanitize-ffi.sh) rebuilds
    `c/zlib_ffi.c` under `-fsanitize=address,undefined` and runs the test
    suite, so FFI-level memory and UB errors surface as runtime traps
  - [`scripts/check-c-allocations.sh`](scripts/check-c-allocations.sh)
    warns when the count of `malloc`/`realloc`/`calloc` mentions drifts
    from the audited baseline below
- Maintenance rule: any new `malloc`/`realloc`/`calloc`/`grow_buffer` call,
  or change to `grow_buffer` semantics, in `c/zlib_ffi.c` requires
  re-running the audit and updating the snapshot table below (and the
  `EXPECTED` baseline in `check-c-allocations.sh`).

## Decompression limits

Every public API that accepts untrusted compressed bytes takes a
`maxDecompressedSize : UInt64` parameter. The default is 1 GiB
(`1073741824`); passing `0` opts into unlimited mode, which is bomb-unsafe
for untrusted input. Overflow raises `IO.userError` containing
`"exceeds limit"`. Compile-time probes in `ZlibTest/` pin each default.

| Entry point | Default | Semantics of 0 | Notes |
|---|---|---|---|
| [`Zlib.decompress`](Zlib/Basic.lean) | 1 GiB | no limit (opt-in) | whole-buffer zlib (RFC 1950). Bomb-limit regression test at [`ZlibTest/Zlib.lean`](ZlibTest/Zlib.lean). |
| [`Gzip.decompress`](Zlib/Gzip.lean) | 1 GiB | no limit (opt-in) | whole-buffer gzip (RFC 1952) + auto-zlib; the cap applies to the *total* output across concatenated members. Test at [`ZlibTest/Gzip.lean`](ZlibTest/Gzip.lean). |
| [`RawDeflate.decompress`](Zlib/RawDeflate.lean) | 1 GiB | no limit (opt-in) | whole-buffer raw DEFLATE (ZIP method 8). Test at [`ZlibTest/RawDeflate.lean`](ZlibTest/RawDeflate.lean). |
| [`Gzip.decompressStream`](Zlib/Gzip.lean) | 1 GiB | no limit (opt-in) | streaming via `IO.Ref UInt64` counter on pushed output (with UInt64 wrap-around detection); the cap check fires before `output.write`, so the already-written prefix is ≤ the cap. |
| [`Gzip.decompressFile`](Zlib/Gzip.lean) | 1 GiB | no limit (opt-in) | thin wrapper forwarding to `decompressStream`. |
| [`RawDeflate.decompressStream`](Zlib/RawDeflate.lean) | 1 GiB | no limit (opt-in) | same counter/check structure as `Gzip.decompressStream`. |

The low-level streaming state entry points (`Gzip.InflateState.push` etc.)
accept no output-size parameter; whole-stream bounding is the caller's
responsibility (the wrappers above do exactly that).

Note the cap on the whole-buffer path is a "refuses to keep going" limit,
not a "refuses to allocate" limit: with `max_output == 0` a bomb can walk
the buffer up to `SIZE_MAX/2` before `grow_buffer` refuses, because the
`max_output` check fires only after `inflate` has written into the grown
buffer.

## Allocation site audit (`c/zlib_ffi.c`)

Snapshot of every `malloc`, `realloc`, `calloc`, and `grow_buffer` call in
[`c/zlib_ffi.c`](c/zlib_ffi.c). `grow_buffer` is the shared doubling
helper; its `*buf_size > SIZE_MAX/2` overflow check and
`free(buf)`-on-failure semantics are the linchpin for every
decompression-side growth site. Callers of `grow_buffer` must NOT free
`buf` themselves on a `NULL` return — it has already been freed.

| Site | Bound | Failure handling | Notes |
|---|---|---|---|
| `mk_zlib_error` (shared error-string formatter; reached by every FFI entry point on a non-OK zlib return) | `prefix_len + detail_len + 3`, with `prefix_len > SIZE_MAX - detail_len - 3` overflow guard | returns `mk_io_error("zlib error: out of memory while formatting error")` (no resource held at this point) | `buf` is `free`d immediately after `snprintf` + `mk_io_error`; the Lean string owns its own copy. Allocation is small (≤ 256 + message). |
| `grow_buffer` (shared helper; caller-dependent) | `*buf_size *= 2`, pre-checked by `if (*buf_size > SIZE_MAX / 2)`; on overflow, frees old `buf` and returns `NULL` | returns `NULL`; **frees the old `buf` on `realloc` failure** | Every caller treats `NULL` as "buffer already freed" — no `free(buf)` on the caller's error path. |
| `decompress_inflate` — reached by `lean_zlib_decompress`, `lean_gzip_decompress`, `lean_raw_deflate_decompress` | `initial_decompress_buf(src_len)`: `src_len * 4` with a `SIZE_MAX/4` overflow guard, floored at 1024. `src_len ≤ UINT_MAX` already enforced by the caller | `inflateEnd(&strm); return mk_io_error("<label>: out of memory")` | Initial whole-buffer decompression buffer. |
| `decompress_inflate` (same callers) | `grow_buffer` doubling, capped at `SIZE_MAX/2` | on `NULL`: `inflateEnd(&strm); return mk_io_error("<label>: out of memory")` — does **not** re-free `buf` (`grow_buffer` already did) | The `max_output` cap (when non-zero) is checked **after** `inflate` writes into the grown buffer, not before `grow_buffer` — see the note above. |
| `lean_gzip_deflate_new` (streaming compression state constructor) | fixed `sizeof(deflate_state)` (small struct; zlib's internal `deflateInit2` buffers are allocated separately inside zlib) | `return mk_io_error("gzip deflate new: out of memory")` (no zlib stream yet) | `calloc` zero-initialises `finished` so the finalizer always makes a well-defined `deflateEnd` decision. |
| `lean_gzip_deflate_push` (streaming compression, per-chunk output buffer) | fixed 65 536 bytes initial | `return mk_io_error("gzip deflate push: out of memory")`. **Does not** call `deflateEnd` — the `deflate_state` remains live and the finalizer will clean it up | Grown by `grow_buffer` in the loop. |
| `lean_gzip_deflate_push` | `grow_buffer` doubling, capped at `SIZE_MAX/2` | on `NULL`: `return mk_io_error("gzip deflate push: out of memory")` (no `free`, no `deflateEnd` — finalizer cleans the state) | No per-call output cap; bounded only by `grow_buffer`'s `SIZE_MAX/2` guard. |
| `lean_gzip_deflate_finish` (streaming compression, `Z_FINISH` flush buffer) | fixed 65 536 bytes initial | `return mk_io_error("gzip deflate finish: out of memory")`. State stays live; finalizer calls `deflateEnd` | Used by both gzip and raw-deflate streaming paths (they share the same `deflate_state`). |
| `lean_gzip_deflate_finish` | `grow_buffer` doubling, capped at `SIZE_MAX/2` | on `NULL`: `return mk_io_error("gzip deflate finish: out of memory")` (no re-free, no `deflateEnd` — finalizer cleans) | No per-call output cap. |
| `lean_gzip_inflate_new` (streaming decompression state constructor; `MAX_WBITS + 32` auto-detect) | fixed `sizeof(inflate_state)` | `return mk_io_error("gzip inflate new: out of memory")` | `calloc` zero-initialises `finished`. |
| `lean_gzip_inflate_push` (streaming decompression, per-chunk output buffer; shared with raw inflate) | fixed 65 536 bytes initial | `return mk_io_error("gzip inflate push: out of memory")`. State stays live | No `max_output` parameter on this path — caller is responsible for whole-stream bounding. |
| `lean_gzip_inflate_push` | `grow_buffer` doubling, capped at `SIZE_MAX/2` | on `NULL`: `return mk_io_error("gzip inflate push: out of memory")` (no re-free, no `inflateEnd` — finalizer cleans) | No per-call output cap. |
| `lean_raw_deflate_new` (streaming raw-deflate compression state) | fixed `sizeof(deflate_state)` | `return mk_io_error("raw deflate new: out of memory")` | Reuses the shared `lean_gzip_deflate_push` / `_finish` helpers via `g_deflate_class`. |
| `lean_raw_inflate_new` (streaming raw-deflate decompression state; `-MAX_WBITS`) | fixed `sizeof(inflate_state)` | `return mk_io_error("raw inflate new: out of memory")` | Reuses the shared `lean_gzip_inflate_push` helper via `g_inflate_class`. |

What this pattern catches: `size_t` overflow in the doubling step;
individual allocation failure (every site has a `NULL`-check and returns an
`IO` error); double-free after `grow_buffer` failure; over-4 GiB
whole-buffer inputs (guarded at the caller via `src_len > UINT_MAX`).
What it does not catch: bombs on the `max_output == 0` opt-in path, and
zlib's own internal allocations.
