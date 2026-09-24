///|
/// LZMA-alone container support.
///
/// The legacy `.lzma` format wraps a single raw LZMA stream in a 13-byte
/// header and carries no checksum, no index and no block structure:
///
/// ```text
/// offset  size  content
/// 0       1     LZMA properties byte (lc, lp, pb)
/// 1       4     dictionary size, little endian
/// 8       8     uncompressed size, little endian, or 0xFFFFFFFFFFFFFFFF
/// 13      ...   range-coded LZMA stream
/// ```
///
/// Two stream terminations exist. When the header records the uncompressed size
/// the decoder stops after exactly that many bytes and the stream has no end
/// marker. When the size field is all ones the decoder runs until the stream's
/// end marker. Both forms are accepted here, which is what makes MoonXZ able to
/// read files produced by `xz --format=lzma` and by Python's
/// `lzma.compress(data, format=lzma.FORMAT_ALONE)`.

///|
const LZMA1_HEADER_SIZE : Int = 13

///|
/// Sentinel stored in the `.lzma` header when the uncompressed size is unknown
/// and the stream ends with an explicit end marker instead.
const LZMA1_UNKNOWN_SIZE : UInt64 = 0xFFFFFFFFFFFFFFFFUL

///|
/// Parsed `.lzma` header.
priv struct Lzma1Header {
  lc : Int
  lp : Int
  pb : Int
  dict_size : Int
  uncompressed_size : Int?
}

///|
/// Normalizes the 32-bit dictionary size field.
///
/// The LZMA reference decoder accepts any value but rounds it up to the next
/// `2^n` or `2^n + 2^(n-1)` size, which is the set of dictionary sizes an
/// encoder can actually select. Reproducing that rule keeps MoonXZ compatible
/// with the same set of producer implementations.
fn lzma1_normalize_dict_size(code : UInt) -> Int raise XzError {
  if code == 0U {
    raise Corrupt("LZMA-alone dictionary size of zero is invalid")
  }
  if code == 0xFFFFFFFFU {
    return 1 << 30
  }
  let mut dictionary_size = code
  let bits = 32 - code.clz()
  if bits <= 12 {
    dictionary_size = 1U << 12
  } else {
    let normalized = (1U << (bits - 1)) | (1U << (bits - 2))
    if code > normalized {
      dictionary_size = 1U << bits
    }
  }
  let dict_size = dictionary_size.reinterpret_as_int()
  if dict_size < 4096 {
    4096
  } else if dict_size > 1 << 30 {
    1 << 30
  } else {
    dict_size
  }
}

///|
/// Reads and validates the 13-byte `.lzma` header.
fn parse_lzma1_header(input : Bytes) -> Lzma1Header raise XzError {
  if input.length() < LZMA1_HEADER_SIZE {
    raise Truncated("LZMA-alone input is shorter than its 13-byte header")
  }
  let cursor = ByteCursor::new(input)
  let property = cursor.read_u8()
  let (lc, lp, pb) = decode_lzma_properties(property)
  let dict_code = cursor.read_u32_le()
  let dict_size = lzma1_normalize_dict_size(dict_code)
  let mut size_field : UInt64 = 0UL
  for i in 0..<8 {
    size_field = size_field | (cursor.read_byte().to_uint64() << (i * 8))
  }
  let uncompressed_size : Int? = if size_field == LZMA1_UNKNOWN_SIZE {
    None
  } else {
    Some(usize_of_u64(size_field, "LZMA-alone uncompressed size"))
  }
  { lc, lp, pb, dict_size, uncompressed_size, }
}

///|
/// Decodes a complete LZMA-alone stream.
///
/// `max_output` bounds the decoded size so that a hostile header cannot make the
/// decoder allocate without limit. Trailing bytes after the stream are
/// tolerated, because some producers pad the output; a stream that ends early is
/// reported as `Truncated`.
fn decode_lzma1(input : Bytes, max_output : Int) -> Bytes raise XzError {
  let header = parse_lzma1_header(input)
  match header.uncompressed_size {
    Some(size) => if size > max_output { raise OutputLimitExceeded(max_output) }
    None => ()
  }
  let payload = input[LZMA1_HEADER_SIZE:].to_owned()
  let stream = decode_lzma1_stream(
    payload,
    header.lc,
    header.lp,
    header.pb,
    header.dict_size,
    header.uncompressed_size,
    max_output,
  )
  match header.uncompressed_size {
    Some(expected) =>
      if stream.data.length() != expected {
        raise Corrupt(
          "LZMA-alone stream produced \{stream.data.length()} bytes, header declared \{expected}",
        )
      }
    None =>
      if !stream.reached_end_marker {
        raise Truncated("LZMA-alone stream ended without an end marker")
      }
  }
  stream.data
}

///|
/// Encodes the range-coded payload of an LZMA-alone stream.
fn encode_lzma1_payload(
  data : Bytes,
  options : CompressionOptions,
  lc : Int,
  lp : Int,
  pb : Int,
) -> Bytes {
  let range = RangeEncoder::new(data.length())
  let state = LzmaEncoder::with_properties(lc, lp, pb)
  let previous = build_match_chains(data)
  let depth = compression_depth(options.level)
  let nice_length = compression_nice_length(options.level)
  let mut position = 0
  while position < data.length() {
    match
      find_match(
        data,
        position,
        data.length(),
        previous,
        depth,
        nice_length,
        options.dict_size,
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
/// Encodes `data` as a complete LZMA-alone stream using the given properties.
///
/// The header records the exact uncompressed size, so the payload needs no end
/// marker. This matches what `xz --format=lzma` writes when the size is known
/// and keeps the output byte-comparable with other implementations.
fn encode_lzma1(
  data : Bytes,
  options : CompressionOptions,
  lc : Int,
  lp : Int,
  pb : Int,
) -> Bytes raise XzError {
  if lc < 0 || lc > 8 || lp < 0 || lp > 4 || pb < 0 || pb > 4 || lc + lp > 4 {
    raise Unsupported("invalid LZMA properties: lc=\{lc} lp=\{lp} pb=\{pb}")
  }
  if data.length() == 0 {
    raise Unsupported("LZMA-alone encoding of an empty input is not supported")
  }
  let header : Array[Byte] = []
  header.push(((pb * 5 + lp) * 9 + lc).to_byte())
  push_u32_le(header, options.dict_size.reinterpret_as_uint())
  push_u64_le(header, data.length().to_uint64())
  let payload = encode_lzma1_payload(data, options, lc, lp, pb)
  append_bytes(header, payload)
  bytes_from_array(header)
}
