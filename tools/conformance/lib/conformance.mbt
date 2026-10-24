///|
pub fn smoke() -> Bool raise {
  let input : Bytes = b"MoonXZ conformance smoke test"
  let moonxz = @moonxz.decompress(@moonxz.compress(input))
  let other = @lzma.decode(@lzma.encode(input))
  moonxz == input && other == input
}
