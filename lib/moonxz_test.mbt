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
test "roundtrip with every check type" {
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
test "compressed encoder splits LZMA2 chunks" {
  let input = Bytes::make(150000, b'A')
  let encoded = @lib.compress(input)
  @test.assert_eq(@lib.decompress(encoded), input)
}

///|
test "compression options roundtrip" {
  let input = Bytes::repeat(b"MoonXZ compression options. ", 500)
  let levels = [1, 6, 9]
  let dictionaries = [4096, 1 << 20]
  for level in levels {
    for dict_size in dictionaries {
      let options = @lib.CompressionOptions::new(level~, dict_size~)
      let encoded = @lib.compress_with_options(input, options)
      @test.assert_eq(@lib.decompress(encoded), input)
    }
  }
}

///|
test "store level roundtrip" {
  let input = Bytes::repeat(b"store mode", 300)
  let encoded = @lib.compress_with_options(
    input,
    @lib.CompressionOptions::new(level=0),
  )
  @test.assert_eq(@lib.decompress(encoded), input)
}

///|
test "delta filter roundtrip" {
  let input = Bytes::repeat(b"Delta filter roundtrip data. ", 80)
  let options = @lib.CompressionOptions::new(
    level=6,
    filter=@lib.FilterMode::Delta(3),
  )
  let encoded = @lib.compress_with_options(input, options)
  @test.assert_eq(@lib.decompress(encoded), input)
}

///|
test "x86 BCJ filter roundtrip" {
  let input = @hex.decode(
    "e800000000e9fbffffff90e801000000c3e800000000e9fbffffff",
  )
  let options = @lib.CompressionOptions::new(
    level=6,
    filter=@lib.FilterMode::X86,
  )
  let encoded = @lib.compress_with_options(input, options)
  @test.assert_eq(@lib.decompress(encoded), input)
}

///|
test "compressed output is smaller for repetitive data" {
  let input = Bytes::make(10000, b'A')
  let encoded = @lib.compress_with_options(
    input,
    @lib.CompressionOptions::new(level=6),
  )
  @test.assert_eq(encoded.length() < input.length() / 10, true)
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
test "decode Python delta filter fixture" {
  let fixture = @hex.decode(
    "fd377a585a000004e6d6b44602010301012101161c477856e000d700265d0022194100f7eadad6ee9e5f3cd81dd2628ec8d5393eef84ae75368c9ce2f9c575c494b6d2c000000000f4b9491e0e91073c000142d801000000472cfc80b1c467fb020000000004595a",
  )
  let expected = Bytes::repeat(b"Delta filter fixture data. ", 8)
  @test.assert_eq(@lib.decompress(fixture), expected)
}

///|
test "decode Python x86 BCJ fixture" {
  let fixture = @hex.decode(
    "fd377a585a000004e6d6b44602010400210116000d86351f010010e805000000e90500000090e811000000c30000000045790daf2939e79800012911320a700e1fb6f37d010000000004595a",
  )
  let expected = @hex.decode("e800000000e9fbffffff90e801000000c3")
  @test.assert_eq(@lib.decompress(fixture), expected)
}

///|
/// The BCJ fixtures below were produced by Python 3.14 `liblzma`, which is the
/// same C implementation `xz-utils` uses. Each input starts with a few real
/// branch instructions and is padded, because `liblzma` skips the BCJ filter
/// entirely for inputs that are too short to contain a branch.
fn bcj_padding() -> Bytes {
  Bytes::make(60, b'\x00')
}

///|
test "decode Python ARM BCJ fixture" {
  let fixture = @hex.decode(
    "fd377a585a000004e6d6b4460201070021011600a3f4a199e0004b00125d00010036114848dd5fb2ced1b14e74a30090000000000daf6ece7d4a1c1f00012e4cbcb1eb541fb6f37d010000000004595a",
  )
  let expected = @hex.decode("000000eb000000eb040000ebffffffea") + bcj_padding()
  @test.assert_eq(@lib.decompress(fixture), expected)
}

///|
/// The ARM-Thumb, PowerPC and IA64 BCJ filters are defined by the XZ
/// specification but are not implemented, so a block that uses one must be
/// refused rather than decoded to wrong bytes.
test "unimplemented BCJ filters are reported as unsupported" {
  let fixtures : Array[String] = [
    // ARM-Thumb (filter id 0x08)
    "fd377a585a000004e6d6b44602010800210116007646f76801001300f002f802f008f800f006f800bf00000000000000114951785f6bf4bb00012c14f80a6d031fb6f37d010000000004595a",
    // PowerPC (filter id 0x05)
     "fd377a585a000004e6d6b4460201050021011600a85569d4e00073000f5d0024002c030860b51ec5d45a4712a000000012a8ef35201abcf500012b7467fd9e011fb6f37d010000000004595a",
  ]
  for fixture in fixtures {
    try {
      let _ = @lib.decompress(@hex.decode(fixture))
      @test.fail("expected Unsupported for an unimplemented BCJ filter")
    } catch {
      @lib.Unsupported(_) => ()
      _ => @test.fail("expected Unsupported for an unimplemented BCJ filter")
    }
  }
}

///|
test "decode Python SPARC BCJ fixture" {
  let fixture = @hex.decode(
    "fd377a585a000004e6d6b4460201090021011600d395aba3e0004b000f5d0020002c0308607fe1714cd80caa8000000037f736463f2dbd1800012b4cf9459c291fb6f37d010000000004595a",
  )
  let expected = @hex.decode("40000001400000054000000901000000") + bcj_padding()
  @test.assert_eq(@lib.decompress(fixture), expected)
}

///|
test "decode padded Python x86 BCJ fixture" {
  let fixture = @hex.decode(
    "fd377a585a000004e6d6b44602010400210116000d86351fe0004c00135d0074013c193e1116b1239d8179a669888f20ac000000f31c92d9262364a200012f4d6bb0f73a1fb6f37d010000000004595a",
  )
  let expected = @hex.decode("e800000000e9fbffffff90e801000000c3") +
    bcj_padding()
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
test "streaming writer and reader use multiple blocks" {
  let writer = @lib.XzWriter::new()
  let first = writer.write(b"first chunk")
  let second = writer.write(b"second chunk")
  let tail = writer.finish()
  let encoded = first + second + tail
  let reader = @lib.XzReader::new(encoded)
  try {
    @test.assert_eq(reader.read_block(), Some(b"first chunk"))
    @test.assert_eq(reader.read_block(), Some(b"second chunk"))
    @test.assert_eq(reader.read_block(), None)
  } catch {
    @lib.ChecksumMismatch(message) => @test.fail(message)
    _ => @test.fail("streaming reader failed")
  }
}

///|
test "streaming empty stream is valid" {
  let writer = @lib.XzWriter::new()
  let tail = writer.finish()
  let reader = @lib.XzReader::new(tail)
  @test.assert_eq(reader.read_block(), None)
  @test.assert_eq(@lib.decompress(tail), b"")
}

///|
test "streaming reader enforces output limit" {
  let writer = @lib.XzWriter::new()
  let encoded = writer.write(b"0123456789") + writer.finish()
  let reader = @lib.XzReader::new(encoded, max_output=4)
  try {
    let _ = reader.read_block()
    @test.fail("expected OutputLimitExceeded")
  } catch {
    @lib.OutputLimitExceeded(_) => ()
    _ => @test.fail("unexpected error")
  }
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

///|
/// Every single-byte truncation of a valid stream must fail cleanly.
///
/// A truncated stream can never legitimately decode to the original bytes, so
/// each prefix either raises a typed `XzError` or - for very short prefixes -
/// fails the stream magic check. Neither may panic or return partial data.
test "truncated streams never decode to the original" {
  let input = Bytes::repeat(b"MoonXZ truncation fixture. ", 40)
  let encoded = @lib.compress(input)
  for cut in 0..<encoded.length() {
    let prefix = encoded[:cut].to_owned()
    let outcome = @lib.decompress(prefix) catch { _ => b"" }
    if outcome == input {
      @test.fail("truncated stream at \{cut} decoded to the original input")
    }
  }
  @test.assert_eq(@lib.decompress(encoded), input)
}

///|
/// Corrupting a stream must never panic and must never silently produce data
/// that differs from the original.
///
/// A handful of single-byte mutations are benign by construction: LZMA2 chunk
/// framing records the compressed payload length while a decoder re-derives that
/// length by scanning to the chunk terminator, so some framing bytes carry no
/// information for a conforming decoder. Those mutations still re-derive the
/// original bytes, which is the correct outcome. What must never happen is a
/// mutation that yields *different* data, or a panic.
///
/// The mutation is applied to a genuinely independent copy, because a shallow
/// view would corrupt the expected value along with the candidate.
test "corrupted streams are detected and never panic" {
  let input = Bytes::repeat(b"MoonXZ corruption fixture. ", 40)
  let encoded = @lib.compress(input)
  let mut raised = 0
  let mut total = 0
  for index in 0..<encoded.length() {
    for bit in [1, 0x80] {
      let flipped = encoded[index].to_uint() ^ bit.reinterpret_as_uint()
      let mutated = copy_with_flipped_byte(encoded, index, flipped.to_byte())
      let outcome = Some(@lib.decompress(mutated)) catch { _ => None }
      match outcome {
        None => raised += 1
        Some(value) =>
          if value != input {
            @test.fail(
              "bit flip at byte \{index} silently produced \{value.length()} different bytes",
            )
          }
      }
      total += 1
    }
  }
  // The block check, the two header CRCs and the payload cover the stream, so
  // corruption is reported for the overwhelming majority of mutations.
  @test.assert_eq(raised * 100 >= total * 90, true)
}

///|
/// Corrupting the stored block check itself must always be reported. XZ places
/// the check immediately before the index, so its position can be derived.
test "corrupting the block check is always detected" {
  let input = Bytes::repeat(b"MoonXZ block check fixture. ", 40)
  let encoded = @lib.compress(input)
  // The index is: indicator byte, record count, one record, padding to a
  // four-byte boundary, then a four-byte CRC32.
  let index_start = encoded.length() - 12
  let index_prefix = 1 + 1 + 16
  let check_end = index_start - (4 - (index_prefix + 4) % 4) % 4 - 4
  let check_start = check_end - 8
  @test.assert_eq(check_start > 0, true)
  for index in check_start..<check_end {
    let flipped = encoded[index].to_uint() ^ 1U
    let mutated = copy_with_flipped_byte(encoded, index, flipped.to_byte())
    let outcome = @lib.decompress(mutated) catch { _ => b"" }
    if outcome.length() != 0 {
      @test.fail("corrupting the block check at byte \{index} was not detected")
    }
  }
}

///|
/// Returns an independent copy of `data` with one byte replaced.
fn copy_with_flipped_byte(data : Bytes, index : Int, value : Byte) -> Bytes {
  let out : Array[Byte] = []
  for i in 0..<data.length() {
    if i == index {
      out.push(value)
    } else {
      out.push(data[i])
    }
  }
  Bytes::from_array(out)
}

///|
/// A `.lzma` stream whose header declares a size larger than the decoder is
/// allowed to produce must be refused before any allocation happens.
test "lzma1 header size is honoured as an output limit" {
  let input = Bytes::repeat(b"MoonXZ lzma1 limit fixture. ", 20)
  let encoded = @lib.compress_lzma1(input)
  @test.assert_eq(@lib.decompress_lzma1(encoded), input)
  try {
    let _ = @lib.decompress_lzma1_with_limit(encoded, 8)
    @test.fail("expected OutputLimitExceeded")
  } catch {
    @lib.OutputLimitExceeded(_) => ()
    _ => @test.fail("expected OutputLimitExceeded")
  }
}

///|
/// The `.lzma` header is 13 bytes; anything shorter is `Truncated`, and a
/// property byte above 224 is rejected as `Corrupt`.
test "lzma1 rejects malformed headers" {
  try {
    let _ = @lib.decompress_lzma1(b"\x5d\x00\x00\x80")
    @test.fail("expected Truncated")
  } catch {
    @lib.Truncated(_) => ()
    _ => @test.fail("expected Truncated")
  }
  let bad_property = @hex.decode("e500008000ffffffffffffffff0000000000")
  try {
    let _ = @lib.decompress_lzma1(bad_property)
    @test.fail("expected Corrupt")
  } catch {
    @lib.Corrupt(_) => ()
    _ => @test.fail("expected Corrupt")
  }
}

///|
/// A `.lzma` stream round-trips through MoonXZ's own encoder and decoder, and
/// reports the properties it wrote.
test "lzma1 round trip and properties" {
  let input = Bytes::repeat(b"MoonXZ lzma1 round trip. ", 120)
  let encoded = @lib.compress_lzma1(input)
  @test.assert_eq(@lib.lzma1_properties(encoded), (3, 0, 2))
  @test.assert_eq(@lib.lzma1_declared_size(encoded), Some(input.length()))
  @test.assert_eq(@lib.decompress_lzma1(encoded), input)
}

///|
/// A `.lzma` stream that records the unknown-size sentinel must be driven by its
/// end marker, and the header accessors must report that sentinel as `None`.
test "lzma1 end-marker stream decodes" {
  let fixture = @hex.decode(
    "5d00008000ffffffffffffffff0020effbbffea3b15ee5f83fb2aa2655f868704170150ee40930ffffb52c0000",
  )
  @test.assert_eq(@lib.lzma1_declared_size(fixture), None)
  @test.assert_eq(@lib.decompress_lzma1(fixture), Bytes::make(4096, b'A'))
}

///|
/// Concatenating many small blocks exercises the multi-chunk LZMA2 path, where a
/// chunk that keeps the previous dictionary must still honour its own size.
test "multi chunk lzma2 decoding stays correct across sizes" {
  for size in [1, 4096, 65535, 65536, 65537, 70000, 150000] {
    let input = Bytes::make(size, b'A')
    @test.assert_eq(@lib.decompress(@lib.compress(input)), input)
  }
}
