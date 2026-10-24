///|
fn usage() -> Unit {
  println("MoonXZ conformance")
  println("usage:")
  println("  moonxz-conformance smoke")
  println("  moonxz-conformance run [manifest] [report]")
}

///|
fn print_report(report : @conformance.Report) -> Unit {
  for result in report.results {
    println(
      "\{result.status} \{result.case_id} [\{result.implementation}] \{result.detail}",
    )
  }
  println(
    "summary: total=\{report.summary.total} passed=\{report.summary.passed} failed=\{report.summary.failed} skipped=\{report.summary.skipped}",
  )
}

///|
fn main {
  let args = @env.args()
  if args.length() < 2 {
    usage()
    return
  }
  try {
    match args[1] {
      "smoke" =>
        if @conformance.smoke() {
          println("MoonXZ conformance: smoke ok")
        } else {
          println("MoonXZ conformance: smoke failed")
          @sys.exit(1)
        }
      "run" => {
        let manifest = if args.length() > 2 {
          args[2]
        } else {
          "corpus/manifest.json"
        }
        let output = if args.length() > 3 {
          args[3]
        } else {
          "_build/conformance-report.json"
        }
        let report = @conformance.run_manifest(manifest)
        @conformance.write_report(output, report)
        print_report(report)
        println("report: \{output}")
        if report.summary.failed > 0 {
          @sys.exit(1)
        }
      }
      _ => usage()
    }
  } catch {
    error => {
      println("error: \{@debug.to_string(error)}")
      @sys.exit(2)
    }
  }
}
