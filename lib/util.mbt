///|
/// A small checked cursor over an immutable byte sequence.
priv struct ByteCursor {
  data : Bytes
  mut pos : Int
}

///|
fn ByteCursor::new(data : Bytes) -> ByteCursor {
  { data, pos: 0, }
}

///|
fn ByteCursor::remaining(self : ByteCursor) -> Int {
  self.data.length() - self.pos
}

///|
fn ByteCursor::peek_byte(self : ByteCursor) -> Byte raise XzError {
  if self.pos >= self.data.length() {
    raise Truncated("unexpected end of input")
  }
  self.data[self.pos]
}

///|
fn ByteCursor::read_byte(self : ByteCursor) -> Byte raise XzError {
  if self.pos >= self.data.length() {
    raise Truncated("unexpected end of input")
  }
  let value = self.data[self.pos]
  self.pos += 1
  value
}

///|
fn ByteCursor::read_u8(self : ByteCursor) -> Int raise XzError {
  self.read_byte().to_int()
}

///|
fn ByteCursor::read_u16_be(self : ByteCursor) -> UInt raise XzError {
  let hi = self.read_byte().to_uint()
  let lo = self.read_byte().to_uint()
  (hi << 8) | lo
}

///|
fn ByteCursor::read_u32_le(self : ByteCursor) -> UInt raise XzError {
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
  length : Int,
) -> Bytes raise XzError {
  if length < 0 || self.pos + length > self.data.length() {
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
fn ByteCursor::skip(self : ByteCursor, length : Int) -> Unit raise XzError {
  if length < 0 || self.pos + length > self.data.length() {
    raise Truncated("requested byte range is outside input")
  }
  self.pos += length
}

///|
fn usize_of_u64(value : UInt64, what : String) -> Int raise XzError {
  if value > 2147483647UL {
    raise Unsupported("\{what} larger than 2 GiB is not supported")
  }
  value.to_int()
}

///|
fn push_u32_le(out : Array[Byte], value : UInt) -> Unit {
  for shift in 0..<4 {
    out.push(((value >> (shift * 8)) & 0xFFU).to_byte())
  }
}

///|
fn push_u64_le(out : Array[Byte], value : UInt64) -> Unit {
  for shift in 0..<8 {
    out.push(((value >> (shift * 8)) & 0xFFUL).to_byte())
  }
}

///|
fn push_u32_be(out : Array[Byte], value : UInt) -> Unit {
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
