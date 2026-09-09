///|
/// Range decoder used by the LZMA probability models.
priv struct RangeDecoder {
  input : Bytes
  mut pos : Int
  mut range : UInt
  mut code : UInt
}

///|
fn RangeDecoder::new(input : Bytes) -> RangeDecoder raise XzError {
  if input.length() < 5 {
    raise Truncated("LZMA range stream is shorter than five bytes")
  }
  if input[0] != b'\x00' {
    raise Corrupt("LZMA range stream has a non-zero first byte")
  }
  let mut code : UInt = 0U
  for i in 1..<5 {
    code = (code << 8) | input[i].to_uint()
  }
  { input, pos: 5, range: 0xFFFFFFFFU, code }
}

///|
fn RangeDecoder::read_byte(self : RangeDecoder) -> Byte raise XzError {
  if self.pos >= self.input.length() {
    raise Truncated("LZMA range stream ended early")
  }
  let value = self.input[self.pos]
  self.pos += 1
  value
}

///|
fn RangeDecoder::normalize(self : RangeDecoder) -> Unit raise XzError {
  if self.range < 0x01000000U {
    self.range = self.range << 8
    self.code = (self.code << 8) | self.read_byte().to_uint()
  }
}

///|
fn RangeDecoder::decode_bit(
  self : RangeDecoder,
  probabilities : Array[UInt],
  index : Int,
) -> UInt raise XzError {
  let probability = probabilities[index]
  let bound = (self.range >> 11) * probability
  let bit = if self.code < bound {
    self.range = bound
    probabilities[index] = probability + ((2048U - probability) >> 5)
    0U
  } else {
    self.code = self.code - bound
    self.range = self.range - bound
    probabilities[index] = probability - (probability >> 5)
    1U
  }
  self.normalize()
  bit
}

///|
fn RangeDecoder::decode_direct_bits(
  self : RangeDecoder,
  bits : Int,
) -> UInt raise XzError {
  let mut value : UInt = 0U
  for _ in 0..<bits {
    self.range = self.range >> 1
    self.code = self.code - self.range
    let mask = 0U - (self.code >> 31)
    self.code = self.code + (self.range & mask)
    value = (value << 1) | ((mask + 1U) & 1U)
    self.normalize()
  }
  value
}

///|
fn RangeDecoder::decode_bit_tree(
  self : RangeDecoder,
  probabilities : Array[UInt],
  base : Int,
  bits : Int,
) -> UInt raise XzError {
  let mut model : UInt = 1U
  for _ in 0..<bits {
    model = (model << 1) |
      self.decode_bit(probabilities, base + model.reinterpret_as_int())
  }
  model - (1U << bits)
}

///|
fn RangeDecoder::decode_reverse_bit_tree(
  self : RangeDecoder,
  probabilities : Array[UInt],
  base : Int,
  bits : Int,
) -> UInt raise XzError {
  let mut model : UInt = 1U
  let mut value : UInt = 0U
  for bit_index in 0..<bits {
    let bit = self.decode_bit(probabilities, base + model.reinterpret_as_int())
    model = (model << 1) | bit
    value = value | (bit << bit_index)
  }
  value
}
