///|
/// Decodes a complete LZMA2 chunk sequence into a byte array.
///
/// The uncompressed size each chunk declares is cross-checked against the bytes
/// the chunk actually produced. That keeps a corrupted or inconsistent framing
/// from being silently ignored, which matters because a decoder that trusts only
/// the block header would otherwise accept streams whose two size records
/// disagree.
fn decode_lzma2(
  input : Bytes,
  dict_size : Int32,
  max_output : Int32,
) -> Bytes raise XzError {
  let cursor = ByteCursor::new(input)
  let output : Array[Byte] = []
  let decoder = LzmaDecoder::new(3, 0, 2)
  let mut dict_start = 0
  while cursor.remaining() > 0 {
    let control = cursor.read_u8()
    if control == 0 {
      break
    }
    if control == 1 || control == 2 {
      let size = cursor.read_u16_be().reinterpret_as_int() + 1
      if control == 1 {
        dict_start = output.length()
      }
      if output.length() + size > max_output {
        raise OutputLimitExceeded(max_output)
      }
      for _ in 0..<size {
        output.push(cursor.read_byte())
      }
      continue
    }
    if control < 0x80 {
      raise Corrupt("reserved LZMA2 chunk control byte")
    }
    // The size is an 18-bit field stored as 5 bits in the control byte followed
    // by 16 bits, encoding (uncompressed size - 1). The two halves must be
    // joined *before* the +1: adding one to the low half first lets a low half
    // of 0xFFFF carry into the high bits and be OR-ed away, which corrupts the
    // size for every chunk whose size is not a multiple of 65536. liblzma emits
    // exactly such chunks from 128 KiB upward, so decoding its output failed
    // even though all size fields were legal.
    let size_minus_one = ((control & 0x1F) << 16) |
      cursor.read_u16_be().reinterpret_as_int()
    let uncompressed_size = size_minus_one + 1
    let compressed_size = cursor.read_u16_be().reinterpret_as_int() + 1
    let reset_mode = control & 0x60
    let properties = if reset_mode >= 0x40 {
      Some(cursor.read_u8())
    } else {
      None
    }
    let compressed = cursor.read_bytes(compressed_size)
    if reset_mode == 0x60 {
      dict_start = output.length()
    }
    if properties is Some(value) {
      let (lc, lp, pb) = decode_lzma_properties(value)
      decoder.set_properties(lc, lp, pb)
    } else if reset_mode == 0x20 {
      decoder.reset_state()
    }
    if output.length() + uncompressed_size > max_output {
      raise OutputLimitExceeded(max_output)
    }
    let before_this_chunk = output.length()
    decoder.decode_chunk(
      compressed, uncompressed_size, output, dict_start, dict_size, max_output,
    )
    let produced = output.length() - before_this_chunk
    if produced != uncompressed_size {
      raise Corrupt(
        "LZMA2 chunk declared \{uncompressed_size} uncompressed bytes but produced \{produced}",
      )
    }
  }
  bytes_from_array(output)
}
