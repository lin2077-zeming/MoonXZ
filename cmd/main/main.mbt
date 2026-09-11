///|
fn usage() -> Unit {
  println("MoonXZ 0.4.0")
  println("usage:")
  println("  moonxz demo")
  println("  moonxz compress <hex> [none|crc32|crc64|sha256]")
  println("  moonxz decompress <hex>")
  println("  moonxz roundtrip <hex>")
  println("  moonxz lzma-decompress <hex>")
  println("  moonxz lzma-roundtrip <hex>")
  println(
    "  moonxz compress-file <input> <output> [none|crc32|crc64|sha256] [none|x86|arm|arm64|powerpc|sparc|delta]",
  )
  println("  moonxz decompress-file <input> <output>")
  println("  moonxz lzma-compress-file <input> <output>")
  println("  moonxz lzma-decompress-file <input> <output>")
}

///|
fn run_demo() -> Unit raise {
  let input = Bytes::repeat(b"MoonXZ compressed LZMA2 stream demo.\n", 200)
  let encoded = @moonxz.compress(input)
  let decoded = @moonxz.decompress(encoded)
  println(
    "input_bytes=\{input.length()} xz_bytes=\{encoded.length()} percent=\{encoded.length() * 100 / input.length()}",
  )
  println("roundtrip=\{decoded == input}")
  println("xz_hex=\{@hex.encode(encoded)}")
}

///|
fn parse_check(name : String) -> @moonxz.CheckKind? {
  match name {
    "none" => Some(@moonxz.CheckKind::None)
    "crc32" => Some(@moonxz.CheckKind::Crc32)
    "crc64" => Some(@moonxz.CheckKind::Crc64)
    "sha256" => Some(@moonxz.CheckKind::Sha256)
    _ => None
  }
}

///|
fn parse_filter(name : String) -> @moonxz.FilterMode? {
  match name {
    "none" => Some(@moonxz.FilterMode::None)
    "x86" => Some(@moonxz.FilterMode::X86)
    "arm" => Some(@moonxz.FilterMode::Arm)
    "arm64" => Some(@moonxz.FilterMode::Arm64)
    "sparc" => Some(@moonxz.FilterMode::Sparc)
    "delta" => Some(@moonxz.FilterMode::Delta(1))
    _ => None
  }
}

///|
fn run_compress(hex : String, check_name : String) -> Unit raise {
  let input = @hex.decode(hex)
  let check_kind = match parse_check(check_name) {
    Some(value) => value
    None => raise Failure::Failure("unknown check type: \{check_name}")
  }
  let encoded = @moonxz.compress_with_check(input, check_kind)
  println(@hex.encode(encoded))
}

///|
fn run_decompress(hex : String) -> Unit raise {
  let input = @hex.decode(hex)
  let decoded = @moonxz.decompress(input)
  println(@hex.encode(decoded))
}

///|
fn run_roundtrip(hex : String) -> Unit raise {
  let input = @hex.decode(hex)
  let decoded = @moonxz.decompress(@moonxz.compress(input))
  println(if decoded == input { "true" } else { "false" })
}

///|
fn run_lzma_decompress(hex : String) -> Unit raise {
  let input = @hex.decode(hex)
  let decoded = @moonxz.decompress_lzma1(input)
  println(@hex.encode(decoded))
}

///|
fn run_lzma_roundtrip(hex : String) -> Unit raise {
  let input = @hex.decode(hex)
  let encoded = @moonxz.compress_lzma1(input)
  let decoded = @moonxz.decompress_lzma1(encoded)
  println(if decoded == input { "true" } else { "false" })
}

///|
fn run_lzma_compress_file(
  input_path : String,
  output_path : String,
) -> Unit raise {
  let input = @fs.read_file_to_bytes(input_path)
  let output = @moonxz.compress_lzma1(input)
  @fs.write_bytes_to_file(output_path, output)
  println(
    "lzma-compressed input_bytes=\{input.length()} output_bytes=\{output.length()}",
  )
}

///|
fn run_lzma_decompress_file(
  input_path : String,
  output_path : String,
) -> Unit raise {
  let input = @fs.read_file_to_bytes(input_path)
  let decoded = @moonxz.decompress_lzma1(input)
  @fs.write_bytes_to_file(output_path, decoded)
  println(
    "lzma-decompressed input_bytes=\{input.length()} output_bytes=\{decoded.length()}",
  )
}

///|
fn run_compress_file(
  input_path : String,
  output_path : String,
  check_name : String,
  filter_name : String,
) -> Unit raise {
  let check_kind = match parse_check(check_name) {
    Some(value) => value
    None => raise Failure::Failure("unknown check type: \{check_name}")
  }
  let filter = match parse_filter(filter_name) {
    Some(value) => value
    None => raise Failure::Failure("unknown filter: \{filter_name}")
  }
  let input = @fs.read_file_to_bytes(input_path)
  let options = @moonxz.CompressionOptions::new(filter~)
  let writer = @moonxz.XzWriter::new(check_kind~, options~)
  let output = writer.write(input) + writer.finish()
  @fs.write_bytes_to_file(output_path, output)
  println(
    "compressed input_bytes=\{input.length()} output_bytes=\{output.length()}",
  )
}

///|
fn run_decompress_file(input_path : String, output_path : String) -> Unit raise {
  let input = @fs.read_file_to_bytes(input_path)
  let reader = @moonxz.XzReader::new(input)
  let output : Array[Byte] = []
  while true {
    match reader.read_block() {
      Some(block) =>
        for byte in block {
          output.push(byte)
        }
      None => break
    }
  }
  let decoded = Bytes::from_array(output)
  @fs.write_bytes_to_file(output_path, decoded)
  println(
    "decompressed input_bytes=\{input.length()} output_bytes=\{decoded.length()}",
  )
}

///|
fn main {
  let args = @env.args()
  if args.length() < 2 {
    usage()
    return
  }
  let command = args[1]
  try {
    match command {
      "demo" => run_demo()
      "compress" if args.length() == 3 => run_compress(args[2], "crc64")
      "compress" if args.length() == 4 => run_compress(args[2], args[3])
      "decompress" if args.length() == 3 => run_decompress(args[2])
      "roundtrip" if args.length() == 3 => run_roundtrip(args[2])
      "lzma-decompress" if args.length() == 3 => run_lzma_decompress(args[2])
      "lzma-roundtrip" if args.length() == 3 => run_lzma_roundtrip(args[2])
      "lzma-compress-file" if args.length() == 4 =>
        run_lzma_compress_file(args[2], args[3])
      "lzma-decompress-file" if args.length() == 4 =>
        run_lzma_decompress_file(args[2], args[3])
      "compress-file" if args.length() == 4 =>
        run_compress_file(args[2], args[3], "crc64", "none")
      "compress-file" if args.length() == 5 =>
        run_compress_file(args[2], args[3], args[4], "none")
      "compress-file" if args.length() == 6 =>
        run_compress_file(args[2], args[3], args[4], args[5])
      "decompress-file" if args.length() == 4 =>
        run_decompress_file(args[2], args[3])
      _ => usage()
    }
  } catch {
    error => println("error: \{@debug.to_string(error)}")
  }
}
