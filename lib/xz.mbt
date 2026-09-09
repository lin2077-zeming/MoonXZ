///|
const XZ_MAGIC : Bytes = b"\xFD7zXZ\x00"

///|
const XZ_FOOTER_MAGIC : Bytes = b"YZ"

///|
const LZMA2_FILTER_ID : UInt64 = 0x21UL

///|
const MAX_BLOCK_HEADER : Int = 1024

///|
const MAX_UNCOMPRESSED_CHUNK : Int = 65536

///|
fn decode_dict_size(code : Byte) -> Int raise XzError {
  let value = code.to_int()
  if value > 40 {
    raise Unsupported("invalid LZMA2 dictionary size code")
  }
  if value == 40 {
    return 1 << 30
  }
  let base = 2 | (value & 1)
  let shift = 11 + (value >> 1)
  if shift >= 30 {
    return 1 << 30
  }
  base << shift
}

///|
fn append_bytes(target : Array[Byte], source : Bytes) -> Unit {
  for byte in source {
    target.push(byte)
  }
}

///|
fn read_stream_header(cursor : ByteCursor) -> CheckKind raise XzError {
  let magic = cursor.read_bytes(6)
  if magic != XZ_MAGIC {
    raise InvalidHeader("invalid XZ stream magic")
  }
  let flags0 = cursor.read_byte()
  let flags1 = cursor.read_byte()
  let expected_crc = cursor.read_u32_le()
  let flags = Bytes::from_array([flags0, flags1])
  let actual_crc = crc32(flags)
  if actual_crc != expected_crc {
    raise ChecksumMismatch("XZ stream header checksum mismatch")
  }
  if flags0 != b'\x00' {
    raise InvalidHeader("reserved XZ stream flags are set")
  }
  match CheckKind::from_id(flags1.to_int()) {
    Some(kind) => kind
    None => raise Unsupported("unsupported XZ check type \{flags1.to_int()}")
  }
}

///|
fn parse_block_header(header : Bytes) -> (Int?, Int?, Int, Int) raise XzError {
  let length = header.length()
  if length < 8 || length > MAX_BLOCK_HEADER || length % 4 != 0 {
    raise Corrupt("invalid XZ block header length")
  }
  let expected_crc = header[length - 4:].to_owned()
  let actual_crc = check_bytes(Crc32, header[0:length - 4].to_owned())
  if actual_crc != expected_crc {
    raise ChecksumMismatch("XZ block header checksum mismatch")
  }

  let body = ByteCursor::new(header[1:length - 4].to_owned())
  let flags = body.read_u8()
  if (flags & 0x3C) != 0 {
    raise Corrupt("reserved XZ block flags are set")
  }
  let filter_count = (flags & 0x03) + 1
  if filter_count != 1 {
    raise Unsupported("only a single LZMA2 filter is supported")
  }
  let compressed_size = if (flags & 0x40) != 0 {
    Some(usize_of_u64(body.read_vli(), "compressed size"))
  } else {
    None
  }
  let uncompressed_size = if (flags & 0x80) != 0 {
    Some(usize_of_u64(body.read_vli(), "uncompressed size"))
  } else {
    None
  }
  let filter_id = body.read_vli()
  if filter_id != LZMA2_FILTER_ID {
    raise Unsupported("unsupported XZ filter id \{filter_id}")
  }
  let properties_size = usize_of_u64(body.read_vli(), "filter properties size")
  if properties_size != 1 {
    raise Corrupt("LZMA2 filter must have one property byte")
  }
  let properties = body.read_byte()
  while body.remaining() > 0 {
    if body.read_byte() != b'\x00' {
      raise Corrupt("non-zero XZ block header padding")
    }
  }
  (compressed_size, uncompressed_size, length, decode_dict_size(properties))
}

