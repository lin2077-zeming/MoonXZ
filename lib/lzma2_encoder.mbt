///|
const LZMA2_PROPERTIES : Byte = b'\x5D'

///|
fn encode_lzma2(data : Bytes, options : CompressionOptions) -> Bytes {
  let output : Array[Byte] = Array(capacity=data.length())
  if data.length() == 0 {
    output.push(b'\x00')
    return Bytes::from_array(output)
  }
  let previous = build_match_chains(data)
  let depth = compression_depth(options.level)
  let mut offset = 0
  let mut first = true
  while offset < data.length() {
    let remaining = data.length() - offset
    let size = if remaining > MAX_UNCOMPRESSED_CHUNK {
      MAX_UNCOMPRESSED_CHUNK
    } else {
      remaining
    }
    let mut compressed : Bytes = b""
    if options.level > 0 {
      compressed = encode_lzma_chunk(
        data,
        offset,
        size,
        previous,
        depth,
        options.dict_size,
      )
    }
    if compressed.length() > 0 && compressed.length() + 3 < size {
      let uncompressed_minus_one = size - 1
      let control = (if first { 0xE0 } else { 0xC0 }) |
        ((uncompressed_minus_one >> 16) & 0x1F)
      output.push(control.to_byte())
      push_u16_be(
        output,
        (uncompressed_minus_one & 0xFFFF).reinterpret_as_uint(),
      )
      push_u16_be(output, (compressed.length() - 1).reinterpret_as_uint())
      output.push(LZMA2_PROPERTIES)
      append_bytes(output, compressed)
    } else {
      output.push(if first { b'\x01' } else { b'\x02' })
      push_u16_be(output, (size - 1).reinterpret_as_uint())
      for i in 0..<size {
        output.push(data[offset + i])
      }
    }
    offset += size
    first = false
  }
  output.push(b'\x00')
  Bytes::from_array(output)
}

///|
fn encode_lzma_chunk(
  data : Bytes,
  start : Int,
  size : Int,
  previous : Array[Int],
  depth : Int,
  dictionary_size : Int,
) -> Bytes {
  let range = RangeEncoder::new()
  let state = LzmaEncoder::new()
  let end = start + size
  let mut position = start
  while position < end {
    match find_match(data, position, end, previous, depth, dictionary_size) {
      Some(found) => {
        state.encode_match(range, found.distance, found.length, position)
        position += found.length
      }
      None => {
        state.encode_literal(range, data, position)
        position += 1
      }
    }
  }
  range.finish()
}

///|
fn dictionary_size_code(size : Int) -> Byte {
  let desired = if size < 4096 {
    4096
  } else if size > 1 << 30 {
    1 << 30
  } else {
    size
  }
  for code in 0..<41 {
    let capacity = if code == 40 {
      1 << 30
    } else {
      let base = 2 | (code & 1)
      let shift = 11 + (code >> 1)
      if shift >= 30 {
        1 << 30
      } else {
        base << shift
      }
    }
    if capacity >= desired {
      return code.to_byte()
    }
  }
  b'\x28'
}
