///|
fn normalize_delta_distance(distance : Int) -> Int {
  if distance < 1 {
    1
  } else if distance > 256 {
    256
  } else {
    distance
  }
}

///|
fn encode_delta(data : Bytes, distance : Int) -> Bytes {
  let distance = normalize_delta_distance(distance)
  let output = Array(capacity=data.length())
  for i in 0..<data.length() {
    let previous = if i < distance { b'\x00' } else { data[i - distance] }
    output.push((data[i].to_int() - previous.to_int()).to_byte())
  }
  bytes_from_array(output)
}

///|
fn decode_delta(data : Bytes, distance : Int) -> Bytes {
  let distance = normalize_delta_distance(distance)
  let output = Array(capacity=data.length())
  for i in 0..<data.length() {
    let previous = if i < distance { b'\x00' } else { output[i - distance] }
    output.push((data[i].to_int() + previous.to_int()).to_byte())
  }
  bytes_from_array(output)
}

///|
fn x86_test_msbyte(value : Byte) -> Bool {
  value == b'\x00' || value == b'\xFF'
}

///|
fn x86_mask_to_bit_number(mask : UInt) -> Int {
  match mask {
    0U => 0
    1U => 1
    2U | 3U => 2
    _ => 3
  }
}

///|
/// Applies the XZ x86 BCJ filter to one complete block.
fn x86_bcj_filter(data : Bytes, encode : Bool) -> Bytes {
  if data.length() < 5 {
    return data
  }
  let buffer = Array(capacity=data.length())
  for byte in data {
    buffer.push(byte)
  }
  let mut prev_mask : UInt = 0U
  let mut prev_pos : UInt = 0xFFFFFFFBU
  let now_pos : UInt = 0U
  let limit = data.length() - 5
  let mut buffer_pos = 0
  while buffer_pos <= limit {
    let current = buffer[buffer_pos]
    if current != b'\xE8' && current != b'\xE9' {
      buffer_pos += 1
      continue
    }
    let offset = now_pos + buffer_pos.reinterpret_as_uint() - prev_pos
    prev_pos = now_pos + buffer_pos.reinterpret_as_uint()
    if offset > 5U {
      prev_mask = 0U
    } else {
      for _ in 0..<offset.reinterpret_as_int() {
        prev_mask = (prev_mask & 0x77U) << 1
      }
    }

    let msbyte = buffer[buffer_pos + 4]
    if x86_test_msbyte(msbyte) && prev_mask >> 1 <= 4U && prev_mask >> 1 != 3U {
      let mut src = (msbyte.to_uint() << 24) |
        (buffer[buffer_pos + 3].to_uint() << 16) |
        (buffer[buffer_pos + 2].to_uint() << 8) |
        buffer[buffer_pos + 1].to_uint()
      let mut dest = 0U
      while true {
        let position = now_pos + buffer_pos.reinterpret_as_uint() + 5U
        dest = if encode { src + position } else { src - position }
        if prev_mask == 0U {
          break
        }
        let bit_number = x86_mask_to_bit_number(prev_mask >> 1)
        let high = (dest >> (24 - bit_number * 8)).to_byte()
        if !x86_test_msbyte(high) {
          break
        }
        let shift = 32 - bit_number * 8
        let mask = if shift >= 32 { 0xFFFFFFFFU } else { (1U << shift) - 1U }
        src = dest ^ mask
      }
      buffer[buffer_pos + 4] = if ((dest >> 24) & 1U) == 0U {
        b'\x00'
      } else {
        b'\xFF'
      }
      buffer[buffer_pos + 3] = (dest >> 16).to_byte()
      buffer[buffer_pos + 2] = (dest >> 8).to_byte()
      buffer[buffer_pos + 1] = dest.to_byte()
      buffer_pos += 5
      prev_mask = 0U
    } else {
      buffer_pos += 1
      prev_mask = prev_mask | 1U
      if x86_test_msbyte(msbyte) {
        prev_mask = prev_mask | 0x10U
      }
    }
  }
  bytes_from_array(buffer)
}

