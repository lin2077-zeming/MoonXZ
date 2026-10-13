///|
/// Incremental XZ writer.
///
/// Each call to `write` emits one complete XZ block. `finish` emits the
/// index and footer. The caller can send every returned `Bytes` directly to
/// a file, socket, or another stream sink.
pub struct XzWriter {
  check_kind : CheckKind
  options : CompressionOptions
  records : Array[(Int32, Int32)]
  mut started : Bool
  mut finished : Bool
}

///|
/// Creates a writer. `check_kind` selects the block check (CRC64 by default) and
/// `options` the compression parameters.
pub fn XzWriter::new(
  check_kind~ : CheckKind = Crc64,
  options~ : CompressionOptions = CompressionOptions::new(),
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
  max_output : Int32
  mut output_so_far : Int32
  mut check_kind : CheckKind?
  records : Array[(Int32, Int32)]
  mut stream_open : Bool
  mut done : Bool
}

///|
/// A forward-only XZ decoder over an input that arrives in chunks.
///
/// `XzReader` requires the whole compressed stream in memory. This type instead
/// keeps a bounded window: the caller appends compressed bytes with `supply` and
/// pulls one block at a time with `next`. Bytes of already decoded blocks are
/// dropped by `compact`, so what is retained is the pending input rather than
/// every byte ever fed, and the decoded block is the only output held.
///
/// The caller keeps ownership of the file or socket, which is what stops this
/// from dragging a runtime into the library: nothing here performs I/O.
///
/// The parser needs a peekable window, so it decodes from a copy of the
/// unconsumed bytes. `next` therefore costs one copy of the pending window per
/// block; a full block-based rewrite could avoid that, and is not needed to make
/// the memory profile bounded.
pub struct XzStreamDecoder {
  window : Array[Byte]
  mut consumed : Int32
  max_output : Int32
  mut output_so_far : Int32
  mut check_kind : CheckKind?
  records : Array[(Int32, Int32)]
  mut stream_open : Bool
  mut done : Bool
  mut input_finished : Bool
  /// Number of complete streams seen; padding is only legal after the first.
  mut streams_seen : Int32
}

///|
/// Creates a chunk-fed decoder. `max_output` bounds the total decoded size, as
/// in `XzReader`.
pub fn XzStreamDecoder::new(max_output~ : Int32 = 1 << 30) -> XzStreamDecoder {
  {
    window: [],
    consumed: 0,
    max_output,
    output_so_far: 0,
    check_kind: None,
    records: [],
    stream_open: false,
    done: false,
    input_finished: false,
    streams_seen: 0,
  }
}

///|
/// Appends more compressed bytes.
pub fn XzStreamDecoder::supply(self : XzStreamDecoder, data : Bytes) -> Unit {
  append_bytes(self.window, data)
}

///|
/// Number of compressed bytes held but not yet consumed.
pub fn XzStreamDecoder::buffered(self : XzStreamDecoder) -> Int32 {
  self.window.length() - self.consumed
}

///|
/// Drops bytes belonging to blocks already decoded, bounding the window.
///
/// Compaction only happens once the consumed prefix is at least half the window,
/// which makes the copying cost amortised constant per byte rather than one copy
/// per call.
fn XzStreamDecoder::compact(self : XzStreamDecoder) -> Unit {
  if self.consumed == 0 {
    return
  }
  if self.consumed >= self.window.length() {
    self.window.clear()
    self.consumed = 0
    return
  }
  if self.consumed * 2 < self.window.length() {
    return
  }
  let remaining = bytes_from_array(self.window[self.consumed:].to_owned())
  self.window.clear()
  append_bytes(self.window, remaining)
  self.consumed = 0
}

///|
/// Whether a complete stream footer has been consumed.
pub fn XzStreamDecoder::is_done(self : XzStreamDecoder) -> Bool {
  self.done
}

///|
/// Declares that no more input will arrive, so `next` reports a stream that ends
/// early instead of asking for more bytes.
pub fn XzStreamDecoder::finish_input(self : XzStreamDecoder) -> Unit {
  self.input_finished = true
}

