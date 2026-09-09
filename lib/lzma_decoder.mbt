///|
const LZMA_PROB_INIT : UInt = 1024U

///|
fn make_probability_array(length : Int) -> Array[UInt] {
  Array::make(length, LZMA_PROB_INIT)
}

///|
fn reset_probability_array(probabilities : Array[UInt]) -> Unit {
  for i in 0..<probabilities.length() {
    probabilities[i] = LZMA_PROB_INIT
  }
}

///|
priv struct LzmaDecoder {
  mut state : Int
  mut rep0 : UInt
  mut rep1 : UInt
  mut rep2 : UInt
  mut rep3 : UInt
  mut lc : Int
  mut lp : Int
  mut pb : Int
  mut literal_probs : Array[UInt]
  is_match : Array[UInt]
  is_rep : Array[UInt]
  is_rep_g0 : Array[UInt]
  is_rep_g1 : Array[UInt]
  is_rep_g2 : Array[UInt]
  is_rep0_long : Array[UInt]
  len_choice : Array[UInt]
  len_low : Array[UInt]
  len_mid : Array[UInt]
  len_high : Array[UInt]
  rep_len_choice : Array[UInt]
  rep_len_low : Array[UInt]
  rep_len_mid : Array[UInt]
  rep_len_high : Array[UInt]
  pos_slot : Array[Array[UInt]]
  pos_model : Array[Array[UInt]]
  align : Array[UInt]
}

///|
fn LzmaDecoder::new(lc : Int, lp : Int, pb : Int) -> LzmaDecoder raise XzError {
  if lc < 0 || lc > 8 || lp < 0 || lp > 4 || pb < 0 || pb > 4 || lc + lp > 4 {
    raise Unsupported("invalid LZMA properties: lc=\{lc} lp=\{lp} pb=\{pb}")
  }
  let pos_slot : Array[Array[UInt]] = Array(capacity=4)
  for _ in 0..<4 {
    pos_slot.push(make_probability_array(64))
  }
  let pos_model : Array[Array[UInt]] = Array(capacity=10)
  for i in 0..<10 {
    let pos_slot_value = 4 + i
    let bits = (pos_slot_value >> 1) - 1
    pos_model.push(make_probability_array(1 << bits))
  }
  let decoder : LzmaDecoder = {
    state: 0,
    rep0: 0U,
    rep1: 0U,
    rep2: 0U,
    rep3: 0U,
    lc,
    lp,
    pb,
    literal_probs: make_probability_array(0x300 << (lc + lp)),
    is_match: make_probability_array(12 << 4),
    is_rep: make_probability_array(12),
    is_rep_g0: make_probability_array(12),
    is_rep_g1: make_probability_array(12),
    is_rep_g2: make_probability_array(12),
    is_rep0_long: make_probability_array(12 << 4),
    len_choice: make_probability_array(2),
    len_low: make_probability_array(16 * 8),
    len_mid: make_probability_array(16 * 8),
    len_high: make_probability_array(256),
    rep_len_choice: make_probability_array(2),
    rep_len_low: make_probability_array(16 * 8),
    rep_len_mid: make_probability_array(16 * 8),
    rep_len_high: make_probability_array(256),
    pos_slot,
    pos_model,
    align: make_probability_array(16),
  }
  decoder
}

///|
fn LzmaDecoder::reset_state(self : LzmaDecoder) -> Unit {
  self.state = 0
  self.rep0 = 0U
  self.rep1 = 0U
  self.rep2 = 0U
  self.rep3 = 0U
  reset_probability_array(self.literal_probs)
  reset_probability_array(self.is_match)
  reset_probability_array(self.is_rep)
  reset_probability_array(self.is_rep_g0)
  reset_probability_array(self.is_rep_g1)
  reset_probability_array(self.is_rep_g2)
  reset_probability_array(self.is_rep0_long)
  reset_probability_array(self.len_choice)
  reset_probability_array(self.len_low)
  reset_probability_array(self.len_mid)
  reset_probability_array(self.len_high)
  reset_probability_array(self.rep_len_choice)
  reset_probability_array(self.rep_len_low)
  reset_probability_array(self.rep_len_mid)
  reset_probability_array(self.rep_len_high)
  for i in 0..<self.pos_slot.length() {
    reset_probability_array(self.pos_slot[i])
  }
  for i in 0..<self.pos_model.length() {
    reset_probability_array(self.pos_model[i])
  }
  reset_probability_array(self.align)
}

