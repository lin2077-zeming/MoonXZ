///|
fn join_path(root : String, relative : String) -> String {
  if root == "" || root == "." {
    relative
  } else {
    "\{root}/\{relative}"
  }
}

///|
fn dirname(path : String) -> String {
  let separator = match path.rev_find("/") {
    Some(index) => Some(index)
    None => path.rev_find("\\")
  }
  match separator {
    Some(index) => path[:index].to_owned()
    None => "."
  }
}

///|
fn read_bytes(path : String) -> Bytes raise ConformanceError {
  @fs.read_file_to_bytes(path) catch {
    error =>
      raise ConformanceError("cannot read \{path}: \{@debug.to_string(error)}")
  }
}

///|
fn read_text(path : String) -> String raise ConformanceError {
  @fs.read_file_to_string(path) catch {
    error =>
      raise ConformanceError("cannot read \{path}: \{@debug.to_string(error)}")
  }
}

///|
fn fixture_hash(data : Bytes) -> String {
  @hex.encode(@moonxz.sha256(data))
}

///|
pub fn load_manifest(path : String) -> Manifest raise ConformanceError {
  let text = read_text(path)
  let json = @json.parse(text) catch {
    error => raise ConformanceError("invalid manifest JSON: \{error}")
  }
  @json.from_json(json) catch {
    error => raise ConformanceError("invalid manifest schema: \{error}")
  }
}

///|
fn expected_name(spec : CaseSpec, implementation : String) -> String {
  let configured = match implementation {
    "moonxz" => spec.moonxz_expect
    "lzma-mbt" => spec.lzma_mbt_expect
    _ => None
  }
  match configured {
    Some(value) => value
    None => "exact"
  }
}

///|
fn outcome_matches(outcome : AdapterOutcome, expectation : String) -> Bool {
  match expectation {
    "exact" => outcome.status == "ok"
    "unsupported" => outcome.status == "unsupported"
    "output_limit" => outcome.status == "output_limit"
    "error" => outcome.status != "ok"
    "skip" => true
    _ => false
  }
}

///|
fn result_for(
  spec : CaseSpec,
  implementation : String,
  outcome : AdapterOutcome,
  expected : Bytes?,
) -> CaseResult {
  let expectation = expected_name(spec, implementation)
  if expectation == "skip" {
    return {
      case_id: spec.id,
      implementation,
      status: "skip",
      detail: "not applicable",
      output_bytes: 0,
    }
  }
  let bytes = match outcome.output {
    Some(value) => value.length()
    None => 0
  }
  if !outcome_matches(outcome, expectation) {
    return {
      case_id: spec.id,
      implementation,
      status: "fail",
      detail: "expected \{expectation}, got \{outcome.status} \{outcome.detail}",
      output_bytes: bytes,
    }
  }
  if expectation == "exact" {
    let output = match outcome.output {
      Some(value) => value
      None => b""
    }
    match expected {
      Some(want) =>
        if output != want {
          return {
            case_id: spec.id,
            implementation,
            status: "fail",
            detail: "output differs: got \{output.length()} bytes, expected \{want.length()}",
            output_bytes: bytes,
          }
        }
      None => ()
    }
  }
  {
    case_id: spec.id,
    implementation,
    status: "pass",
    detail: expectation,
    output_bytes: bytes,
  }
}

///|
fn run_decode_case(
  spec : CaseSpec,
  input : Bytes,
  expected : Bytes?,
) -> Array[CaseResult] {
  let format = match spec.format {
    Some(value) => value
    None => "xz"
  }
  let max_output = spec.max_output
  let concatenated = match spec.concatenated {
    Some(value) => value
    None => false
  }
  let chunk = match spec.stream_chunk {
    Some(value) => value
    None => 1
  }
  let specs = [
    (
      "moonxz",
      if spec.operation == "stream_decode" {
        moonxz_stream_decode(input, chunk)
      } else {
        moonxz_decode(input, format, max_output)
      },
    ),
    (
      "lzma-mbt",
      if spec.operation == "stream_decode" {
        lzma_mbt_stream_decode(input, chunk)
      } else {
        lzma_mbt_decode(input, format, concatenated)
      },
    ),
  ]
  let results = []
  for entry in specs {
    let (implementation, outcome) = entry
    results.push(result_for(spec, implementation, outcome, expected))
  }
  results
}

