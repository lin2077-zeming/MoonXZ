///|
/// Errors raised while reading or writing XZ data.
pub(all) suberror XzError {
  InvalidHeader(String)
  Truncated(String)
  Unsupported(String)
  Corrupt(String)
  ChecksumMismatch(String)
  OutputLimitExceeded(Int)
} derive(@debug.Debug)
