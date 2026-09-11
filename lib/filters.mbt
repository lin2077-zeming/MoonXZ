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
fn encode_filter(data : Bytes, filter : FilterMode) -> Bytes {
  match filter {
    None => data
    Delta(distance) => encode_delta(data, distance)
    X86 => x86_bcj_filter(data, true)
  }
}

///|
fn decode_filter(data : Bytes, filter : FilterMode) -> Bytes {
  match filter {
    None => data
    Delta(distance) => decode_delta(data, distance)
    X86 => x86_bcj_filter(data, false)
  }
}
