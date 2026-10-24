///|
pub(all) suberror ConformanceError {
  ConformanceError(String)
} derive(@debug.Debug)

///|
pub extend ConformanceError with @debug.Debug::{to_repr}

///|
pub(all) struct Manifest {
  schema_version : Int32
  corpus_version : String
  generated_by : String
  cases : Array[CaseSpec]
} derive(@json.FromJson, @json.ToJson)

///|
pub extend Manifest with @json.FromJson::{from_json}

///|
pub extend Manifest with @json.ToJson::{to_json}

///|
pub(all) struct CaseSpec {
  id : String
  description : String
  operation : String
  input : String
  input_sha256 : String
  expected : String?
  expected_sha256 : String?
  format : String?
  check : String?
  stream_chunk : Int32?
  max_output : Int32?
  concatenated : Bool?
  moonxz_expect : String?
  lzma_mbt_expect : String?
  source : String
} derive(@json.FromJson, @json.ToJson)

///|
pub extend CaseSpec with @json.FromJson::{from_json}

///|
pub extend CaseSpec with @json.ToJson::{to_json}

///|
pub(all) struct CaseResult {
  case_id : String
  implementation : String
  status : String
  detail : String
  output_bytes : Int32
} derive(@json.FromJson, @json.ToJson)

///|
pub extend CaseResult with @json.FromJson::{from_json}

///|
pub extend CaseResult with @json.ToJson::{to_json}

///|
pub(all) struct ReportSummary {
  total : Int32
  passed : Int32
  failed : Int32
  skipped : Int32
} derive(@json.FromJson, @json.ToJson)

///|
pub extend ReportSummary with @json.FromJson::{from_json}

///|
pub extend ReportSummary with @json.ToJson::{to_json}

///|
pub(all) struct Report {
  schema_version : Int32
  corpus_version : String
  generated_by : String
  summary : ReportSummary
  results : Array[CaseResult]
} derive(@json.FromJson, @json.ToJson)

///|
pub extend Report with @json.FromJson::{from_json}

///|
pub extend Report with @json.ToJson::{to_json}

///|
priv struct AdapterOutcome {
  status : String
  output : Bytes?
  detail : String
}
