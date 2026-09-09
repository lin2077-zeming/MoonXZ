///|
test "crc32 known vector" {
  @test.assert_eq(@lib.crc32(b"123456789"), 0xCBF43926U)
}

///|
test "sha256 known vector" {
  @test.assert_eq(
    @hex.encode(@lib.sha256(b"abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
}

///|
test "empty store roundtrip" {
  let input : Bytes = b""
  @test.assert_eq(@lib.decompress(@lib.compress(input)), input)
}

///|
test "store roundtrip with every check type" {
  let input = b"MoonXZ roundtrip test data.\n"
  let checks : Array[@lib.CheckKind] = [
    @lib.CheckKind::None,
    @lib.CheckKind::Crc32,
    @lib.CheckKind::Crc64,
    @lib.CheckKind::Sha256,
  ]
  for check in checks {
    let encoded = @lib.compress_with_check(input, check)
    @test.assert_eq(@lib.decompress(encoded), input)
  }
}

///|
test "store encoder splits LZMA2 chunks" {
  let input = Bytes::make(150000, b'A')
  let encoded = @lib.compress(input)
  @test.assert_eq(@lib.decompress(encoded), input)
}

///|
test "decode Python lzma fixture" {
  let fixture = @hex.decode(
    "fd377a585a000004e6d6b4460200210116000000742fe5a3e0010700285d00269becdc582d64a56402725f68cd5025d1696dcb146ffbb84cf3a46ea2c3f777d3ef7e15960000000084409d92403699d100014488020000007faf037cb1c467fb020000000004595a",
  )
  let expected = Bytes::repeat(b"MoonXZ interoperability fixture.\n", 8)
  @test.assert_eq(@lib.decompress(fixture), expected)
}

///|
test "decode concatenated streams with padding" {
  let fixture = @hex.decode(
    "fd377a585a000004e6d6b4460200210116000000742fe5a301000466697273740000000056ad19257a06e5f300011d05b82d80af1fb6f37d010000000004595a00000000fd377a585a000004e6d6b4460200210116000000742fe5a30100057365636f6e6400000038e888c5c630b47400011e06c12fa41d1fb6f37d010000000004595a",
  )
  @test.assert_eq(@lib.decompress(fixture), b"firstsecond")
}

///|
test "output limit is enforced" {
  let encoded = @lib.compress(b"0123456789")
  try {
    let _ = @lib.decompress_with_limit(encoded, 4)
    @test.fail("expected OutputLimitExceeded")
  } catch {
    @lib.OutputLimitExceeded(_) => ()
    _ => @test.fail("unexpected error")
  }
}

///|
test "reject invalid stream magic" {
  try {
    let _ = @lib.decompress(b"not an xz stream")
    @test.fail("expected InvalidHeader")
  } catch {
    @lib.InvalidHeader(_) => ()
    _ => @test.fail("unexpected error")
  }
}

///|
test "reject truncated stream header" {
  try {
    let _ = @lib.decompress(b"\xfd7zX")
    @test.fail("expected Truncated")
  } catch {
    @lib.Truncated(_) => ()
    _ => @test.fail("unexpected error")
  }
}