///|
/// Decodes the next block.
///
/// `None` means the buffered bytes do not yet contain a complete unit: supply
/// more input and call again. Once `finish_input` has been called the same
/// `None` means the input ended before the stream did.
///
/// State advances only when a unit is fully consumed, so an input that stops
/// mid-block is retried from the same position once the rest arrives. That is
/// what makes feeding a stream one byte at a time work.
pub fn XzStreamDecoder::next(self : XzStreamDecoder) -> Bytes? raise XzError {
  if self.done {
    return None
  }
  while true {
    // Rebuilt every iteration: `compact` moves the window, which invalidates
    // any cursor positioned over the previous copy.
    let cursor = ByteCursor::new(
      bytes_from_array(self.window[self.consumed:].to_owned()),
    )
    if !self.stream_open {
      if cursor.remaining() >= 4 &&
        cursor.data[cursor.pos] == b'\x00' &&
        cursor.data[cursor.pos + 1] == b'\x00' &&
        cursor.data[cursor.pos + 2] == b'\x00' &&
        cursor.data[cursor.pos + 3] == b'\x00' {
        self.consumed += 4
        self.compact()
        continue
      }
      if cursor.remaining() == 0 {
        if self.input_finished {
          self.done = true
        }
        return None
      }
      if cursor.remaining() < 12 {
        return None
      }
      self.check_kind = Some(read_stream_header(cursor))
      self.records.clear()
      self.stream_open = true
      self.consumed += cursor.pos
      self.compact()
      continue
    }
    if cursor.remaining() == 0 {
      return None
    }
    // Index and footer end the stream. Both must be present before anything is
    // consumed: the index has no length prefix, so whether it is complete is
    // only known by parsing it, and a partial parse must not advance state.
    // Running out of bytes is the one outcome meaning "wait for more input"; a
    // re-parse happens on the next call.
    if cursor.peek_byte() == b'\x00' {
      let check_kind = match self.check_kind {
        Some(value) => value
        None => raise Corrupt("XZ stream has no active header")
      }
      // Stream padding is a multiple of four zero bytes and only ever appears
      // *after* a completed stream, whereas a zero-record index is `00 00 00 00`
      // followed by the footer. Both therefore start with four zeros, and the
      // distinguishing feature is what follows: padding is followed by the next
      // stream's magic, an empty index by footer bytes.
      //
      // `streams_seen >= 1` is required, not merely implied. Without it the
      // lookahead also matches at the end of the first stream, because a stream
      // with CRC64 whose recorded checksum happens to be zero ends in four zero
      // bytes followed by the 12-byte footer, and the sixth footer byte is 'Z' -
      // so eight of the ten compared bytes line up. Mistaking the footer for
      // padding sets `done`, and a decoder that is done never looks at the rest
      // of a concatenated input.
      if self.streams_seen >= 1 &&
        cursor.remaining() >= 10 &&
        cursor.data[cursor.pos] == b'\x00' &&
        cursor.data[cursor.pos + 1] == b'\x00' &&
        cursor.data[cursor.pos + 2] == b'\x00' &&
        cursor.data[cursor.pos + 3] == b'\x00' &&
        cursor.data[cursor.pos + 4] == b'\xFD' &&
        cursor.data[cursor.pos + 5] == b'7' &&
        cursor.data[cursor.pos + 6] == b'z' &&
        cursor.data[cursor.pos + 7] == b'X' &&
        cursor.data[cursor.pos + 8] == b'Z' &&
        cursor.data[cursor.pos + 9] == b'\x00' {
        self.consumed += 4
        self.compact()
        continue
      }
      let index_size = parse_index(cursor, self.records) catch {
        Truncated(_) => return None
        error => raise error
      }
      let footer_start = cursor.pos
      if cursor.remaining() < 12 {
        // The footer has not fully arrived; retry the whole unit later.
        return None
      }
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
      self.stream_open = false
      self.check_kind = None
      self.streams_seen += 1
      self.consumed += cursor.pos
      self.compact()
      if self.buffered() == 0 {
        // Only settle as finished once the caller has said no more input is
        // coming. A completed footer mid-feed does not mean the stream is over:
        // a concatenated stream may still be on its way, and `done` is sticky,
        // so setting it here would make the decoder ignore that input.
        if self.input_finished {
          self.done = true
        }
        return None
      }
      // A concatenated stream follows; loop to read it from its header.
      continue
    }
    let check_kind = match self.check_kind {
      Some(value) => value
      None => raise Corrupt("XZ stream has no active header")
    }
    // The block header is length-prefixed, so wait until all of it is buffered
    // before parsing; a partial header would otherwise look like corruption.
    let header_size_byte = cursor.peek_byte().to_int()
    let header_length = (header_size_byte + 1) * 4
    if header_length < 8 || header_length > MAX_BLOCK_HEADER {
      raise Corrupt("invalid XZ block header size")
    }
    if cursor.remaining() < header_length {
      return None
    }
    let header = cursor.read_bytes(header_length)
    let (
      compressed_size_opt,
      uncompressed_size_opt,
      parsed_header_length,
      filters,
    ) = parse_block_header(header)
    let compressed_size = match compressed_size_opt {
      Some(value) => value
      None => scan_lzma2_size(cursor.data, cursor.pos)
    }
    match uncompressed_size_opt {
      Some(expected) =>
        if self.output_so_far + expected > self.max_output {
          raise OutputLimitExceeded(self.max_output)
        }
      None => ()
    }
    // Everything after the header must be buffered before decoding, or a short
    // window would be reported as a corrupt stream instead of "need more".
    let padding = (4 - compressed_size % 4) % 4
    let needed = compressed_size + padding + check_kind.size()
    if cursor.remaining() < needed {
      return None
    }
    let compressed = cursor.read_bytes(compressed_size)
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
    for _ in 0..<padding {
      if cursor.read_byte() != b'\x00' {
        raise Corrupt("non-zero XZ block padding")
      }
    }
    let stored_check = cursor.read_bytes(check_kind.size())
    if stored_check != check_bytes(check_kind, decoded) {
      raise ChecksumMismatch("XZ block checksum mismatch")
    }
    let unpadded = parsed_header_length + compressed_size + check_kind.size()
    self.records.push((unpadded, decoded.length()))
    self.output_so_far += decoded.length()
    self.consumed += cursor.pos
    self.compact()
    return Some(decoded)
  } nobreak {
    None
  }
}

///|
/// Creates a reader over an in-memory XZ stream. `max_output` bounds the total
/// decoded size across all blocks, so a hostile stream cannot exhaust memory.
pub fn XzReader::new(input : Bytes, max_output~ : Int32 = 1 << 30) -> XzReader {
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
