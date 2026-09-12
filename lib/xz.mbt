///|
const XZ_MAGIC : Bytes = b"\xFD7zXZ\x00"

///|
const XZ_FOOTER_MAGIC : Bytes = b"YZ"

///|
const LZMA2_FILTER_ID : UInt64 = 0x21UL

///|
/// XZ filter id for the delta filter.
const DELTA_FILTER_ID : UInt64 = 0x03UL

///|
/// XZ filter id for the x86 BCJ filter.
const X86_FILTER_ID : UInt64 = 0x04UL

///|
/// XZ filter id for the PowerPC BCJ filter.
const POWERPC_FILTER_ID : UInt64 = 0x05UL

///|
/// XZ filter id for the IA64 BCJ filter, which MoonXZ reports as unsupported.
const IA64_FILTER_ID : UInt64 = 0x06UL

///|
/// XZ filter id for the ARM BCJ filter.
const ARM_FILTER_ID : UInt64 = 0x07UL

///|
/// XZ filter id for the ARM-Thumb BCJ filter. MoonXZ reports it as unsupported
/// because the 21-bit halfword packing is not implemented.
const ARMTHUMB_FILTER_ID : UInt64 = 0x08UL

///|
/// XZ filter id for the SPARC BCJ filter.
const SPARC_FILTER_ID : UInt64 = 0x09UL

///|
/// XZ filter id for the ARM64 (AArch64) BCJ filter.
const ARM64_FILTER_ID : UInt64 = 0x0AUL

///|
const MAX_BLOCK_HEADER : Int = 1024

///|
const MAX_UNCOMPRESSED_CHUNK : Int = 65536

///|
priv struct FilterSpec {
  id : UInt64
  properties : Bytes
}

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
/// Human-readable name of a filter id, used in error messages.
fn filter_id_name(id : UInt64) -> String {
  if id == DELTA_FILTER_ID {
    "delta"
  } else if id == X86_FILTER_ID {
    "x86"
  } else if id == POWERPC_FILTER_ID {
    "powerpc"
  } else if id == IA64_FILTER_ID {
    "ia64"
  } else if id == ARM_FILTER_ID {
    "arm"
  } else if id == ARMTHUMB_FILTER_ID {
    "armthumb"
  } else if id == SPARC_FILTER_ID {
    "sparc"
  } else if id == ARM64_FILTER_ID {
    "arm64"
  } else if id == LZMA2_FILTER_ID {
    "lzma2"
  } else {
    "unknown"
  }
}

///|
/// Turns a non-LZMA2 filter id plus its property bytes into a `FilterMode`.
///
/// This is the single place where XZ filter ids are mapped onto MoonXZ filter
/// implementations, so block-header validation and filter application can never
/// disagree about which ids are supported. The property requirements come from
/// the filter definitions in the XZ specification:
///
/// - delta takes exactly one byte, the distance minus one
/// - x86 takes no properties
/// - every other BCJ id is recognized but reported as `Unsupported`
fn filter_mode_of(id : UInt64, properties : Bytes) -> FilterMode raise XzError {
  if id == DELTA_FILTER_ID {
    if properties.length() != 1 {
      raise Corrupt("delta filter must have exactly one property byte")
    }
    Delta(properties[0].to_int() + 1)
  } else if id == X86_FILTER_ID {
    if properties.length() != 0 {
      raise Corrupt("x86 BCJ filter must have no properties")
    }
    X86
  } else if id == ARM_FILTER_ID {
    raise Unsupported("the ARM BCJ filter is not implemented")
  } else if id == ARM64_FILTER_ID {
    raise Unsupported("the ARM64 BCJ filter is not implemented")
  } else if id == ARMTHUMB_FILTER_ID {
    raise Unsupported("the ARM-Thumb BCJ filter is not implemented")
  } else if id == POWERPC_FILTER_ID {
    raise Unsupported("the PowerPC BCJ filter is not implemented")
  } else if id == SPARC_FILTER_ID {
    raise Unsupported("the SPARC BCJ filter is not implemented")
  } else if id == IA64_FILTER_ID {
    raise Unsupported("the IA64 BCJ filter is not implemented")
  } else {
    raise Unsupported("unsupported XZ filter id \{id}")
  }
}

