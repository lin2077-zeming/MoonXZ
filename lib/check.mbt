///|
/// Integrity check algorithms supported by the XZ format.
pub(all) enum CheckKind {
  None
  Crc32
  Crc64
  Sha256
} derive(Eq, @debug.Debug)

///|
pub fn CheckKind::id(self : CheckKind) -> Int {
  match self {
    None => 0
    Crc32 => 1
    Crc64 => 4
    Sha256 => 10
  }
}

///|
pub fn CheckKind::size(self : CheckKind) -> Int {
  match self {
    None => 0
    Crc32 => 4
    Crc64 => 8
    Sha256 => 32
  }
}

///|
pub fn CheckKind::from_id(id : Int) -> CheckKind? {
  match id {
    0 => Some(None)
    1 => Some(Crc32)
    4 => Some(Crc64)
    10 => Some(Sha256)
    _ => None
  }
}

///|
pub fn crc32(data : Bytes) -> UInt {
  let mut crc = 0xFFFFFFFFU
  for byte in data {
    crc = crc ^ byte.to_uint()
    for _ in 0..<8 {
      if (crc & 1U) != 0U {
        crc = (crc >> 1) ^ 0xEDB88320U
      } else {
        crc = crc >> 1
      }
    }
  }
  crc ^ 0xFFFFFFFFU
}

///|
pub fn crc64(data : Bytes) -> UInt64 {
  let mut crc = 0xFFFFFFFFFFFFFFFFUL
  for byte in data {
    crc = crc ^ byte.to_uint64()
    for _ in 0..<8 {
      if (crc & 1UL) != 0UL {
        crc = (crc >> 1) ^ 0xC96C5795D7870F42UL
      } else {
        crc = crc >> 1
      }
    }
  }
  crc ^ 0xFFFFFFFFFFFFFFFFUL
}

///|
fn rotr32(value : UInt, bits : Int) -> UInt {
  (value >> bits) | (value << (32 - bits))
}

///|
fn sha256_round(
  a : UInt,
  b : UInt,
  c : UInt,
  d : UInt,
  e : UInt,
  f : UInt,
  g : UInt,
  h : UInt,
  k : UInt,
  w : UInt,
) -> (UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt) {
  let big_s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
  let choose = (e & f) ^ (e.lnot() & g)
  let temp1 = h + big_s1 + choose + k + w
  let big_s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
  let majority = (a & b) ^ (a & c) ^ (b & c)
  let temp2 = big_s0 + majority
  (temp1 + temp2, a, b, c, d + temp1, e, f, g)
}

///|
/// Computes the SHA-256 digest required by XZ check type 10.
pub fn sha256(data : Bytes) -> Bytes {
  let bit_length = data.length().to_uint64() * 8UL
  let padded = Array(capacity=data.length() + 9)
  for byte in data {
    padded.push(byte)
  }
  padded.push(b'\x80')
  while padded.length() % 64 != 56 {
    padded.push(b'\x00')
  }
  for shift in 0..<8 {
    padded.push(((bit_length >> ((7 - shift) * 8)) & 0xFFUL).to_byte())
  }

  let mut h0 = 0x6A09E667U
  let mut h1 = 0xBB67AE85U
  let mut h2 = 0x3C6EF372U
  let mut h3 = 0xA54FF53AU
  let mut h4 = 0x510E527FU
  let mut h5 = 0x9B05688CU
  let mut h6 = 0x1F83D9ABU
  let mut h7 = 0x5BE0CD19U
  let k : Array[UInt] = [
    0x428A2F98U, 0x71374491U, 0xB5C0FBCFU, 0xE9B5DBA5U, 0x3956C25BU, 0x59F111F1U,
    0x923F82A4U, 0xAB1C5ED5U, 0xD807AA98U, 0x12835B01U, 0x243185BEU, 0x550C7DC3U,
    0x72BE5D74U, 0x80DEB1FEU, 0x9BDC06A7U, 0xC19BF174U, 0xE49B69C1U, 0xEFBE4786U,
    0x0FC19DC6U, 0x240CA1CCU, 0x2DE92C6FU, 0x4A7484AAU, 0x5CB0A9DCU, 0x76F988DAU,
    0x983E5152U, 0xA831C66DU, 0xB00327C8U, 0xBF597FC7U, 0xC6E00BF3U, 0xD5A79147U,
    0x06CA6351U, 0x14292967U, 0x27B70A85U, 0x2E1B2138U, 0x4D2C6DFCU, 0x53380D13U,
    0x650A7354U, 0x766A0ABBU, 0x81C2C92EU, 0x92722C85U, 0xA2BFE8A1U, 0xA81A664BU,
    0xC24B8B70U, 0xC76C51A3U, 0xD192E819U, 0xD6990624U, 0xF40E3585U, 0x106AA070U,
    0x19A4C116U, 0x1E376C08U, 0x2748774CU, 0x34B0BCB5U, 0x391C0CB3U, 0x4ED8AA4AU,
    0x5B9CCA4FU, 0x682E6FF3U, 0x748F82EEU, 0x78A5636FU, 0x84C87814U, 0x8CC70208U,
    0x90BEFFFAU, 0xA4506CEBU, 0xBEF9A3F7U, 0xC67178F2U,
  ]
  let schedule = Array::make(64, 0U)
  for chunk_start in 0..<(padded.length() / 64) {
    for i in 0..<16 {
      let offset = chunk_start * 64 + i * 4
      schedule[i] = (padded[offset].to_uint() << 24) |
        (padded[offset + 1].to_uint() << 16) |
        (padded[offset + 2].to_uint() << 8) |
        padded[offset + 3].to_uint()
    }
    for i in 16..<64 {
      let x = schedule[i - 15]
      let y = schedule[i - 2]
      let s0 = rotr32(x, 7) ^ rotr32(x, 18) ^ (x >> 3)
      let s1 = rotr32(y, 17) ^ rotr32(y, 19) ^ (y >> 10)
      schedule[i] = schedule[i - 16] + s0 + schedule[i - 7] + s1
    }
    let mut a = h0
    let mut b = h1
    let mut c = h2
    let mut d = h3
    let mut e = h4
    let mut f = h5
    let mut g = h6
    let mut h = h7
    for i in 0..<64 {
      let next = sha256_round(a, b, c, d, e, f, g, h, k[i], schedule[i])
      a = next.0
      b = next.1
      c = next.2
      d = next.3
      e = next.4
      f = next.5
      g = next.6
      h = next.7
    }
    h0 += a
    h1 += b
    h2 += c
    h3 += d
    h4 += e
    h5 += f
    h6 += g
    h7 += h
  }
  let out = Array(capacity=4)
  push_u32_be(out, h0)
  push_u32_be(out, h1)
  push_u32_be(out, h2)
  push_u32_be(out, h3)
  push_u32_be(out, h4)
  push_u32_be(out, h5)
  push_u32_be(out, h6)
  push_u32_be(out, h7)
  bytes_from_array(out)
}

///|
pub fn check_bytes(kind : CheckKind, data : Bytes) -> Bytes {
  match kind {
    None => b""
    Crc32 => {
      let out = Array(capacity=4)
      push_u32_le(out, crc32(data))
      bytes_from_array(out)
    }
    Crc64 => {
      let out = Array(capacity=8)
      push_u64_le(out, crc64(data))
      bytes_from_array(out)
    }
    Sha256 => sha256(data)
  }
}
