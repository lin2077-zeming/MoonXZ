///|
/// Optional filter placed before LZMA2 in an XZ block.
///
/// `Delta` is a byte-distance filter and `X86` is the x86 branch-converter (BCJ)
/// filter. A BCJ filter rewrites machine-code branch addresses from relative to
/// absolute form so that the LZMA2 encoder sees repeated byte sequences.
///
/// Every other filter id the XZ specification defines is recognized but reported
/// as `Unsupported`: IA64, ARM, ARM64, ARM-Thumb, PowerPC and SPARC. They are
/// refused rather than approximated because a BCJ filter whose address arithmetic
/// is even slightly wrong corrupts the output silently - the block check can only
/// report an inconsistency, not a wrong-but-consistent result.
///
/// `X86` is the only BCJ filter MoonXZ ships because it is the only one that
/// passed a bidirectional interop check against liblzma on both synthetic branch
/// instructions and random data. The reasons each other filter is withheld are
/// recorded in `docs/DESIGN.md`.
pub(all) enum FilterMode {
  None
  Delta(Int)
  X86
}

///|
/// Compression parameters for the LZMA2 encoder.
pub(all) struct CompressionOptions {
  level : Int
  dict_size : Int
  filter : FilterMode
}

///|
/// Creates encoder options.
///
/// `level` is clamped to 0 through 9. Level 0 uses uncompressed LZMA2 chunks;
/// levels 1 through 9 use the range encoder with progressively deeper hash
/// chains. `dict_size` is clamped to 4 KiB through 1 GiB.
pub fn CompressionOptions::new(
  level? : Int = 6,
  dict_size? : Int = 8 * 1024 * 1024,
  filter? : FilterMode = None,
) -> CompressionOptions {
  let level = if level < 0 { 0 } else if level > 9 { 9 } else { level }
  let dict_size = if dict_size < 4096 {
    4096
  } else if dict_size > 1 << 30 {
    1 << 30
  } else {
    dict_size
  }
  { level, dict_size, filter, }
}

///|
/// Compresses data into a single-block XZ stream using default options.
pub fn compress(data : Bytes) -> Bytes {
  compress_with_options(data, CompressionOptions::new())
}

///|
/// Compresses data into a single-block XZ stream using default options and an
/// explicit block check.
pub fn compress_with_check(data : Bytes, check_kind : CheckKind) -> Bytes {
  compress_with_options_and_check(data, CompressionOptions::new(), check_kind)
}

///|
/// Compresses data using explicit level and dictionary size.
pub fn compress_with_options(
  data : Bytes,
  options : CompressionOptions,
) -> Bytes {
  compress_with_options_and_check(data, options, Crc64)
}

///|
/// Compresses data using explicit options and block check type.
pub fn compress_with_options_and_check(
  data : Bytes,
  options : CompressionOptions,
  check_kind : CheckKind,
) -> Bytes {
  encode_xz(data, options, check_kind)
}

///|
/// Decompresses one or more concatenated XZ streams.
pub fn decompress(data : Bytes) -> Bytes raise XzError {
  decode_xz(data, 1 << 30)
}

///|
/// Decompresses XZ data while refusing outputs larger than `max_output`.
pub fn decompress_with_limit(
  data : Bytes,
  max_output : Int,
) -> Bytes raise XzError {
  if max_output < 0 {
    raise OutputLimitExceeded(max_output)
  }
  decode_xz(data, max_output)
}

///|
/// Decompresses a legacy LZMA-alone (`.lzma`) stream.
///
/// The `.lzma` container predates XZ. It has a 13-byte header with the LZMA
/// properties, dictionary size and uncompressed size, and carries no checksum,
/// index or block structure, so it offers no integrity guarantee beyond the
/// range coder's own consistency checks.
///
/// Both header forms are accepted: a recorded uncompressed size, and the
/// `0xFFFFFFFFFFFFFFFF` sentinel that means the stream carries an end marker.
pub fn decompress_lzma1(data : Bytes) -> Bytes raise XzError {
  decode_lzma1(data, 1 << 30)
}

///|
/// Decompresses a legacy LZMA-alone stream while refusing outputs larger than
/// `max_output`.
pub fn decompress_lzma1_with_limit(
  data : Bytes,
  max_output : Int,
) -> Bytes raise XzError {
  if max_output < 0 {
    raise OutputLimitExceeded(max_output)
  }
  decode_lzma1(data, max_output)
}

///|
/// Compresses `data` into a legacy LZMA-alone (`.lzma`) stream.
///
/// `lc`, `lp` and `pb` are the LZMA literal context, literal position and
/// position bits. The defaults `3`, `0`, `2` are the values the reference
/// encoder uses, and they are the only combination MoonXZ writes.
pub fn compress_lzma1(
  data : Bytes,
  options? : CompressionOptions = CompressionOptions::new(),
  lc? : Int = 3,
  lp? : Int = 0,
  pb? : Int = 2,
) -> Bytes raise XzError {
  encode_lzma1(data, options, lc, lp, pb)
}

///|
/// Returns the LZMA properties recorded by a `.lzma` header as `(lc, lp, pb)`.
/// Useful for reporting why a stream cannot be decoded.
pub fn lzma1_properties(data : Bytes) -> (Int, Int, Int) raise XzError {
  let header = parse_lzma1_header(data)
  (header.lc, header.lp, header.pb)
}

///|
/// Returns the uncompressed size recorded by a `.lzma` header, or `None` when
/// the header stores the unknown-size sentinel.
pub fn lzma1_declared_size(data : Bytes) -> Int? raise XzError {
  parse_lzma1_header(data).uncompressed_size
}
