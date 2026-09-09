///|
/// Compresses data into a single-block XZ stream.
///
/// Version 0.1 writes standards-compatible uncompressed LZMA2 chunks. This
/// keeps the encoder simple and interoperable while the range encoder and
/// match finder are developed.
pub fn compress(data : Bytes) -> Bytes {
  compress_with_check(data, Crc64)
}

///|
pub fn compress_with_check(data : Bytes, check_kind : CheckKind) -> Bytes {
  encode_xz_store(data, check_kind)
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