///|
fn LzmaDecoder::set_properties(
  self : LzmaDecoder,
  lc : Int,
  lp : Int,
  pb : Int,
) -> Unit raise XzError {
  if lc < 0 || lc > 8 || lp < 0 || lp > 4 || pb < 0 || pb > 4 || lc + lp > 4 {
    raise Unsupported("invalid LZMA properties: lc=\{lc} lp=\{lp} pb=\{pb}")
  }
  self.lc = lc
  self.lp = lp
  self.pb = pb
  self.literal_probs = make_probability_array(0x300 << (lc + lp))
  self.reset_state()
}

///|
fn LzmaDecoder::update_state_literal(self : LzmaDecoder) -> Unit {
  if self.state < 4 {
    self.state = 0
  } else if self.state < 10 {
    self.state -= 3
  } else {
    self.state -= 6
  }
}

///|
fn LzmaDecoder::update_state_match(self : LzmaDecoder) -> Unit {
  self.state = if self.state < 7 { 7 } else { 10 }
}

///|
fn LzmaDecoder::update_state_rep(self : LzmaDecoder) -> Unit {
  self.state = if self.state < 7 { 8 } else { 11 }
}

///|
fn LzmaDecoder::update_state_short_rep(self : LzmaDecoder) -> Unit {
  self.state = if self.state < 7 { 9 } else { 11 }
}

///|
fn LzmaDecoder::decode_length(
  self : LzmaDecoder,
  range : RangeDecoder,
  pos_state : Int,
  is_rep : Bool,
) -> Int raise XzError {
  let choice = if is_rep { self.rep_len_choice } else { self.len_choice }
  let low = if is_rep { self.rep_len_low } else { self.len_low }
  let mid = if is_rep { self.rep_len_mid } else { self.len_mid }
  let high = if is_rep { self.rep_len_high } else { self.len_high }
  let length = if range.decode_bit(choice, 0) == 0U {
    range.decode_bit_tree(low, pos_state * 8, 3).reinterpret_as_int()
  } else if range.decode_bit(choice, 1) == 0U {
    range.decode_bit_tree(mid, pos_state * 8, 3).reinterpret_as_int() + 8
  } else {
    range.decode_bit_tree(high, 0, 8).reinterpret_as_int() + 16
  }
  length + 2
}

///|
fn LzmaDecoder::decode_distance(
  self : LzmaDecoder,
  range : RangeDecoder,
  length : Int,
) -> UInt raise XzError {
  let len_state = if length - 2 < 4 { length - 2 } else { 3 }
  let pos_slot = range.decode_bit_tree(self.pos_slot[len_state], 0, 6)
  if pos_slot < 4U {
    return pos_slot
  }
  let bits = (pos_slot >> 1).reinterpret_as_int() - 1
  let mut distance = (2U | (pos_slot & 1U)) << bits
  if pos_slot < 14U {
    let index = (pos_slot - 4U).reinterpret_as_int()
    distance = distance +
      range.decode_reverse_bit_tree(self.pos_model[index], 0, bits)
  } else {
    let direct_bits = bits - 4
    distance = distance + (range.decode_direct_bits(direct_bits) << 4)
    distance = distance + range.decode_reverse_bit_tree(self.align, 0, 4)
  }
  distance
}

