import Zlib

/-! Test utilities: fixture loading, assertion helpers, and test data generation. -/

set_option maxRecDepth 2048

/-- Read a test fixture from testdata/ directory. -/
def readFixture (path : String) : IO ByteArray :=
  IO.FS.readBinFile s!"testdata/{path}"

/-- Assert that an IO action throws an error containing the given substring. -/
def assertThrows (description : String) (action : IO Unit) (errorSubstring : String) : IO Unit := do
  let sentinel := "<<ASSERT_THROWS_FAIL>>"
  try
    action
    throw (IO.userError s!"{sentinel}{description}: expected error containing '{errorSubstring}' but succeeded")
  catch e =>
    let msg := toString e
    if msg.contains sentinel then
      throw e
    else if msg.contains errorSubstring then
      pure ()
    else
      throw (IO.userError s!"{sentinel}{description}: expected '{errorSubstring}' but got: {msg}")

/-- Create a readable IO.FS.Stream backed by a ByteArray.
    Each `read n` returns up to `n` bytes from the current position. -/
def byteArrayReadStream (data : ByteArray) : IO IO.FS.Stream := do
  let posRef ← IO.mkRef 0
  return {
    flush := pure ()
    read := fun n => do
      let pos ← posRef.get
      let available := data.size - pos
      let toRead := min n.toNat available
      let result := data.extract pos (pos + toRead)
      posRef.set (pos + toRead)
      return result
    write := fun _ => throw (IO.userError "byteArrayReadStream: write not supported")
    getLine := pure ""
    putStr := fun _ => pure ()
    isTty := pure false
  }

/-- Create the standard test data (100x repeated string, 6300 bytes). -/
def mkTestData : IO ByteArray := do
  let original := "Hello, world! This is a test of zlib compression from Lean 4. ".toUTF8
  let mut big := ByteArray.empty
  for _ in [:100] do
    big := big ++ original
  return big

/-- Create large test data (2000x repeated string, 126000 bytes). -/
def mkLargeData : IO ByteArray := do
  let original := "Hello, world! This is a test of zlib compression from Lean 4. ".toUTF8
  let mut large := ByteArray.empty
  for _ in [:2000] do
    large := large ++ original
  return large
