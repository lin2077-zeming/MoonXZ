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

///|
/// Re-export the derived `Debug` method as an ordinary method.
///
/// The compiler used to promote methods from a derived `impl` automatically; that
/// promotion is deprecated and warns unless it is requested explicitly. Stating it
/// keeps `error.to_repr()` and `@debug.to_string(error)` working for callers.
pub extend XzError with @debug.Debug::{to_repr}
