///|
fn arm64_payload() -> Bytes raise {
  let bl = @hex.decode(
    "00000094cdab00949a5701946703029434af0294015b0394ce0604949bb20494685e0594350a069402",
  )
  let adrp = @hex.decode(
    "00000090812800b0025100d0837900f024a20090a5ca00b026f300d0a71b01f048440190c96c01b04a9501d0cbbd01f0",
  )
  Bytes::repeat(bl, 8) + Bytes::repeat(adrp, 4) + b"\x94"
}

///|
fn main raise {
  let args = @env.args()
  if args.length() != 3 {
    raise Failure::Failure("usage: gen_arm64 <payload-out> <xz-out>")
  }
  let payload = arm64_payload()
  let encoded = @xz.encode_xz(
    payload,
    3,
    0,
    2,
    65536U,
    check_id=4,
    bcj_arm64=true,
  )
  @fs.write_bytes_to_file(args[1], payload)
  @fs.write_bytes_to_file(args[2], encoded)
  println("arm64 fixture: payload=\{payload.length()} xz=\{encoded.length()}")
}
