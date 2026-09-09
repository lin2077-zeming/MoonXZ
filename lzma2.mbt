///|
/// Decodes a complete LZMA2 chunk sequence into a byte array.
fn decode_lzma2(
  input : Bytes,
  dict_size : Int,
  max_output : Int,
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
    let uncompressed_size = ((control & 0x1F) << 16) |
      (cursor.read_u16_be().reinterpret_as_int() + 1)
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
    decoder.decode_chunk(
      compressed, uncompressed_size, output, dict_start, dict_size,
    )
  }
  bytes_from_array(output)
}
