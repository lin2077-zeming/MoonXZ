///|
/// Range encoder used by the LZMA probability models.
priv struct RangeEncoder {
  output : Array[Byte]
  mut low : UInt64
  mut range : UInt
  mut cache : Byte
  mut cache_size : Int
}

///|
fn RangeEncoder::new() -> RangeEncoder {
  {
    output: Array(capacity=1024),
    low: 0UL,
    range: 0xFFFFFFFFU,
    cache: b'\x00',
    cache_size: 1,
  }
}

///|
fn RangeEncoder::shift_low(self : RangeEncoder) -> Unit {
  if self.low.to_uint() < 0xFF000000U || self.low >> 32 != 0UL {
    let mut temp = self.cache
    let carry = (self.low >> 32).to_byte()
    while true {
      self.output.push((temp.to_uint() + carry.to_uint()).to_byte())
      temp = b'\xFF'
      self.cache_size -= 1
      if self.cache_size == 0 {
        break
      }
    }
    self.cache = ((self.low >> 24) & 0xFFUL).to_byte()
  }
  self.cache_size += 1
  self.low = (self.low << 8) & 0xFFFFFFFFUL
}

///|
fn RangeEncoder::normalize(self : RangeEncoder) -> Unit {
  if self.range < 0x01000000U {
    self.range = self.range << 8
    self.shift_low()
  }
}

///|
fn RangeEncoder::encode_bit(
  self : RangeEncoder,
  probabilities : Array[UInt],
  index : Int,
  bit : UInt,
) -> Unit {
  let probability = probabilities[index]
  let bound = (self.range >> 11) * probability
  if bit == 0U {
    self.range = bound
    probabilities[index] = probability + ((2048U - probability) >> 5)
  } else {
    self.low = self.low + bound.to_uint64()
    self.range = self.range - bound
    probabilities[index] = probability - (probability >> 5)
  }
  self.normalize()
}

///|
fn RangeEncoder::encode_direct_bits(
  self : RangeEncoder,
  value : UInt,
  bits : Int,
) -> Unit {
  for i in 0..<bits {
    let bit = (value >> (bits - 1 - i)) & 1U
    self.range = self.range >> 1
    if bit == 1U {
      self.low = self.low + self.range.to_uint64()
    }
    self.normalize()
  }
}

///|
fn RangeEncoder::encode_bit_tree(
  self : RangeEncoder,
  probabilities : Array[UInt],
  base : Int,
  bits : Int,
  value : UInt,
) -> Unit {
  let mut model : UInt = 1U
  for i in 0..<bits {
    let bit = (value >> (bits - 1 - i)) & 1U
    self.encode_bit(probabilities, base + model.reinterpret_as_int(), bit)
    model = (model << 1) | bit
  }
}

///|
fn RangeEncoder::encode_reverse_bit_tree(
  self : RangeEncoder,
  probabilities : Array[UInt],
  base : Int,
  bits : Int,
  value : UInt,
) -> Unit {
  let mut model : UInt = 1U
  for i in 0..<bits {
    let bit = (value >> i) & 1U
    self.encode_bit(probabilities, base + model.reinterpret_as_int(), bit)
    model = (model << 1) | bit
  }
}

///|
fn RangeEncoder::finish(self : RangeEncoder) -> Bytes {
  for _ in 0..<5 {
    self.shift_low()
  }
  Bytes::from_array(self.output)
}
