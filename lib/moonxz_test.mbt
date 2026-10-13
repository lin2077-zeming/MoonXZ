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
/// The x86 BCJ fixture below was produced by Python 3.14 `liblzma`, the same C
/// implementation `xz-utils` uses. The input starts with real branch
/// instructions and is padded, because `liblzma` skips the BCJ filter entirely
/// for inputs too short to contain a branch.
fn bcj_padding() -> Bytes {
  Bytes::make(60, b'\x00')
}

///|
/// ARM, ARM64, ARM-Thumb, PowerPC, SPARC and IA64 are all defined by the XZ
/// specification but are not shipped, so a block that uses one must be refused
/// rather than decoded to wrong bytes.
///
/// These ids were implemented and withdrawn. They either could not be aligned
/// with liblzma or silently corrupted data on inputs outside the test set, so the
/// only safe behaviour is a loud `Unsupported`. See `docs/DESIGN.md`.
test "unimplemented BCJ filters are reported as unsupported" {
  let fixtures : Array[String] = [
    // ARM (filter id 0x07)
    "fd377a585a000004e6d6b4460201070021011600a3f4a199e0004b00125d00010036114848dd5fb2ced1b14e74a30090000000000daf6ece7d4a1c1f00012e4cbcb1eb541fb6f37d010000000004595a",
    // ARM-Thumb (filter id 0x08)
     "fd377a585a000004e6d6b44602010800210116007646f76801001300f002f802f008f800f006f800bf00000000000000114951785f6bf4bb00012c14f80a6d031fb6f37d010000000004595a",
    // PowerPC (filter id 0x05)
     "fd377a585a000004e6d6b4460201050021011600a85569d4e00073000f5d0024002c030860b51ec5d45a4712a000000012a8ef35201abcf500012b7467fd9e011fb6f37d010000000004595a",
    // SPARC (filter id 0x09)
     "fd377a585a000004e6d6b4460201090021011600d395aba3e0004b000f5d0020002c0308607fe1714cd80caa8000000037f736463f2dbd1800012b4cf9459c291fb6f37d010000000004595a",
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
/// Feeds `encoded` to a streaming decoder one byte at a time and returns the
/// concatenation of every block it yielded.
///
/// One-byte feeds are the hardest case for a windowed parser: every internal
/// read lands on a partial field at some point, so a decoder that advances its
/// state before a unit is fully buffered will lose or duplicate data here.
fn decode_streaming_one_byte_at_a_time(
  encoded : Bytes,
  max_output : Int,
) -> Bytes raise @lib.XzError {
  let decoder = @lib.XzStreamDecoder::new(max_output~)
  let parts : Array[Bytes] = []
  for i in 0..<encoded.length() {
    decoder.supply(encoded[i:i + 1].to_owned())
    while true {
      match decoder.next() {
        Some(value) => parts.push(value)
        None => break
      }
    }
  }
  decoder.finish_input()
  while true {
    match decoder.next() {
      Some(value) => parts.push(value)
      None => break
    }
  }
  if !decoder.is_done() {
    raise @lib.Truncated("streaming decoder did not reach the footer")
  }
  if decoder.buffered() != 0 {
    raise @lib.Corrupt(
      "streaming decoder left \{decoder.buffered()} bytes buffered of \{encoded.length()}",
    )
  }
  let out : Array[Byte] = []
  for part in parts {
    for byte in part {
      out.push(byte)
    }
  }
  Bytes::from_array(out)
}

///|
test "streaming decoder matches one-shot decoding byte for byte" {
  let writer = @lib.XzWriter::new()
  let first = writer.write(Bytes::repeat(b"first block payload ", 300))
  let second = writer.write(Bytes::repeat(b"second block payload ", 300))
  let tail = writer.finish()
  let encoded = first + second + tail
  let expected = @lib.decompress(encoded)
  let streamed = decode_streaming_one_byte_at_a_time(encoded, 1 << 20)
  @test.assert_eq(streamed.length(), expected.length())
  @test.assert_eq(streamed, expected)
}

///|
test "streaming decoder handles an empty stream" {
  let writer = @lib.XzWriter::new()
  let encoded = writer.finish()
  let streamed = decode_streaming_one_byte_at_a_time(encoded, 1 << 20)
  @test.assert_eq(streamed, b"")
}

///|
test "streaming decoder handles concatenated streams and padding" {
  let writer = @lib.XzWriter::new()
  let first = writer.write(b"alpha") + writer.finish()
  let second = @lib.compress(b"beta")
  // Four zero bytes between streams are legal stream padding.
  let encoded = first + b"\x00\x00\x00\x00" + second
  let expected = @lib.decompress(encoded)
  let streamed = decode_streaming_one_byte_at_a_time(encoded, 1 << 20)
  @test.assert_eq(streamed, expected)
}

///|
test "streaming decoder reports truncation instead of hanging" {
  let encoded = @lib.compress(Bytes::repeat(b"truncate me ", 200))
  let cut = encoded[0:encoded.length() - 8].to_owned()
  let decoder = @lib.XzStreamDecoder::new()
  decoder.supply(cut)
  decoder.finish_input()
  let mut produced = 0
  try {
    while true {
      match decoder.next() {
        Some(value) => produced += value.length()
        None => break
      }
    }
    // Running out of input mid-stream must not look like a clean end.
    if decoder.is_done() {
      @test.fail("a truncated stream must not report completion")
    }
  } catch {
    @lib.Truncated(_) => ()
    @lib.ChecksumMismatch(_) => ()
    _ => @test.fail("unexpected error for a truncated stream")
  }
  ignore(produced)
}

///|
test "streaming decoder enforces the output limit" {
  let writer = @lib.XzWriter::new()
  let encoded = writer.write(b"0123456789") + writer.finish()
  let decoder = @lib.XzStreamDecoder::new(max_output=4)
  decoder.supply(encoded)
  decoder.finish_input()
  try {
    let _ = decoder.next()
    @test.fail("expected OutputLimitExceeded")
  } catch {
    @lib.OutputLimitExceeded(_) => ()
    _ => @test.fail("unexpected error")
  }
}

///|
/// Decodes a liblzma-produced stream whose single LZMA2 chunk declares an
/// uncompressed size at or above 64 KiB.
///
/// These are the fixtures that exposed the size-field carry bug. liblzma packs
/// (size - 1) as 5 bits in the control byte plus 16 low bits, and for any size
/// that is not a multiple of 65536 the low half is 0xFFFF: 128 KiB arrives as
/// control 0xE1 with a low half of 0xFFFF. Adding one to the low half before
/// joining the halves carries into bit 16 and is then OR-ed away, so the
/// declared size came out one high-half unit too large - 0x30000 instead of
/// 0x20000 for 128 KiB - and the chunk then disagreed with its own output.
///
/// Every size here is above the 64 KiB store bound, so all three go through the
/// compressed-chunk path that the earlier tests never reached.
test "decode Python lzma fixtures with chunks at or above 64 KiB" {
  // 128 KiB, control byte 0xE1.
  let fixture_128 = @hex.decode(
    "fd377a585a000004e6d6b4460200210116000000742fe5a3e1ef9500775d00269becdc582d64a5c3203af8e1810d8e16790d7610026c5a06bb08f3ed937634ccd39e1ac96967808912ae31e46fa83b274f92ba23e6744c1d2beb491b0b5be6e1ab3db023b0a3caa814645ce22697c5655e14ef7a9d45546b7d30275b3081dee2ff4468e735ff768f7c6f6c18be8407124e4b62bab60000001bf3af680526d3bf0001930196df070032c37834b1c467fb020000000004595a",
  )
  // 256 KiB, control byte 0xE3.
  let fixture_256 = @hex.decode(
    "fd377a585a000004e6d6b4460200210116000000742fe5a3e3df0d00895d00269becdc582d64a5c3203af8e1810d8e16790d7610026c5a06bb08f3ed937634ccd39e1ac96967808912ae31e46fa83b274f92ba23e6744c1d2beb491b0b5be6e1ab3db023b0a3caa814645ce22697c5655e14ef7a9d45546b7d30275b3081dee2ff4468e735ff768f7c6f6c18be8407124e8b0e384d84a5c2505491229706035fc9703ac2adcfcd0000000000eb147216db8713c90001a5018ebe0f00ed733af2b1c467fb020000000004595a",
  )
  // 1 MiB, control byte 0xEF.
  let fixture_1m = @hex.decode(
    "fd377a585a000004e6d6b4460200210116000000742fe5a3ef7bfb00f45d00269becdc582d64a5c3203af8e1810d8e16790d7610026c5a06bb08f3ed937634ccd39e1ac96967808912ae31e46fa83b274f92ba23e6744c1d2beb491b0b5be6e1ab3db023b0a3caa814645ce22697c5655e14ef7a9d45546b7d30275b3081dee2ff4468e735ff768f7c6f6c18be8407124e8b0e384d84a5c2505491229706035fc9703b14c0323798a51501a5e8a3092aecaaff5a26ac720c1692a7be398f24e1709ea7235fec28cb85d195988a7e2a91f22775f719c006984d98fdd8afd5900fc42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b04fddc401a0000fc35e6921f92148400019002fcf73d000a1520b2b1c467fb020000000004595a",
  )
  // The payload liblzma compressed: a 30-byte phrase repeated, which makes the
  // expected value exact without embedding a megabyte of bytes.
  let phrase = b"MoonXZ liblzma chunk fixture.\n"
  @test.assert_eq(phrase.length(), 30)
  @test.assert_eq(@lib.decompress(fixture_128), Bytes::repeat(phrase, 4229))
  @test.assert_eq(@lib.decompress(fixture_256), Bytes::repeat(phrase, 8457))
  @test.assert_eq(@lib.decompress(fixture_1m), Bytes::repeat(phrase, 33826))
}

///|
/// An empty input must round-trip through `.lzma` like every other format.
///
/// The encoder used to reject it outright, which made `compress_lzma1` the only
/// entry point that could not encode its own empty case. An empty payload is
/// legal: the header records a size of zero and the range encoder is finished,
/// and both liblzma and this decoder accept the result.
test "lzma1 encodes and decodes an empty input" {
  let encoded = @lib.compress_lzma1(b"")
  @test.assert_eq(@lib.decompress_lzma1(encoded), b"")
  // The header must be present and declare a zero size, not be omitted.
  @test.assert_eq(@lib.lzma1_declared_size(encoded), Some(0))
}

///|
/// Malformed inputs must be rejected, never panicked on.
///
/// The cases target the declared-length fields. A length read from the stream is
/// used to bound a copy, and the old check was written `pos + length >
/// data.length()`: a hostile length can make that sum overflow into a negative
/// number, which passes the check and lets the copy read past the buffer. The
/// check is now written as `length > remaining` so no term can overflow. These
/// inputs declare lengths far beyond the buffer to exercise that path, and the
/// requirement is simply that each one raises a handled error.
test "oversized declared lengths are rejected without panicking" {
  // A valid LZMA-alone header declaring an absurd uncompressed size.
  let huge_size : Array[Byte] = [
    b'\x5D', b'\x00', b'\x00', b'\x80', b'\x00', b'\xFF', b'\xFF', b'\xFF', b'\xFF',
    b'\xFF', b'\xFF', b'\xFF', b'\x7F',
  ]
  let mut rejected = 0
  let attempt = fn() -> Unit raise @lib.XzError {
    let _ = @lib.decompress_lzma1(Bytes::from_array(huge_size))
    ()
  }
  attempt() catch {
    _ => rejected += 1
  }
  @test.assert_eq(rejected, 1)
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

///|
/// Matches that reach across a 64 KiB LZMA2 chunk boundary exercise the
/// dictionary rules: a later chunk may keep the previous dictionary, while a
/// chunk that resets it may not.
///
/// A naive `"A" * n` input does not cover this, because all of its matches are at
/// distance 1, which is valid under every dictionary rule.
test "matches spanning chunk boundaries round trip" {
  // A one-off 70000-byte period repeated twice. Every long match is between the
  // two halves, at a distance larger than the old 64 KiB chunk size.
  let period = pseudo_random_bytes(0x5EEDU, 70000)
  let straddling = period + period
  @test.assert_eq(@lib.decompress(@lib.compress(straddling)), straddling)

  // A short period repeated far past the boundary, so matches cross many chunks.
  let repeated = pseudo_random_bytes(0xC0FFEEU, 100)
  let many = Bytes::repeat(repeated, 1400)
  @test.assert_eq(@lib.decompress(@lib.compress(many)), many)

  // Compressible regions on both sides of a boundary, with incompressible data
  // between them.
  let noise = pseudo_random_bytes(0xBEEFU, 200)
  let mixed = Bytes::make(65530, b'A') + noise + Bytes::make(65530, b'A')
  @test.assert_eq(@lib.decompress(@lib.compress(mixed)), mixed)
}

///|
/// Compression must actually shrink compressible data, and must not blow up
/// incompressible data.
///
/// This guards the chunk-size logic. A chunk declares its uncompressed size in 21
/// bits but its compressed size in 16, so a chunk that is both large and poorly
/// compressible cannot be represented; getting that wrong either produced invalid
/// streams above 65536 bytes or silently disabled compression for larger inputs.
/// Both regressions were real, so the boundaries are pinned here.
test "compression shrinks compressible input and stores incompressible input" {
  // Incompressible: barely any expansion is allowed, and it must round trip.
  for size in [65536, 65537, 100000, 131072, 140000, 300000] {
    let noise = pseudo_random_bytes(0x5EEDU, size)
    let encoded = @lib.compress(noise)
    @test.assert_eq(@lib.decompress(encoded), noise)
    // Only the chunk framing may be added.
    @test.assert_eq(
      encoded.length() <= noise.length() + size / 1024 + 128,
      true,
    )
  }

  // Compressible: the repetitive case must shrink to a small fraction, and the
  // ratio must not degrade as the input grows past the old 64 KiB chunk size.
  for size in [65536, 262144, 1048576] {
    let unit = b"MoonXZ compression ratio guard payload line.\n"
    let input = Bytes::repeat(unit, size / unit.length() + 1)[:size].to_owned()
    let encoded = @lib.compress_with_options(
      input,
      @lib.CompressionOptions::new(level=6),
    )
    @test.assert_eq(@lib.decompress(encoded), input)
    // A tenth of the input is a loose bound that still fails if the encoder
    // falls back to storing, which is what the 64 KiB chunking used to do.
    @test.assert_eq(encoded.length() * 10 < input.length(), true)
  }
}

///|
/// A tiny deterministic generator. The tests only need reproducible pseudo-random
/// bytes, so a plain xorshift keeps the suite dependency-free.
fn pseudo_random_bytes(seed : UInt, length : Int) -> Bytes {
  let out : Array[Byte] = Array(capacity=length)
  let mut state = if seed == 0U { 0x2545F491U } else { seed }
  for _ in 0..<length {
    state = state ^ (state << 13)
    state = state ^ (state >> 17)
    state = state ^ (state << 5)
    out.push((state & 0xFFU).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Random bytes are almost never a valid stream, so the decoder must reject them
/// through a typed error and never panic.
///
/// This is deliberately independent of the mutation sweep above: that one starts
/// from a valid stream and explores small changes, while this one explores inputs
/// with no valid structure at all, which is where length and offset arithmetic
/// tends to go wrong.
test "random bytes are rejected without panicking" {
  let mut seed : UInt = 1U
  for length in [0, 1, 5, 12, 13, 32, 64, 200, 1000] {
    for _ in 0..<12 {
      let junk = pseudo_random_bytes(seed, length)
      seed = seed + 0x9E3779B9U
      // A zero-length input is a legitimate empty stream: it decodes to nothing.
      // Anything longer has no valid structure and must be refused.
      let xz_outcome = Some(@lib.decompress(junk)) catch { _ => None }
      match xz_outcome {
        None => ()
        Some(value) =>
          if length > 0 || value.length() > 0 {
            @test.fail(
              "random \{length}-byte input decoded to \{value.length()} bytes",
            )
          }
      }
      let lzma_outcome = Some(@lib.decompress_lzma1(junk)) catch { _ => None }
      match lzma_outcome {
        None => ()
        Some(value) =>
          @test.fail(
            "random \{length}-byte lzma input decoded to \{value.length()} bytes",
          )
      }
    }
  }
}

///|
/// A stream whose header promises far more output than the input can produce must
/// fail on the output limit rather than exhausting memory.
test "declared size cannot force unbounded work" {
  // XZ stream header, then an LZMA2 chunk that declares a huge uncompressed size
  // but carries almost no payload.
  let header = @hex.decode("fd377a585a000004e6d6b44602")
  let block = @hex.decode("0100ffffffffffffffff5d00")
  let bomb = header + block
  try {
    let _ = @lib.decompress_with_limit(bomb, 64 * 1024 * 1024)
    @test.fail("expected a typed error for the truncated bomb")
  } catch {
    _ => ()
  }
}

///|
/// Repeats `unit` until exactly `length` bytes are produced.
fn repeat_to_length(unit : Bytes, length : Int) -> Bytes {
  let out : Array[Byte] = []
  if unit.length() == 0 {
    return Bytes::make(length, b'\x00')
  }
  while out.length() < length {
    for byte in unit {
      if out.length() < length {
        out.push(byte)
      }
    }
  }
  Bytes::from_array(out)
}

///|
/// Every filter must round trip across many lengths *and* several content shapes.
///
/// This is the test that was missing. The earlier filter coverage used one
/// convenient repeated pattern at one convenient length, and that combination hid
/// real defects: three BCJ filters corrupted data only for particular words, and
/// only once the payload grew past a few dozen bytes. Length alone is not enough
/// either, so each length is tried with zeros, text, pseudo-random content and a
/// payload built from real x86 branch instructions.
test "all filters round trip across lengths and content shapes" {
  let filters : Array[@lib.FilterMode] = [
    @lib.FilterMode::None,
    @lib.FilterMode::X86,
    @lib.FilterMode::Delta(1),
    @lib.FilterMode::Delta(8),
  ]
  let lengths : Array[Int] = [
    0, 1, 3, 4, 5, 8, 12, 16, 20, 24, 25, 26, 31, 32, 40, 64, 100, 200, 1000,
  ]
  let branches = @hex.decode("e800000000e9fbffffff90e801000000c3")
  for filter in filters {
    for length in lengths {
      let shapes : Array[Bytes] = [
        Bytes::make(length, b'\x00'),
        repeat_to_length(b"MoonXZ library consumer.\n", length),
        pseudo_random_bytes(0x5EEDU, length),
        pseudo_random_bytes(0xC0FFEEU, length),
        repeat_to_length(branches, length),
      ]
      for shape in shapes {
        let options = @lib.CompressionOptions::new(level=6, filter~)
        let encoded = @lib.compress_with_options(shape, options)
        let decoded = @lib.decompress(encoded) catch {
          _ => b"\x00decode failed"
        }
        @test.assert_eq(decoded, shape)
      }
    }
  }
}
