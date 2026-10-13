///|
/// A small checked cursor over an immutable byte sequence.
///
/// `limit` is the first index that must not be read. It defaults to the end of
/// `data`, and a streaming caller lowers it to the boundary of the bytes it has
/// actually received. Carrying the boundary here means a read that stops short
/// reports `Truncated` from one place, so a chunk-fed parser can distinguish
/// "wait for more input" from "the stream is malformed".
#doc(hidden)
pub struct ByteCursor {
  data : Bytes
  mut pos : Int32
  limit : Int32
}

///|
fn ByteCursor::new(data : Bytes) -> ByteCursor {
  { data, pos: 0, limit: data.length(), }
}

///|
fn ByteCursor::remaining(self : ByteCursor) -> Int32 {
  self.limit - self.pos
}

///|
fn ByteCursor::peek_byte(self : ByteCursor) -> Byte raise XzError {
  if self.pos >= self.limit {
    raise Truncated("unexpected end of input")
  }
  self.data[self.pos]
}

///|
fn ByteCursor::read_byte(self : ByteCursor) -> Byte raise XzError {
  if self.pos >= self.limit {
    raise Truncated("unexpected end of input")
  }
  let value = self.data[self.pos]
  self.pos += 1
  value
}

///|
fn ByteCursor::read_u8(self : ByteCursor) -> Int32 raise XzError {
  self.read_byte().to_int()
}

///|
fn ByteCursor::read_u16_be(self : ByteCursor) -> UInt32 raise XzError {
  let hi = self.read_byte().to_uint()
  let lo = self.read_byte().to_uint()
  (hi << 8) | lo
}

///|
fn ByteCursor::read_u32_le(self : ByteCursor) -> UInt32 raise XzError {
  let b0 = self.read_byte().to_uint()
  let b1 = self.read_byte().to_uint()
  let b2 = self.read_byte().to_uint()
  let b3 = self.read_byte().to_uint()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
fn ByteCursor::read_vli(self : ByteCursor) -> UInt64 raise XzError {
  let mut value : UInt64 = 0UL
  let mut shift = 0
  for index in 0..<9 {
    let byte = self.read_byte()
    let payload = (byte & b'\x7F').to_uint64()
    if index == 8 && payload > 1UL {
      raise Corrupt("variable-length integer overflows 64 bits")
    }
    value = value | (payload << shift)
    if (byte & b'\x80') == b'\x00' {
      return value
    }
    shift += 7
  }
  raise Corrupt("variable-length integer is too long")
}

///|
fn ByteCursor::read_bytes(
  self : ByteCursor,
  length : Int32,
) -> Bytes raise XzError {
  // Written as `length > remaining` instead of `pos + length > data.length()`:
  // a corrupt stream can carry a huge length, and `pos + length` can then
  // overflow to a negative value that passes the check, letting the loop below
  // index past the end of the buffer. Subtracting keeps every term in range.
  if length < 0 || length > self.remaining() {
    raise Truncated("requested byte range is outside input")
  }
  let out : Array[Byte] = []
  for i in 0..<length {
    out.push(self.data[self.pos + i])
  }
  self.pos += length
  bytes_from_array(out)
}

///|
fn ByteCursor::skip(self : ByteCursor, length : Int32) -> Unit raise XzError {
  if length < 0 || length > self.remaining() {
    raise Truncated("requested byte range is outside input")
  }
  self.pos += length
}

///|
fn usize_of_u64(value : UInt64, what : String) -> Int32 raise XzError {
  if value > 2147483647UL {
    raise Unsupported("\{what} larger than 2 GiB is not supported")
  }
  value.to_int()
}

///|
fn push_u32_le(out : Array[Byte], value : UInt32) -> Unit {
  for shift in 0..<4 {
    out.push(((value >> (shift * 8)) & 0xFFU).to_byte())
  }
}

///|
fn push_u16_be(out : Array[Byte], value : UInt32) -> Unit {
  out.push(((value >> 8) & 0xFFU).to_byte())
  out.push((value & 0xFFU).to_byte())
}

///|
fn push_u64_le(out : Array[Byte], value : UInt64) -> Unit {
  for shift in 0..<8 {
    out.push(((value >> (shift * 8)) & 0xFFUL).to_byte())
  }
}

///|
fn push_u32_be(out : Array[Byte], value : UInt32) -> Unit {
  for shift in 0..<4 {
    out.push(((value >> ((3 - shift) * 8)) & 0xFFU).to_byte())
  }
}

///|
fn push_vli(out : Array[Byte], value : UInt64) -> Unit {
  let mut current = value
  while current >= 0x80UL {
    out.push(((current & 0x7FUL) | 0x80UL).to_byte())
    current = current >> 7
  }
  out.push(current.to_byte())
}

///|
fn bytes_from_array(array : Array[Byte]) -> Bytes {
  Bytes::from_array(array)
}
