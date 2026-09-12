///|
const MATCH_HASH_BITS : Int = 16

///|
const MATCH_MIN_LENGTH : Int = 3

///|
const MATCH_MAX_LENGTH : Int = 273

///|
priv struct Match {
  length : Int
  distance : Int
}

///|
/// Builds a hash chain for each input position. A chain entry points to the
/// previous position with the same three-byte hash.
fn build_match_chains(data : Bytes) -> Array[Int] {
  let previous = Array::make(data.length(), -1)
  let heads = Array::make(1 << MATCH_HASH_BITS, -1)
  for position in 0..<data.length() {
    if position + MATCH_MIN_LENGTH - 1 < data.length() {
      let hash = hash_match(data, position)
      previous[position] = heads[hash]
      heads[hash] = position
    }
  }
  previous
}

///|
fn hash_match(data : Bytes, position : Int) -> Int {
  let value = (data[position].to_uint() << 16) |
    (data[position + 1].to_uint() << 8) |
    data[position + 2].to_uint()
  let mixed = value * 2654435761U
  (mixed >> (32 - MATCH_HASH_BITS)).reinterpret_as_int()
}

///|
fn find_match(
  data : Bytes,
  position : Int,
  end : Int,
  previous : Array[Int],
  depth : Int,
  nice_length : Int,
  dictionary_size : Int,
) -> Match? {
  if position + MATCH_MIN_LENGTH > end {
    return None
  }
  let lower_bound = if position > dictionary_size {
    position - dictionary_size
  } else {
    0
  }
  let max_length = if end - position > MATCH_MAX_LENGTH {
    MATCH_MAX_LENGTH
  } else {
    end - position
  }
  let mut candidate = previous[position]
  let mut best_length = 0
  let mut best_distance = 0
  let mut attempts = 0
  while candidate >= lower_bound && attempts < depth {
    let mut length = 0
    while length < max_length &&
          data[candidate + length] == data[position + length] {
      length += 1
    }
    if length >= MATCH_MIN_LENGTH && length > best_length {
      best_length = length
      best_distance = position - candidate
      // Stop once the match is long enough to be worth taking. Without this the
      // search keeps walking the chain to find a strictly longer match, which on
      // repetitive input means comparing hundreds of bytes per candidate and
      // dominates the whole encoder's runtime. Every serious LZMA encoder cuts
      // the search off at a "nice" length for exactly this reason.
      if best_length >= nice_length || best_length == max_length {
        break
      }
    }
    candidate = previous[candidate]
    attempts += 1
  }
  if best_length >= MATCH_MIN_LENGTH {
    Some({ length: best_length, distance: best_distance, })
  } else {
    None
  }
}

///|
/// Hash chain search depth per compression level, following the shape of the
/// reference encoder's presets: level 1 searches a couple of candidates, level 9
/// searches deeply. A larger depth buys a slightly shorter output and costs time
/// roughly linearly.
fn compression_depth(level : Int) -> Int {
  if level <= 0 {
    0
  } else if level <= 2 {
    2
  } else if level <= 4 {
    8
  } else if level <= 6 {
    32
  } else if level <= 8 {
    96
  } else {
    256
  }
}

///|
/// Match length at which the search stops looking for something better.
///
/// The cutoff matters more than the depth on repetitive input: a match of this
/// length already compresses well, and continuing to search only costs time.
fn compression_nice_length(level : Int) -> Int {
  if level <= 0 {
    MATCH_MIN_LENGTH
  } else if level <= 2 {
    16
  } else if level <= 4 {
    32
  } else if level <= 6 {
    64
  } else if level <= 8 {
    128
  } else {
    MATCH_MAX_LENGTH
  }
}
