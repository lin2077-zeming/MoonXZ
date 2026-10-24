///|
fn check_kind(name : String) -> @moonxz.CheckKind {
  match name {
    "none" => @moonxz.CheckKind::None
    "crc32" => @moonxz.CheckKind::Crc32
    "sha256" => @moonxz.CheckKind::Sha256
    _ => @moonxz.CheckKind::Crc64
  }
}

///|
fn lzma_check(name : String) -> @lzma.Check {
  match name {
    "none" => @lzma.Check::None
    "crc32" => @lzma.Check::Crc32
    "sha256" => @lzma.Check::Sha256
    _ => @lzma.Check::Crc64
  }
}

///|
fn classify_error(message : String) -> AdapterOutcome {
  let status = if message.contains("Unsupported") ||
    message.contains("unsupported") {
    "unsupported"
  } else if message.contains("OutputLimitExceeded") {
    "output_limit"
  } else {
    "error"
  }
  { status, output: None, detail: message, }
}

///|
fn moonxz_decode(
  input : Bytes,
  format : String,
  max_output : Int32?,
) -> AdapterOutcome {
  try {
    let output = match format {
      "lzma" =>
        match max_output {
          Some(limit) => @moonxz.decompress_lzma1_with_limit(input, limit)
          None => @moonxz.decompress_lzma1(input)
        }
      _ =>
        match max_output {
          Some(limit) => @moonxz.decompress_with_limit(input, limit)
          None => @moonxz.decompress(input)
        }
    }
    { status: "ok", output: Some(output), detail: "", }
  } catch {
    error => classify_error(@debug.to_string(error))
  }
}

///|
fn lzma_mbt_decode(
  input : Bytes,
  format : String,
  concatenated : Bool,
) -> AdapterOutcome {
  try {
    let format_value = match format {
      "lzma" => @lzma.Format::Lzma
      "xz" => @lzma.Format::Xz
      _ => @lzma.Format::Auto
    }
    let options = @lzma.DecodeOptions::{
      ..@lzma.DecodeOptions::default(),
      format: format_value,
      concatenated,
    }
    let output = @lzma.decode(input, options~)
    { status: "ok", output: Some(output), detail: "", }
  } catch {
    error => classify_error(@debug.to_string(error))
  }
}

///|
fn moonxz_stream_decode(input : Bytes, chunk_size : Int32) -> AdapterOutcome {
  try {
    let decoder = @moonxz.XzStreamDecoder::new()
    let collected : Array[Byte] = []
    let mut offset = 0
    let step = if chunk_size < 1 { 1 } else { chunk_size }
    while offset < input.length() {
      let end = if offset + step > input.length() {
        input.length()
      } else {
        offset + step
      }
      decoder.supply(input[offset:end].to_owned())
      offset = end
      while true {
        match decoder.next() {
          Some(block) =>
            for byte in block {
              collected.push(byte)
            }
          None => break
        }
      }
    }
    decoder.finish_input()
    while true {
      match decoder.next() {
        Some(block) =>
          for byte in block {
            collected.push(byte)
          }
        None => break
      }
    }
    if !decoder.is_done() {
      return {
        status: "error",
        output: None,
        detail: "streaming decoder did not reach the footer",
      }
    }
    { status: "ok", output: Some(Bytes::from_array(collected)), detail: "", }
  } catch {
    error => classify_error(@debug.to_string(error))
  }
}

///|
fn lzma_mbt_stream_decode(input : Bytes, chunk_size : Int32) -> AdapterOutcome {
  try {
    let decoder = @lzma.Decoder::new()
    let mut offset = 0
    let step = if chunk_size < 1 { 1 } else { chunk_size }
    while offset < input.length() {
      let end = if offset + step > input.length() {
        input.length()
      } else {
        offset + step
      }
      decoder.write(input[offset:end])
      offset = end
    }
    { status: "ok", output: Some(decoder.finish()), detail: "", }
  } catch {
    error => classify_error(@debug.to_string(error))
  }
}

///|
fn moonxz_encode(input : Bytes, check : String) -> AdapterOutcome {
  let output = @moonxz.compress_with_check(input, check_kind(check))
  { status: "ok", output: Some(output), detail: "", }
}

///|
fn lzma_mbt_encode(input : Bytes, check : String) -> AdapterOutcome {
  try {
    let options = @lzma.EncodeOptions::{
      ..@lzma.EncodeOptions::default(),
      check: lzma_check(check),
    }
    let output = @lzma.encode(input, options~)
    { status: "ok", output: Some(output), detail: "", }
  } catch {
    error => classify_error(@debug.to_string(error))
  }
}
