///|
/// LZMA probability state used by the compressed encoder.
///
/// This first encoder emits literals and ordinary matches. It keeps the full
/// LZMA state transitions so that the output remains compatible with the
/// decoder and with other XZ implementations.
priv struct LzmaEncoder {
  mut state : Int
  mut rep0 : UInt
  lc : Int
  lp : Int
  pb : Int
  literal_probs : Array[UInt]
  is_match : Array[UInt]
  is_rep : Array[UInt]
  len_choice : Array[UInt]
  len_low : Array[UInt]
  len_mid : Array[UInt]
  len_high : Array[UInt]
  pos_slot : Array[Array[UInt]]
  pos_model : Array[Array[UInt]]
  align : Array[UInt]
}

///|
fn LzmaEncoder::new() -> LzmaEncoder {
  let lc = 3
  let lp = 0
  let pb = 2
  let pos_slot : Array[Array[UInt]] = Array(capacity=4)
  for _ in 0..<4 {
    pos_slot.push(make_probability_array(64))
  }
  let pos_model : Array[Array[UInt]] = Array(capacity=10)
  for i in 0..<10 {
    let slot = 4 + i
    let bits = (slot >> 1) - 1
    pos_model.push(make_probability_array(1 << bits))
  }
  {
    state: 0,
    rep0: 0U,
    lc,
    lp,
    pb,
    literal_probs: make_probability_array(0x300 << (lc + lp)),
    is_match: make_probability_array(12 << 4),
    is_rep: make_probability_array(12),
    len_choice: make_probability_array(2),
    len_low: make_probability_array(16 * 8),
    len_mid: make_probability_array(16 * 8),
    len_high: make_probability_array(256),
    pos_slot,
    pos_model,
    align: make_probability_array(16),
  }
}

///|
fn LzmaEncoder::update_state_literal(self : LzmaEncoder) -> Unit {
  if self.state < 4 {
    self.state = 0
  } else if self.state < 10 {
    self.state -= 3
  } else {
    self.state -= 6
  }
}

///|
fn LzmaEncoder::update_state_match(self : LzmaEncoder) -> Unit {
  self.state = if self.state < 7 { 7 } else { 10 }
}

///|
fn LzmaEncoder::encode_literal(
  self : LzmaEncoder,
  range : RangeEncoder,
  data : Bytes,
  position : Int,
) -> Unit {
  let pos_state = position & ((1 << self.pb) - 1)
  range.encode_bit(self.is_match, self.state * 16 + pos_state, 0U)

  let previous = if position == 0 { b'\x00' } else { data[position - 1] }
  let literal_state = ((position & ((1 << self.lp) - 1)) << self.lc) |
    (previous.to_int() >> (8 - self.lc))
  let base = literal_state * 0x300
  let value = data[position].to_int()
  let mut remaining = value
  let mut symbol : UInt = 1U
  if self.state >= 7 && self.rep0 < position.reinterpret_as_uint() {
    let mut match_byte = data[position - self.rep0.reinterpret_as_int() - 1].to_int()
    for _ in 0..<8 {
      let match_bit = (match_byte >> 7) & 1
      match_byte = match_byte << 1
      let bit = (remaining >> 7) & 1
      remaining = remaining << 1
      range.encode_bit(
        self.literal_probs,
        base + (((1 + match_bit) << 8) | symbol.reinterpret_as_int()),
        bit.reinterpret_as_uint(),
      )
      symbol = (symbol << 1) | bit.reinterpret_as_uint()
      if match_bit != bit || symbol >= 0x100U {
        break
      }
    }
  }
  while symbol < 0x100U {
    let bit = (remaining >> 7) & 1
    remaining = remaining << 1
    range.encode_bit(
      self.literal_probs,
      base + symbol.reinterpret_as_int(),
      bit.reinterpret_as_uint(),
    )
    symbol = (symbol << 1) | bit.reinterpret_as_uint()
  }
  self.update_state_literal()
}

///|
fn LzmaEncoder::encode_length(
  self : LzmaEncoder,
  range : RangeEncoder,
  length : Int,
  pos_state : Int,
) -> Unit {
  let offset = length - 2
  if offset < 8 {
    range.encode_bit(self.len_choice, 0, 0U)
    range.encode_bit_tree(
      self.len_low,
      pos_state * 8,
      3,
      offset.reinterpret_as_uint(),
    )
    return
  }
  range.encode_bit(self.len_choice, 0, 1U)
  if offset < 16 {
    range.encode_bit(self.len_choice, 1, 0U)
    range.encode_bit_tree(
      self.len_mid,
      pos_state * 8,
      3,
      (offset - 8).reinterpret_as_uint(),
    )
    return
  }
  range.encode_bit(self.len_choice, 1, 1U)
  range.encode_bit_tree(
    self.len_high,
    0,
    8,
    (offset - 16).reinterpret_as_uint(),
  )
}

///|
fn LzmaEncoder::encode_distance(
  self : LzmaEncoder,
  range : RangeEncoder,
  distance : Int,
  length : Int,
) -> Unit {
  let value = (distance - 1).reinterpret_as_uint()
  let pos_slot = if value < 4U {
    value
  } else {
    let bits = 30 - value.clz()
    2U + (bits.reinterpret_as_uint() << 1) + ((value >> bits) & 1U)
  }
  let len_state = if length - 2 < 4 { length - 2 } else { 3 }
  range.encode_bit_tree(self.pos_slot[len_state], 0, 6, pos_slot)
  if pos_slot < 4U {
    return
  }
  let bits = (pos_slot >> 1).reinterpret_as_int() - 1
  let base = (2U | (pos_slot & 1U)) << bits
  if pos_slot < 14U {
    let index = (pos_slot - 4U).reinterpret_as_int()
    range.encode_reverse_bit_tree(self.pos_model[index], 0, bits, value - base)
    return
  }
  let direct_bits = bits - 4
  range.encode_direct_bits((value - base) >> 4, direct_bits)
  range.encode_reverse_bit_tree(self.align, 0, 4, (value - base) & 0xFU)
}

///|
fn LzmaEncoder::encode_match(
  self : LzmaEncoder,
  range : RangeEncoder,
  distance : Int,
  length : Int,
  position : Int,
) -> Unit {
  let pos_state = position & ((1 << self.pb) - 1)
  range.encode_bit(self.is_match, self.state * 16 + pos_state, 1U)
  range.encode_bit(self.is_rep, self.state, 0U)
  self.rep0 = (distance - 1).reinterpret_as_uint()
  self.update_state_match()
  self.encode_length(range, length, pos_state)
  self.encode_distance(range, distance, length)
}
