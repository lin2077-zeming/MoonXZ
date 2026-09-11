///|
/// Optional filter placed before LZMA2 in an XZ block.
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