///|
fn run_roundtrip_case(spec : CaseSpec, input : Bytes) -> Array[CaseResult] {
  let check = match spec.check {
    Some(value) => value
    None => "crc64"
  }
  let results = []
  let moon_encoded = moonxz_encode(input, check)
  match moon_encoded.output {
    Some(encoded) => {
      let decoded = lzma_mbt_decode(encoded, "xz", false)
      results.push({
        case_id: spec.id,
        implementation: "moonxz->lzma-mbt",
        status: if decoded.output == Some(input) {
          "pass"
        } else {
          "fail"
        },
        detail: if decoded.status == "ok" {
          "cross-decoded"
        } else {
          decoded.detail
        },
        output_bytes: match decoded.output {
          Some(value) => value.length()
          None => 0
        },
      })
    }
    None =>
      results.push({
        case_id: spec.id,
        implementation: "moonxz->lzma-mbt",
        status: "fail",
        detail: "MoonXZ encode failed: \{moon_encoded.detail}",
        output_bytes: 0,
      })
  }
  let other_encoded = lzma_mbt_encode(input, check)
  match other_encoded.output {
    Some(encoded) => {
      let decoded = moonxz_decode(encoded, "xz", None)
      results.push({
        case_id: spec.id,
        implementation: "lzma-mbt->moonxz",
        status: if decoded.output == Some(input) {
          "pass"
        } else {
          "fail"
        },
        detail: if decoded.status == "ok" {
          "cross-decoded"
        } else {
          decoded.detail
        },
        output_bytes: match decoded.output {
          Some(value) => value.length()
          None => 0
        },
      })
    }
    None =>
      results.push({
        case_id: spec.id,
        implementation: "lzma-mbt->moonxz",
        status: "fail",
        detail: "lzma-mbt encode failed: \{other_encoded.detail}",
        output_bytes: 0,
      })
  }
  results
}

///|
fn verify_hash(
  spec : CaseSpec,
  kind : String,
  actual : String,
  expected : String,
) -> Unit raise ConformanceError {
  if actual != expected {
    raise ConformanceError(
      "\{spec.id}/\{kind} sha256 mismatch: got \{actual}, expected \{expected}",
    )
  }
}

///|
pub fn run_manifest(path : String) -> Report raise ConformanceError {
  let manifest = load_manifest(path)
  let root = dirname(path)
  let results : Array[CaseResult] = []
  for spec in manifest.cases {
    let input_path = join_path(root, spec.input)
    let input = read_bytes(input_path)
    verify_hash(spec, "input", fixture_hash(input), spec.input_sha256)
    let expected = match spec.expected {
      Some(relative) => {
        let data = read_bytes(join_path(root, relative))
        let expected_hash = match spec.expected_sha256 {
          Some(value) => value
          None =>
            raise ConformanceError("\{spec.id}: expected_sha256 is required")
        }
        verify_hash(spec, "expected", fixture_hash(data), expected_hash)
        Some(data)
      }
      None => None
    }
    let case_results = match spec.operation {
      "roundtrip" => run_roundtrip_case(spec, input)
      "decode" | "stream_decode" => run_decode_case(spec, input, expected)
      operation =>
        raise ConformanceError("\{spec.id}: unknown operation \{operation}")
    }
    for result in case_results {
      results.push(result)
    }
  }
  let passed = results
    .iter()
    .filter(fn(result) { result.status == "pass" })
    .count()
  let failed = results
    .iter()
    .filter(fn(result) { result.status == "fail" })
    .count()
  let skipped = results
    .iter()
    .filter(fn(result) { result.status == "skip" })
    .count()
  {
    schema_version: 1,
    corpus_version: manifest.corpus_version,
    generated_by: "MoonXZ conformance",
    summary: { total: results.length(), passed, failed, skipped, },
    results,
  }
}

///|
pub fn report_json(report : Report) -> String {
  @json.to_json(report).stringify(indent=2)
}

///|
pub fn write_report(
  path : String,
  report : Report,
) -> Unit raise ConformanceError {
  let parent = dirname(path)
  if parent != "." && !@fs.path_exists(parent) {
    @fs.create_dir(parent) catch {
      error =>
        raise ConformanceError(
          "cannot create report directory \{parent}: \{@debug.to_string(error)}",
        )
    }
  }
  @fs.write_string_to_file(path, report_json(report) + "\n") catch {
    error =>
      raise ConformanceError(
        "cannot write report \{path}: \{@debug.to_string(error)}",
      )
  }
}
