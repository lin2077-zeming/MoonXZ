///|
/// Incremental XZ writer.
///
/// Each call to `write` emits one complete XZ block. `finish` emits the
/// index and footer. The caller can send every returned `Bytes` directly to
/// a file, socket, or another stream sink.
pub struct XzWriter {
  check_kind : CheckKind
  options : CompressionOptions
  records : Array[(Int, Int)]
  mut started : Bool
  mut finished : Bool
}

///|
/// Creates a writer. `check_kind` selects the block check (CRC64 by default) and
/// `options` the compression parameters.
pub fn XzWriter::new(
  check_kind? : CheckKind = Crc64,
  options? : CompressionOptions = CompressionOptions::new(),
) -> XzWriter {
  { check_kind, options, records: [], started: false, finished: false, }
}

///|
/// Encodes `data` as one complete XZ block and returns the bytes to emit. The
/// first call also emits the stream header. Raises `Corrupt` once the writer has
/// been finished.
pub fn XzWriter::write(self : XzWriter, data : Bytes) -> Bytes raise XzError {
  if self.finished {
    raise Corrupt("XZ writer is already finished")
  }
  let output : Array[Byte] = []
  if !self.started {
    append_bytes(output, encode_stream_header(self.check_kind))
    self.started = true
  }
  if data.length() > 0 {
    let (block, unpadded, uncompressed) = encode_xz_block(
      data,
      self.options,
      self.check_kind,
    )
    append_bytes(output, block)
    self.records.push((unpadded, uncompressed))
  }
  bytes_from_array(output)
}

///|
/// Emits the XZ index and footer, completing the stream. Raises `Corrupt` if the
/// writer was already finished.
pub fn XzWriter::finish(self : XzWriter) -> Bytes raise XzError {
  if self.finished {
    raise Corrupt("XZ writer is already finished")
  }
  let output : Array[Byte] = []
  if !self.started {
    append_bytes(output, encode_stream_header(self.check_kind))
    self.started = true
  }
  let index = encode_index(self.records)
  append_bytes(output, index)
  append_bytes(output, encode_footer(index.length(), self.check_kind))
  self.finished = true
  bytes_from_array(output)
}

///|
/// Incremental XZ reader over an in-memory compressed byte sequence.
pub struct XzReader {
  cursor : ByteCursor
  max_output : Int
  mut output_so_far : Int
  mut check_kind : CheckKind?
  records : Array[(Int, Int)]
  mut stream_open : Bool
  mut done : Bool
}

///|
/// Creates a reader over an in-memory XZ stream. `max_output` bounds the total
/// decoded size across all blocks, so a hostile stream cannot exhaust memory.
pub fn XzReader::new(input : Bytes, max_output? : Int = 1 << 30) -> XzReader {
  {
    cursor: ByteCursor::new(input),
    max_output,
    output_so_far: 0,
    check_kind: None,
    records: [],
    stream_open: false,
    done: false,
  }
}

///|
/// Reads and decodes the next XZ block. Returns `None` after the final
/// stream footer has been validated.
pub fn XzReader::read_block(self : XzReader) -> Bytes? raise XzError {
  if self.done {
    return None
  }
  while true {
    if !self.stream_open {
      if self.cursor.remaining() >= 4 &&
        self.cursor.data[self.cursor.pos] == b'\x00' &&
        self.cursor.data[self.cursor.pos + 1] == b'\x00' &&
        self.cursor.data[self.cursor.pos + 2] == b'\x00' &&
        self.cursor.data[self.cursor.pos + 3] == b'\x00' {
        self.cursor.pos += 4
        continue
      }
      if self.cursor.remaining() == 0 {
        self.done = true
        return None
      }
      self.check_kind = Some(read_stream_header(self.cursor))
      self.records.clear()
      self.stream_open = true
    }
    if self.cursor.remaining() == 0 {
      raise Truncated("XZ stream ended before its index")
    }
    if self.cursor.peek_byte() == b'\x00' {
      let check_kind = match self.check_kind {
        Some(value) => value
        None => raise Corrupt("XZ stream has no active header")
      }
      let index_size = parse_index(self.cursor, self.records)
      let footer_start = self.cursor.pos
      let footer_crc = self.cursor.read_u32_le()
      let backward_size = self.cursor.read_u32_le()
      let flags0 = self.cursor.read_byte()
      let flags1 = self.cursor.read_byte()
      let footer_magic = self.cursor.read_bytes(2)
      if footer_magic != XZ_FOOTER_MAGIC {
        raise InvalidHeader("invalid XZ footer magic")
      }
      let footer_body = self.cursor.data[footer_start + 4:footer_start + 10].to_owned()
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
      self.stream_open = false
      self.check_kind = None
      continue
    }

    let check_kind = match self.check_kind {
      Some(value) => value
      None => raise Corrupt("XZ stream has no active header")
    }
    let header_size_byte = self.cursor.peek_byte().to_int()
    let header_length = (header_size_byte + 1) * 4
    if header_length < 8 || header_length > MAX_BLOCK_HEADER {
      raise Corrupt("invalid XZ block header size")
    }
    let header = self.cursor.read_bytes(header_length)
    let (compressed_size_opt, uncompressed_size_opt, header_length, filters) = parse_block_header(
      header,
    )
    let compressed_size = match compressed_size_opt {
      Some(value) => value
      None => scan_lzma2_size(self.cursor.data, self.cursor.pos)
    }
    match uncompressed_size_opt {
      Some(expected) =>
        if self.output_so_far + expected > self.max_output {
          raise OutputLimitExceeded(self.max_output)
        }
      None => ()
    }
    let compressed = self.cursor.read_bytes(compressed_size)
    let filtered = decode_lzma2(
      compressed,
      filter_dict_size(filters),
      self.max_output - self.output_so_far,
    )
    let decoded = decode_filter_chain(filters, filtered)
    match uncompressed_size_opt {
      Some(expected) =>
        if decoded.length() != expected {
          raise Corrupt("XZ block uncompressed size mismatch")
        }
      None => ()
    }
    let padding = (4 - compressed_size % 4) % 4
    for _ in 0..<padding {
      if self.cursor.read_byte() != b'\x00' {
        raise Corrupt("non-zero XZ block padding")
      }
    }
    let stored_check = self.cursor.read_bytes(check_kind.size())
    if stored_check != check_bytes(check_kind, decoded) {
      raise ChecksumMismatch("XZ block checksum mismatch")
    }
    let unpadded = header_length + compressed_size + check_kind.size()
    self.records.push((unpadded, decoded.length()))
    self.output_so_far += decoded.length()
    return Some(decoded)
  } nobreak {
    None
  }
}
