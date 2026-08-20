import ZlibTest.Zlib
import ZlibTest.Gzip
import ZlibTest.RawDeflate
import ZlibTest.Checksum
import ZlibTest.CompressFixtures

def main : IO Unit := do
  unless ← System.FilePath.pathExists "testdata" do
    throw (IO.userError "testdata/ not found — run tests via 'lake test' from the project root")
  ZlibTest.Zlib.tests
  ZlibTest.Gzip.tests
  ZlibTest.RawDeflate.tests
  ZlibTest.Checksum.tests
  ZlibTest.CompressFixtures.tests
  IO.println "\nAll tests passed!"
