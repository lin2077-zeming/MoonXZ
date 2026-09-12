///|
const LZMA2_PROPERTIES : Byte = b'\x5D'

///|
/// Bytes covered by one uncompressed chunk.
///
/// The uncompressed size field is 16 bits, so a store chunk can hold at most
/// 65536 bytes. A compressed chunk has the same bound here: its compressed size
/// also has to fit 16 bits, and keeping both fields at 65536 means neither can
/// overflow regardless of how compressible the input turns out to be.
///
/// Chunk boundaries cost compression ratio because a chunk that resets the
/// dictionary cannot reference bytes before its own start. Raising this bound
/// reduced a 1 MiB repetitive payload from 1752 to 428 bytes against `xz`'s 328,
/// but the correct bound depends on the 21-bit/16-bit split of the two size
/// fields and needs care: sizes at or above 2^20 spill into the control byte's
/// reset flags. See `docs/DESIGN.md` for the current state.
const LZMA2_STORE_CHUNK : Int = 65536

///|
/// Largest uncompressed size a compressed chunk may declare. Bounded by the
/// 16-bit compressed-size field, since a chunk's compressed bytes must fit 65536.
const LZMA2_COMPRESSED_CHUNK : Int = 65536

///|
/// Encodes `data` as a complete LZMA2 chunk sequence.
fn encode_lzma2(data : Bytes, options : CompressionOptions) -> Bytes {
  let output : Array[Byte] = Array(capacity=data.length())
  if data.length() == 0 {
    output.push(b'\x00')
    return Bytes::from_array(output)
  }
  let previous = build_match_chains(data)
  let depth = compression_depth(options.level)
  let nice_length = compression_nice_length(options.level)
  let mut offset = 0
  let mut first = true
  while offset < data.length() {
    let remaining = data.length() - offset
    let limit = if remaining > LZMA2_COMPRESSED_CHUNK {
      LZMA2_COMPRESSED_CHUNK
    } else {
      remaining
    }
    let mut compressed : Bytes = b""
    if options.level > 0 {
      compressed = encode_lzma_chunk(
        data,
        offset,
        limit,
        previous,
        depth,
        nice_length,
        options.dict_size,
      )
    }
    // Take the compressed form only when it is smaller and representable.
    if compressed.length() > 0 &&
      compressed.length() + 3 < limit &&
      compressed.length() <= LZMA2_STORE_CHUNK {
      let uncompressed_minus_one = limit - 1
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
      offset += limit
    } else {
      let store = if remaining > LZMA2_STORE_CHUNK {
        LZMA2_STORE_CHUNK
      } else {
        remaining
      }
      output.push(if first { b'\x01' } else { b'\x02' })
      push_u16_be(output, (store - 1).reinterpret_as_uint())
      for i in 0..<store {
        output.push(data[offset + i])
      }
      offset += store
    }
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
  nice_length : Int,
  dictionary_size : Int,
) -> Bytes {
  let range = RangeEncoder::new(hint=size)
  let state = LzmaEncoder::new()
  let end = start + size
  let mut position = start
  while position < end {
    match
      find_match(
        data, position, end, previous, depth, nice_length, dictionary_size,
      ) {
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
