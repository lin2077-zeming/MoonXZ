///|
fn usage() -> Unit {
  println("MoonXZ 0.1.0")
  println("usage:")
  println("  moonxz demo")
  println("  moonxz compress <hex> [none|crc32|crc64|sha256]")
  println("  moonxz decompress <hex>")
  println("  moonxz roundtrip <hex>")
}

///|
fn run_demo() -> Unit raise {
  let input = b"MoonXZ stores data in a standards-compatible XZ stream.\n"
  let encoded = @moonxz.compress(input)
  let decoded = @moonxz.decompress(encoded)
  println("input_bytes=\{input.length()} xz_bytes=\{encoded.length()}")
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
      _ => usage()
    }
  } catch {
    error => println("error: \{error}")
  }
}