///|
fn LzmaDecoder::copy_match(
  self : LzmaDecoder,
  output : Array[Byte],
  distance : UInt,
  length : Int,
  dict_start : Int,
  dict_size : Int,
) -> Unit raise XzError {
  ignore(self)
  if distance >= 0xFFFFFFFFU {
    raise Corrupt("LZMA end marker is not valid inside an LZMA2 chunk")
  }
  let actual_distance = distance.reinterpret_as_int() + 1
  if actual_distance > dict_size ||
    actual_distance > output.length() - dict_start {
    raise Corrupt("LZMA match distance exceeds the available dictionary")
  }
  for _ in 0..<length {
    let index = output.length() - actual_distance
    output.push(output[index])
  }
}

///|
fn LzmaDecoder::decode_literal(
  self : LzmaDecoder,
  range : RangeDecoder,
  output : Array[Byte],
  dict_start : Int,
) -> Unit raise XzError {
  let position = output.length() - dict_start
  let previous = if position == 0 {
    b'\x00'
  } else {
    output[output.length() - 1]
  }
  let literal_state = ((position & ((1 << self.lp) - 1)) << self.lc) |
    (previous.to_int() >> (8 - self.lc))
  let base = literal_state * 0x300
  let mut symbol : UInt = 1U
  if self.state >= 7 {
    let match_byte = output[output.length() - self.rep0.reinterpret_as_int() - 1].to_uint()
    let mut matched : UInt = match_byte
    for _ in 0..<8 {
      let match_bit = (matched >> 7) & 1U
      matched = matched << 1
      let bit = range.decode_bit(
        self.literal_probs,
        base + (((1U + match_bit) << 8) | symbol).reinterpret_as_int(),
      )
      symbol = (symbol << 1) | bit
      if match_bit != bit || symbol >= 0x100U {
        break
      }
    }
  }
  while symbol < 0x100U {
    symbol = (symbol << 1) |
      range.decode_bit(self.literal_probs, base + symbol.reinterpret_as_int())
  }
  output.push((symbol - 0x100U).to_byte())
  self.update_state_literal()
}

///|
fn LzmaDecoder::decode_chunk(
  self : LzmaDecoder,
  compressed : Bytes,
  uncompressed_size : Int,
  output : Array[Byte],
  dict_start : Int,
  dict_size : Int,
) -> Unit raise XzError {
  let start = output.length()
  let range = RangeDecoder::new(compressed)
  while output.length() - start < uncompressed_size {
    let position = output.length() - dict_start
    let pos_state = position & ((1 << self.pb) - 1)
    let state_index = self.state * 16 + pos_state
    if range.decode_bit(self.is_match, state_index) == 0U {
      self.decode_literal(range, output, dict_start)
      continue
    }
    if range.decode_bit(self.is_rep, self.state) == 0U {
      self.rep3 = self.rep2
      self.rep2 = self.rep1
      self.rep1 = self.rep0
      self.update_state_match()
      let length = self.decode_length(range, pos_state, false)
      self.rep0 = self.decode_distance(range, length)
      self.copy_match(output, self.rep0, length, dict_start, dict_size)
      continue
    }
    let mut distance = self.rep0
    if range.decode_bit(self.is_rep_g0, self.state) == 0U {
      if range.decode_bit(self.is_rep0_long, state_index) == 0U {
        self.update_state_short_rep()
        self.copy_match(output, distance, 1, dict_start, dict_size)
        continue
      }
    } else {
      if range.decode_bit(self.is_rep_g1, self.state) == 0U {
        distance = self.rep1
      } else {
        if range.decode_bit(self.is_rep_g2, self.state) == 0U {
          distance = self.rep2
        } else {
          distance = self.rep3
          self.rep3 = self.rep2
        }
        self.rep2 = self.rep1
      }
      self.rep1 = self.rep0
      self.rep0 = distance
    }
    let length = self.decode_length(range, pos_state, true)
    self.update_state_rep()
    self.copy_match(output, distance, length, dict_start, dict_size)
  }
}

///|
fn decode_lzma_properties(value : Int) -> (Int, Int, Int) raise XzError {
  if value < 0 || value > 224 {
    raise Corrupt("invalid LZMA property byte")
  }
  let lc = value % 9
  let rest = value / 9
  let lp = rest % 5
  let pb = rest / 5
  (lc, lp, pb)
}