///|
fn scan_lzma2_size(data : Bytes, start : Int) -> Int raise XzError {
  let cursor = ByteCursor::new(data)
  cursor.pos = start
  let mut result = 0
  while true {
    let control = cursor.read_u8()
    if control == 0 {
      result = cursor.pos - start
      break
    }
    if control == 1 || control == 2 {
      let size = cursor.read_u16_be().reinterpret_as_int() + 1
      cursor.skip(size)
      continue
    }
    if control < 0x80 {
      raise Corrupt("reserved LZMA2 chunk control byte")
    }
    let _uncompressed_size = ((control & 0x1F) << 16) |
      (cursor.read_u16_be().reinterpret_as_int() + 1)
    let compressed_size = cursor.read_u16_be().reinterpret_as_int() + 1
    if (control & 0x40) != 0 {
      let _ = cursor.read_byte()
    }
    cursor.skip(compressed_size)
  }
  result
}

///|
fn parse_index(
  cursor : ByteCursor,
  expected : Array[(Int, Int)],
) -> Int raise XzError {
  let index_start = cursor.pos
  let indicator = cursor.read_u8()
  if indicator != 0 {
    raise Corrupt("missing XZ index indicator")
  }
  let count = usize_of_u64(cursor.read_vli(), "index record count")
  if count != expected.length() {
    raise Corrupt("XZ index record count mismatch")
  }
  for i in 0..<count {
    let unpadded = usize_of_u64(cursor.read_vli(), "index unpadded size")
    let uncompressed = usize_of_u64(
      cursor.read_vli(),
      "index uncompressed size",
    )
    if unpadded != expected[i].0 || uncompressed != expected[i].1 {
      raise Corrupt("XZ index record mismatch")
    }
  }
  while (cursor.pos - index_start) % 4 != 0 {
    if cursor.read_byte() != b'\x00' {
      raise Corrupt("non-zero XZ index padding")
    }
  }
  let index_end = cursor.pos
  let expected_crc = cursor.read_u32_le()
  let actual_crc = crc32(cursor.data[index_start:index_end].to_owned())
  if actual_crc != expected_crc {
    raise ChecksumMismatch("XZ index checksum mismatch")
  }
  cursor.pos - index_start
}

///|
fn decode_xz(input : Bytes, max_output : Int) -> Bytes raise XzError {
  let cursor = ByteCursor::new(input)
  let output : Array[Byte] = []
  while cursor.remaining() > 0 {
    if cursor.remaining() >= 4 &&
      cursor.data[cursor.pos] == b'\x00' &&
      cursor.data[cursor.pos + 1] == b'\x00' &&
      cursor.data[cursor.pos + 2] == b'\x00' &&
      cursor.data[cursor.pos + 3] == b'\x00' {
      cursor.pos += 4
      continue
    }
    let check_kind = read_stream_header(cursor)
    let records : Array[(Int, Int)] = []
    while true {
      if cursor.remaining() == 0 {
        raise Truncated("XZ stream ended before its index")
      }
      let header_size_byte = cursor.peek_byte().to_int()
      if header_size_byte == 0 {
        let index_size = parse_index(cursor, records)
        let footer_start = cursor.pos
        let footer_crc = cursor.read_u32_le()
        let backward_size = cursor.read_u32_le()
        let flags0 = cursor.read_byte()
        let flags1 = cursor.read_byte()
        let footer_magic = cursor.read_bytes(2)
        if footer_magic != XZ_FOOTER_MAGIC {
          raise InvalidHeader("invalid XZ footer magic")
        }
        let footer_body = cursor.data[footer_start + 4:footer_start + 10].to_owned()
        if crc32(footer_body) != footer_crc {
          raise ChecksumMismatch("XZ footer checksum mismatch")
        }
        if backward_size.reinterpret_as_int() + 1 != index_size / 4 {
          raise Corrupt("XZ footer backward size mismatch")
        }
        if flags0 != b'\x00' ||
          CheckKind::from_id(flags1.to_int()) != Some(check_kind) {
          raise Corrupt("XZ footer flags mismatch")
        }
        break
      }

      let header_length = (header_size_byte + 1) * 4
      if header_length < 8 || header_length > MAX_BLOCK_HEADER {
        raise Corrupt("invalid XZ block header size")
      }
      let header = cursor.read_bytes(header_length)
      let (compressed_size_opt, uncompressed_size_opt, header_length, dict_size) = parse_block_header(
        header,
      )
      let compressed_size = match compressed_size_opt {
        Some(value) => value
        None => scan_lzma2_size(cursor.data, cursor.pos)
      }
      match uncompressed_size_opt {
        Some(expected) =>
          if output.length() + expected > max_output {
            raise OutputLimitExceeded(max_output)
          }
        None => ()
      }
      let compressed = cursor.read_bytes(compressed_size)
      let decoded = decode_lzma2(
        compressed,
        dict_size,
        max_output - output.length(),
      )
      match uncompressed_size_opt {
        Some(expected) =>
          if decoded.length() != expected {
            raise Corrupt("XZ block uncompressed size mismatch")
          }
        None => ()
      }
      append_bytes(output, decoded)
      let padding = (4 - compressed_size % 4) % 4
      for _ in 0..<padding {
        if cursor.read_byte() != b'\x00' {
          raise Corrupt("non-zero XZ block padding")
        }
      }
      let stored_check = cursor.read_bytes(check_kind.size())
      let computed_check = check_bytes(check_kind, decoded)
      if stored_check != computed_check {
        raise ChecksumMismatch("XZ block checksum mismatch")
      }
      let unpadded = header_length + compressed_size + check_kind.size()
      records.push((unpadded, decoded.length()))
    }
  }
  bytes_from_array(output)
}

