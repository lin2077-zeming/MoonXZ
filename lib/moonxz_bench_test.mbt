///|
/// Compression and decompression benchmarks.
///
/// Run with `moon test --release --target native` to print the tables, or
/// `moon bench --release --target native` to run them through the bench harness.
///
/// These exist so that the performance and ratio numbers in the README are
/// measured rather than guessed. Absolute timings are host-dependent; the useful
/// signals are the shape of the growth curve and the output sizes.
///
/// The payloads come from a seeded xorshift so a run is reproducible. They cover
/// the input classes that stress different code paths: highly repetitive text
/// (long matches), pseudo-random bytes (no matches, so the literal path dominates)
/// and a mix of both.
///
/// Note that `@bench.monotonic_clock_end` reports microseconds.

///|
fn bench_payload(kind : String, size : Int) -> Bytes {
  if kind == "repetitive" {
    let unit = b"MoonXZ compression benchmark payload line.\n"
    Bytes::repeat(unit, size / unit.length() + 1)[:size].to_owned()
  } else if kind == "random" {
    bench_pseudo_random(0x5EEDU, size)
  } else {
    let half = size / 2
    let unit = b"MoonXZ mixed payload section.\n"
    Bytes::repeat(unit, half / unit.length() + 1)[:half].to_owned() +
    bench_pseudo_random(0xC0FFEEU, size - half)
  }
}

///|
fn bench_pseudo_random(seed : UInt, length : Int) -> Bytes {
  let out : Array[Byte] = Array(capacity=length)
  let mut state = if seed == 0U { 0x2545F491U } else { seed }
  for _ in 0..<length {
    state = state ^ (state << 13)
    state = state ^ (state >> 17)
    state = state ^ (state << 5)
    out.push((state & 0xFFU).to_byte())
  }
  Bytes::from_array(out)
}

///|
fn bench_compress_once(input : Bytes, level : Int) -> Int {
  let options = @lib.CompressionOptions::new(level~)
  @lib.compress_with_options(input, options).length()
}

///|
/// Reports the compression ratio table the README quotes, so those numbers can be
/// regenerated instead of trusted.
test "bench ratio table" {
  for size in [65536, 262144, 1048576] {
    for kind in ["repetitive", "random", "mixed"] {
      let input = bench_payload(kind, size)
      let out = bench_compress_once(input, 6)
      println("ratio kind=\{kind} size=\{size} out=\{out}")
    }
  }
}

///|
/// Compression cost and output size by level on a 64 KiB repetitive payload. This
/// is the table to read when choosing a level.
test "bench compression by level" {
  let bencher = @bench.Bench()
  let input = bench_payload("repetitive", 65536)
  for level in [0, 1, 3, 6, 9] {
    let out = bench_compress_once(input, level)
    println("level=\{level} out=\{out}")
    bencher.bench(name="compress_level\{level}", fn() {
      ignore(bench_compress_once(input, level))
    })
  }
  println(bencher.dump_summaries())
}

///|
/// Throughput at 1 MiB, the size the README quotes.
test "bench throughput" {
  let size = 1048576
  for kind in ["repetitive", "random"] {
    let input = bench_payload(kind, size)
    let options = @lib.CompressionOptions::new(level=6)
    // Warm up so first-touch allocation is not counted.
    ignore(@lib.compress_with_options(input, options))
    let start = @bench.monotonic_clock_start()
    let encoded = @lib.compress_with_options(input, options)
    let us = @bench.monotonic_clock_end(start)
    let dstart = @bench.monotonic_clock_start()
    let decoded = @lib.decompress(encoded) catch { _ => b"" }
    let dus = @bench.monotonic_clock_end(dstart)
    let mib = input.length().to_double() / 1048576.0
    let compress_rate = if us > 0.0 { mib / (us / 1_000_000.0) } else { 0.0 }
    let decompress_rate = if dus > 0.0 {
      mib / (dus / 1_000_000.0)
    } else {
      0.0
    }
    println(
      "throughput kind=\{kind} encoded=\{encoded.length()} decoded_ok=\{decoded.length() == input.length()} compress_us=\{us} decompress_us=\{dus} compress_MiB_s=\{compress_rate} decompress_MiB_s=\{decompress_rate}",
    )
  }
}
