import Lake
open System Lake DSL

/-- Split a shell-style flag string on spaces and drop empties. -/
def splitFlags (s : String) : Array String :=
  s.splitOn " " |>.filter (· ≠ "") |>.toArray

/-- Look `cmd` up on `PATH`, the way a shell would. -/
def onPath (cmd : String) : IO Bool := do
  let some path ← IO.getEnv "PATH" | return false
  let sep := if Platform.isWindows then ";" else ":"
  let exts := if Platform.isWindows then #["", ".exe", ".cmd", ".bat"] else #[""]
  for dir in path.splitOn sep do
    if dir.isEmpty then continue
    for ext in exts do
      let candidate : FilePath := dir / (cmd ++ ext)
      if (← candidate.pathExists) && !(← candidate.isDir) then return true
  return false

/-- Run a probe command, reporting `none` if the tool is not installed.

    We must not hand `IO.Process.output` a command that does not exist. On the
    pinned toolchain (v4.30.0-rc2), a failed spawn duplicates whatever is
    sitting unflushed in the parent's file buffers, and one of those buffers
    belongs to Lake: it writes the configuration trace, then elaborates this
    file with that write still buffered. The trace ends up holding its JSON
    object twice, which Lake's own parser rejects, so the first `lake` command
    in a fresh clone succeeds and every one after it fails with "compiled
    configuration is invalid; run with '-R' to reconfigure" until you actually
    run `-R`. That is fixed from v4.31.0-rc1 on; until we move, look the tool up
    on `PATH` first. (`IO.Process.output` does not throw for a missing
    executable — it reports exit code 255 — but it can still fail for other
    reasons, hence the fallible call below.) -/
def tryOutput (cmd : String) (args : Array String) : IO (Option IO.Process.Output) := do
  unless (← onPath cmd) do return none
  match ← (IO.Process.output { cmd, args }).toBaseIO with
  | .ok out => return some out
  | .error e =>
    IO.eprintln s!"warning: could not run the probe '{cmd}': {e}"
    return none

/-- Run `pkg-config` and split the output into flags. Returns `#[]` on failure. -/
def pkgConfig (pkg : String) (flag : String) : IO (Array String) := do
  let some out ← tryOutput "pkg-config" #[flag, pkg] | return #[]
  if out.exitCode != 0 then return #[]
  return splitFlags out.stdout.trimAscii.toString

/-- Run `xcrun --show-sdk-path` and return the SDK path on Apple platforms. -/
def macSdkPath : IO (Option FilePath) := do
  if !Platform.isOSX then return none
  let some out ← tryOutput "xcrun" #["--show-sdk-path"] | return none
  if out.exitCode != 0 then
    return none
  else
    return some out.stdout.trimAscii.toString

/-- Prefer an explicit linker override when supplied by the environment. -/
def zlibLdFlagsOverride : IO (Option (Array String)) := do
  return (← IO.getEnv "ZLIB_LDFLAGS") |>.map (splitFlags ·.trimAscii.toString)

/-- Get zlib include flags, respecting `ZLIB_CFLAGS` env var override. -/
def zlibCFlags : IO (Array String) := do
  if let some flags := (← IO.getEnv "ZLIB_CFLAGS") then
    return splitFlags flags.trimAscii.toString
  let flags ← pkgConfig "zlib" "--cflags"
  if !flags.isEmpty then
    return flags
  if let some sdk := (← macSdkPath) then
    return #["-I", (sdk / "usr/include").toString]
  return #[]

/-- Extract `-L` library paths from `NIX_LDFLAGS` (set by nix-shell). -/
def nixLdLibPaths : IO (Array String) := do
  let some val := (← IO.getEnv "NIX_LDFLAGS") | return #[]
  return val.splitOn " " |>.filter (·.startsWith "-L") |>.toArray

/-- Get link flags for zlib.
    Tries `ZLIB_LDFLAGS`, then pkg-config, then macOS SDK / Nix fallbacks. -/
def zlibLinkFlags : IO (Array String) := do
  if let some flags := (← zlibLdFlagsOverride) then
    return flags
  let libPaths ← nixLdLibPaths
  let zlibFlags ← pkgConfig "zlib" "--libs"
  if !zlibFlags.isEmpty && zlibFlags.any (·.startsWith "-L") then
    return zlibFlags
  if let some sdk := (← macSdkPath) then
    return #["-L", (sdk / "usr/lib").toString, "-lz"]
  if !zlibFlags.isEmpty then
    return libPaths ++ zlibFlags
  -- pkg-config unavailable — try NIX_LDFLAGS for -L paths
  return libPaths ++ #["-lz"]

package «lean-zlib» where
  moreLinkArgs := run_io zlibLinkFlags
  testDriver := "test"

lean_lib Zlib

input_file zlib_ffi.c where
  path := "c" / "zlib_ffi.c"
  text := true

target zlib_ffi.o pkg : FilePath := do
  let srcJob ← zlib_ffi.c.fetch
  let oFile := pkg.buildDir / "c" / "zlib_ffi.o"
  let weakArgs := #["-I", (← getLeanIncludeDir).toString] ++ (← zlibCFlags)
  let hardArgs := if Platform.isWindows then #[] else #["-fPIC"]
  buildO oFile srcJob weakArgs hardArgs "cc"

extern_lib libzlib_ffi pkg := do
  let ffiO ← zlib_ffi.o.fetch
  let name := nameToStaticLib "zlib_ffi"
  buildStaticLib (pkg.staticLibDir / name) #[ffiO]

lean_lib ZlibTest where
  globs := #[.submodules `ZlibTest]

@[default_target]
lean_exe test where
  root := `ZlibTest