///|
/// Applies the XZ ARM (little endian) BCJ filter to one complete block.
///
/// ARM words are little endian, so the `BL` opcode `0xEB` is the *last* byte of
/// the word and the 24-bit signed offset occupies the first three bytes. The
/// offset is a word offset relative to the instruction address plus eight, so
/// the filter shifts it left by two and rewrites it as an absolute byte address.
fn arm_bcj_filter(data : Bytes, encode : Bool) -> Bytes {
  if data.length() < 8 {
    return data
  }
  let buffer : Array[Byte] = []
  for byte in data {
    buffer.push(byte)
  }
  let limit = data.length() - 4
  let mut pos = 0
  while pos <= limit {
    // `buffer[pos + 3]` holds the opcode. The word's low two bits live in the
    // top two bits of `buffer[pos + 2]`, and they must clear so that only
    // word-aligned branch targets are rewritten.
    if buffer[pos + 3] == b'\xEB' && (buffer[pos + 2].to_uint() & 0x03U) == 0U {
      // Shift-isolated bindings: `|` binds tighter than `<<` in MoonBit, so the
      // fields must never appear in one shared expression.
      let high = buffer[pos + 2].to_uint() << 16
      let middle = buffer[pos + 1].to_uint() << 8
      let low = buffer[pos + 0].to_uint()
      let mut src = high
      src = src | middle
      src = src | low
      src = src << 2
      let position = pos.reinterpret_as_uint() + 8U
      let dest = if encode { src + position } else { src - position }
      let value = dest >> 2
      buffer[pos + 2] = (value >> 16).to_byte()
      buffer[pos + 1] = (value >> 8).to_byte()
      buffer[pos + 0] = value.to_byte()
      buffer[pos + 3] = b'\xEB'
      pos += 4
      continue
    }
    pos += 1
  }
  bytes_from_array(buffer)
}

///|
/// Applies the XZ ARM64 (AArch64) BCJ filter to one complete block.
///
/// AArch64 branch instructions are fixed 32-bit words: `100101` in the top six
/// bits marks `BL`, and in encoding order the source field is stored as the top
/// three bits followed by the low 24 bits of the low 26-bit immediate.
/// The 26-bit offset is scaled by four, giving a reach of +/-128 MiB that is
/// measured from the instruction address.
fn arm64_bcj_filter(data : Bytes, encode : Bool) -> Bytes {
  if data.length() < 4 {
    return data
  }
  let buffer : Array[Byte] = []
  for byte in data {
    buffer.push(byte)
  }
  let limit = data.length() - 4
  let mut pos = 0
  while pos <= limit {
    if buffer[pos + 3] == b'\x94' || buffer[pos + 3] == b'\x95' {
      let top = (buffer[pos + 3].to_uint() & 0x03U) << 24
      let high = buffer[pos + 2].to_uint() << 16
      let middle = buffer[pos + 1].to_uint() << 8
      let low = buffer[pos + 0].to_uint()
      let mut src = top
      src = src | high
      src = src | middle
      src = src | low
      if (src & 0x03000000U) == 0U {
        let value = src << 2
        let position = pos.reinterpret_as_uint()
        let dest = if encode { value + position } else { value - position }
        let packed = dest >> 2
        buffer[pos + 3] = (packed >> 24).to_byte() | b'\x94'
        buffer[pos + 2] = (packed >> 16).to_byte()
        buffer[pos + 1] = (packed >> 8).to_byte()
        buffer[pos + 0] = packed.to_byte()
        pos += 4
        continue
      }
    }
    pos += 1
  }
  bytes_from_array(buffer)
}

///|
/// Applies the XZ SPARC BCJ filter to one complete block.
///
/// SPARC `call` instructions are big-endian words whose top two bits are `01`.
/// The 30-bit word offset is relative to the current instruction, which is the
/// same convention the encoder and decoder share here.
fn sparc_bcj_filter(data : Bytes, encode : Bool) -> Bytes {
  if data.length() < 4 {
    return data
  }
  let buffer : Array[Byte] = []
  for byte in data {
    buffer.push(byte)
  }
  let limit = data.length() - 4
  let mut pos = 0
  while pos <= limit {
    if (buffer[pos].to_uint() & 0xC0U) == 0x40U {
      let top = buffer[pos].to_uint() << 24
      let upper = buffer[pos + 1].to_uint() << 16
      let lower = buffer[pos + 2].to_uint() << 8
      let low = buffer[pos + 3].to_uint()
      let mut src = top
      src = src | upper
      src = src | lower
      src = src | low
      src = src << 2
      let position = pos.reinterpret_as_uint()
      let dest = if encode { src + position } else { src - position }
      let out0 = (dest >> 24) & 0x3FU
      buffer[pos] = out0.to_byte() | b'\x40'
      buffer[pos + 1] = (dest >> 16).to_byte()
      buffer[pos + 2] = (dest >> 8).to_byte()
      buffer[pos + 3] = (dest >> 2).to_byte()
      pos += 4
      continue
    }
    pos += 1
  }
  bytes_from_array(buffer)
}

///|
fn encode_filter(data : Bytes, filter : FilterMode) -> Bytes {
  match filter {
    None => data
    Delta(distance) => encode_delta(data, distance)
    X86 => x86_bcj_filter(data, true)
    Arm => arm_bcj_filter(data, true)
    Arm64 => arm64_bcj_filter(data, true)
    Sparc => sparc_bcj_filter(data, true)
  }
}

///|
fn decode_filter(data : Bytes, filter : FilterMode) -> Bytes {
  match filter {
    None => data
    Delta(distance) => decode_delta(data, distance)
    X86 => x86_bcj_filter(data, false)
    Arm => arm_bcj_filter(data, false)
    Arm64 => arm64_bcj_filter(data, false)
    Sparc => sparc_bcj_filter(data, false)
  }
}