///|
fn parse_block_header(
  header : Bytes,
) -> (Int?, Int?, Int, Array[FilterSpec]) raise XzError {
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
  if filter_count < 1 || filter_count > 2 {
    raise Unsupported(
      "only XZ filter chains with one or two filters are supported",
    )
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
  let filters : Array[FilterSpec] = []
  for filter_index in 0..<filter_count {
    let filter_id = body.read_vli()
    let properties_size = usize_of_u64(
      body.read_vli(),
      "filter properties size",
    )
    let properties = body.read_bytes(properties_size)
    if filter_id == LZMA2_FILTER_ID {
      if filter_index != filter_count - 1 || properties_size != 1 {
        raise Corrupt("LZMA2 must be the final one-byte filter")
      }
    } else if filter_index != 0 || filter_count != 2 {
      raise Corrupt(
        "\{filter_id_name(filter_id)} filter must be the first of a two-filter chain",
      )
    } else {
      // Validates the property count for this filter id.
      let _ = filter_mode_of(filter_id, properties)
    }
    filters.push({ id: filter_id, properties, })
  }
  while body.remaining() > 0 {
    if body.read_byte() != b'\x00' {
      raise Corrupt("non-zero XZ block header padding")
    }
  }
  (compressed_size, uncompressed_size, length, filters)
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
fn filter_dict_size(filters : Array[FilterSpec]) -> Int raise XzError {
  if filters.length() == 0 {
    raise Corrupt("XZ block has no filter chain")
  }
  let lzma2 = filters[filters.length() - 1]
  if lzma2.id != LZMA2_FILTER_ID || lzma2.properties.length() != 1 {
    raise Corrupt("XZ block does not end with LZMA2")
  }
  decode_dict_size(lzma2.properties[0])
}

///|
fn decode_filter_chain(
  filters : Array[FilterSpec],
  data : Bytes,
) -> Bytes raise XzError {
  let mut result = data
  for index in 0..<(filters.length() - 1) {
    let filter = filters[filters.length() - 2 - index]
    let mode = filter_mode_of(filter.id, filter.properties)
    result = decode_filter(result, mode)
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
      let (compressed_size_opt, uncompressed_size_opt, header_length, filters) = parse_block_header(
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
      let filtered = decode_lzma2(
        compressed,
        filter_dict_size(filters),
        max_output - output.length(),
      )
      // The LZMA2 chunk framing repeats the payload length that the block header
      // already declared. Cross-checking both keeps a corrupted or inconsistent
      // framing from being silently ignored.
      let consumed = scan_lzma2_size(compressed, 0)
      if consumed != compressed_size {
        raise Corrupt(
          "XZ block LZMA2 framing covers \{consumed} bytes but the block header declared \{compressed_size}",
        )
      }
      let decoded = decode_filter_chain(filters, filtered)
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
fn encode_stream_header(check_kind : CheckKind) -> Bytes {
  let out : Array[Byte] = []
  append_bytes(out, XZ_MAGIC)
  let stream_flags = Bytes::from_array([b'\x00', check_kind.id().to_byte()])
  append_bytes(out, stream_flags)
  push_u32_le(out, crc32(stream_flags))
  bytes_from_array(out)
}

///|
/// Writes a filter id plus its (empty) property list into a block header.
///
/// Filter ids are variable-length integers, but every id MoonXZ supports except
/// LZMA2 fits in a single byte, so the id is written directly.
fn push_propertyless_filter(header : Array[Byte], id : UInt64) -> Unit {
  header.push(id.to_byte())
  header.push(b'\x00')
}

///|
fn encode_xz_block(
  data : Bytes,
  options : CompressionOptions,
  check_kind : CheckKind,
) -> (Bytes, Int, Int) {
  let out : Array[Byte] = []
  let filtered = encode_filter(data, options.filter)
  let lzma2 = encode_lzma2(filtered, options)
  let compressed_size = lzma2.length()
  let uncompressed_size = data.length()

  let block_header : Array[Byte] = []
  block_header.push(b'\x00')
  block_header.push(if options.filter is None { b'\xC0' } else { b'\xC1' })
  push_vli(block_header, compressed_size.to_uint64())
  push_vli(block_header, uncompressed_size.to_uint64())
  match options.filter {
    None => ()
    Delta(distance) => {
      block_header.push(DELTA_FILTER_ID.to_byte())
      block_header.push(b'\x01')
      block_header.push((normalize_delta_distance(distance) - 1).to_byte())
    }
    X86 => push_propertyless_filter(block_header, X86_FILTER_ID)
  }
  block_header.push(LZMA2_FILTER_ID.to_byte())
  block_header.push(b'\x01')
  block_header.push(dictionary_size_code(options.dict_size))
  while block_header.length() % 4 != 0 {
    block_header.push(b'\x00')
  }
  block_header[0] = ((block_header.length() + 4) / 4 - 1).to_byte()
  push_u32_le(block_header, crc32(bytes_from_array(block_header)))
  append_bytes(out, bytes_from_array(block_header))
  append_bytes(out, lzma2)
  while out.length() % 4 != 0 {
    out.push(b'\x00')
  }
  let check_size = check_kind.size()
  append_bytes(out, check_bytes(check_kind, data))
  let unpadded = block_header.length() + compressed_size + check_size
  (bytes_from_array(out), unpadded, uncompressed_size)
}

///|
fn encode_index(records : Array[(Int, Int)]) -> Bytes {
  let index : Array[Byte] = [b'\x00']
  push_vli(index, records.length().to_uint64())
  for record in records {
    push_vli(index, record.0.to_uint64())
    push_vli(index, record.1.to_uint64())
  }
  while index.length() % 4 != 0 {
    index.push(b'\x00')
  }
  push_u32_le(index, crc32(bytes_from_array(index)))
  bytes_from_array(index)
}

///|
fn encode_footer(index_size : Int, check_kind : CheckKind) -> Bytes {
  let footer : Array[Byte] = []
  push_u32_le(footer, (index_size / 4 - 1).reinterpret_as_uint())
  footer.push(b'\x00')
  footer.push(check_kind.id().to_byte())
  let footer_crc = crc32(bytes_from_array(footer))
  let footer_with_crc : Array[Byte] = []
  push_u32_le(footer_with_crc, footer_crc)
  append_bytes(footer_with_crc, bytes_from_array(footer))
  append_bytes(footer_with_crc, XZ_FOOTER_MAGIC)
  bytes_from_array(footer_with_crc)
}

///|
fn encode_xz(
  data : Bytes,
  options : CompressionOptions,
  check_kind : CheckKind,
) -> Bytes {
  let out : Array[Byte] = []
  append_bytes(out, encode_stream_header(check_kind))
  let records : Array[(Int, Int)] = []
  if data.length() > 0 {
    let (block, unpadded, uncompressed) = encode_xz_block(
      data, options, check_kind,
    )
    append_bytes(out, block)
    records.push((unpadded, uncompressed))
  }
  let index = encode_index(records)
  append_bytes(out, index)
  append_bytes(out, encode_footer(index.length(), check_kind))
  bytes_from_array(out)
}