///|
fn encode_xz_store(data : Bytes, check_kind : CheckKind) -> Bytes {
  let out : Array[Byte] = []
  append_bytes(out, XZ_MAGIC)
  let stream_flags = Bytes::from_array([b'\x00', check_kind.id().to_byte()])
  append_bytes(out, stream_flags)
  push_u32_le(out, crc32(stream_flags))

  let lzma2 : Array[Byte] = []
  if data.length() > 0 {
    let mut offset = 0
    let mut first = true
    while offset < data.length() {
      let size = if data.length() - offset > MAX_UNCOMPRESSED_CHUNK {
        MAX_UNCOMPRESSED_CHUNK
      } else {
        data.length() - offset
      }
      lzma2.push(if first { b'\x01' } else { b'\x02' })
      lzma2.push((((size - 1) >> 8) & 0xFF).to_byte())
      lzma2.push(((size - 1) & 0xFF).to_byte())
      for i in 0..<size {
        lzma2.push(data[offset + i])
      }
      offset += size
      first = false
    }
  }
  lzma2.push(b'\x00')
  let compressed_size = lzma2.length()
  let uncompressed_size = data.length()

  let block_header : Array[Byte] = []
  block_header.push(b'\x00')
  block_header.push(b'\xC0')
  push_vli(block_header, compressed_size.to_uint64())
  push_vli(block_header, uncompressed_size.to_uint64())
  block_header.push(LZMA2_FILTER_ID.to_byte())
  block_header.push(b'\x01')
  block_header.push(b'\x00')
  while block_header.length() % 4 != 0 {
    block_header.push(b'\x00')
  }
  block_header[0] = ((block_header.length() + 4) / 4 - 1).to_byte()
  push_u32_le(block_header, crc32(bytes_from_array(block_header)))
  append_bytes(out, bytes_from_array(block_header))
  append_bytes(out, bytes_from_array(lzma2))
  while out.length() % 4 != 0 {
    out.push(b'\x00')
  }
  append_bytes(out, check_bytes(check_kind, data))

  let index : Array[Byte] = [b'\x00', b'\x01']
  let check_size = check_kind.size()
  let block_unpadded = block_header.length() + compressed_size + check_size
  push_vli(index, block_unpadded.to_uint64())
  push_vli(index, uncompressed_size.to_uint64())
  while index.length() % 4 != 0 {
    index.push(b'\x00')
  }
  push_u32_le(index, crc32(bytes_from_array(index)))
  append_bytes(out, bytes_from_array(index))

  let footer : Array[Byte] = []
  push_u32_le(footer, (index.length() / 4 - 1).reinterpret_as_uint())
  footer.push(b'\x00')
  footer.push(check_kind.id().to_byte())
  let footer_crc = crc32(bytes_from_array(footer))
  let footer_with_crc : Array[Byte] = []
  push_u32_le(footer_with_crc, footer_crc)
  append_bytes(footer_with_crc, bytes_from_array(footer))
  append_bytes(footer_with_crc, XZ_FOOTER_MAGIC)
  append_bytes(out, bytes_from_array(footer_with_crc))
  bytes_from_array(out)
}
