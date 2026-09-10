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
      if best_length == max_length {
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
fn compression_depth(level : Int) -> Int {
  if level <= 0 {
    0
  } else if level >= 9 {
    1024
  } else {
    1 << level
  }
}
