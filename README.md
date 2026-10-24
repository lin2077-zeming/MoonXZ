# MoonXZ

MoonXZ 由两个部分组成：纯 MoonBit 的 XZ / LZMA / LZMA2 实现，以及一个面向
MoonBit 生态的 XZ 一致性与差分验证工具。前者保持运行时无关、无 FFI，可直接发布
到 mooncakes.io；后者用同一组 fixture 同时运行 MoonXZ 与
`aurora0x27/lzma-mbt`，把“支持什么、拒绝什么、与另一个实现是否一致”变成可执行
报告。

仓库当前版本是 `0.4.6`。解压端支持标准 XZ 容器、LZMA2 压缩块、`.lzma` 旧格式，
以及 delta 与 x86 BCJ filter；压缩端具备 LZMA2 range encoder、hash chain match
finder、压缩级别和字典大小参数，并可写出 `.lzma`。默认压缩级别为 6，字典大小为
8 MiB；级别 0 保留规范的未压缩 LZMA2 块模式。

> **发布说明。**
>
> - `0.4.2` 及更早版本**有解码缺陷**：解析 LZMA2 未压缩长度字段时存在进位错误，
>   128 KiB / 256 KiB / 1 MiB 等常见体积的合法 Python / `xz-utils` 输出会解码
>   失败；同一批版本的长度校验还存在整数溢出。请勿用它们解压外部产生的 XZ 文件
> - `0.4.3` 修复上述缺陷；`0.4.4` 只同步了 `moonc 0.10.15` 的格式与发布源码
> - `0.4.1` 及更早版本还会在新工具链上因 `implicit_impl_as_method` 构建失败
> - `0.4.5` 修复外部 XZ 流的逐字节流式解码误报，并加入一致性验证模块
> - `0.4.6` 适配 `moonc 0.10.17` 的公开接口格式，行为与 0.4.5 相同
>
> 构建要求 `moonc` 0.10.14 或更高；当前源码已在 `moonc v0.10.17+d971670cd` 上
> 完整验证（`check --deny-warn`、四个后端的 `test --deny-warn`、`fmt --check`、
> `bundle --all`、CLI 示例、一致性语料、基准与互操作脚本）。详见
> `CHANGELOG.md` 和 `docs/compatibility.md`。

## 功能状态

| 功能 | 状态 |
| --- | --- |
| XZ stream header / footer / index 解析 | 支持 |
| 单 block 和多 block XZ stream | 支持 |
| 拼接 XZ stream 和 stream padding | 支持 |
| LZMA2 压缩块解码 | 支持 |
| LZMA2 未压缩块解码 | 支持 |
| LZMA2 range encoder 和压缩编码 | 支持 |
| Hash chain match finder | 支持 |
| 压缩级别 0-9 和字典大小参数 | 支持 |
| LZMA2 未压缩块编码和自动回退 | 支持 |
| `.lzma` LZMA1 旧格式解码 | 支持 |
| `.lzma` LZMA1 旧格式编码 | 支持 |
| CRC32 / CRC64 / SHA-256 block check | 支持 |
| 输出大小限制和错误分类 | 支持 |
| Delta filter | 支持 |
| x86 BCJ filter | 支持 |
| PowerPC / IA64 / ARM / ARM-Thumb / SPARC / ARM64 BCJ filter | 未实现，返回 `Unsupported` |
| 流式 Reader / Writer | 支持 |
| 有界窗口流式解码（`XzStreamDecoder`） | 支持 |
| 文件 CLI | 支持 |
| 一致性 / 差分验证工具（`tools/conformance`） | 支持 |

## 安装与使用

添加已发布模块（mooncakes 当前最新版本为 `0.4.6`）：

```text
moon add lin2077-zeming/moonxz
```

在 `moon.pkg` 中导入库包并使用别名：

```text
import {
  "lin2077-zeming/moonxz/lib" @moonxz,
}
```

一次性 API：

```moonbit
fn example() -> Unit raise {
  let input = b"MoonXZ quick start\n"
  let encoded = @moonxz.compress(input)
  let decoded = @moonxz.decompress(encoded)
  println(decoded == input)
}
```

### 最小可复现示例

仓库自带的示例就是 CLI，可以从零复现。在仓库根目录依次执行：

```text
moon run cmd/main -- demo
```

预期输出（`xz_bytes` 与 `percent` 会随数据变化，`roundtrip` 必须为 `true`）：

```text
input_bytes=7400 xz_bytes=156 percent=2
roundtrip=true
xz_hex=fd377a585a000004e6d6b44602...
```

CLI 之外还可以用一个独立工程验证发布产物确实可用：新建任意 MoonBit 工程，
`moon add lin2077-zeming/moonxz`，导入 `lin2077-zeming/moonxz/lib`，然后调用
`@moonxz.compress` / `@moonxz.decompress`。`scripts/interop.py` 会自动完成这一
验证，并额外检查 Python `lzma` 与本库的双向互通。

指定校验类型：

```moonbit
let encoded = @moonxz.compress_with_check(input, @moonxz.CheckKind::Sha256)
```

指定压缩级别、字典大小和 filter：

```moonbit
let options = @moonxz.CompressionOptions::new(
  level=9,
  dict_size=8 * 1024 * 1024,
  filter=@moonxz.FilterMode::X86,
)
let encoded = @moonxz.compress_with_options(input, options)
```

流式写入和读取：

```moonbit
let writer = @moonxz.XzWriter::new()
let first = writer.write(b"first block")
let second = writer.write(b"second block")
let tail = writer.finish()

let reader = @moonxz.XzReader::new(first + second + tail)
let block = reader.read_block()
```

限制解压输出大小，避免恶意输入造成内存膨胀：

```moonbit
let decoded = @moonxz.decompress_with_limit(encoded, 16 * 1024 * 1024)
```

读写旧格式 `.lzma`：

```moonbit
// 解压由 xz --format=lzma 或 Python lzma.compress(data, format=lzma.FORMAT_ALONE) 生成的文件
let decoded = @moonxz.decompress_lzma1(legacy)

// 写出 .lzma
let encoded = @moonxz.compress_lzma1(input)

// 读取头部信息，便于诊断
let (lc, lp, pb) = @moonxz.lzma1_properties(legacy)
let declared = @moonxz.lzma1_declared_size(legacy)
```

`.lzma` 头部的 `0xFFFFFFFFFFFFFFFF` 大小字段表示"未知大小"，此时解码器依赖流
末尾的结束标记。两种形式都被接受。

## BCJ filter 支持范围

| filter id | 名称 | 状态 | 验证方式 |
| --- | --- | --- | --- |
| 0x03 | delta | 支持 | liblzma 双向 |
| 0x04 | x86 | 支持 | liblzma 双向 |
| 0x05 | PowerPC | 当前版本返回 `Unsupported` | 一致性工具保留扩展位 |
| 0x06 | IA64 | 当前版本返回 `Unsupported` | 一致性工具保留扩展位 |
| 0x07 | ARM | 当前版本返回 `Unsupported` | `xz-arm` 与 `lzma-mbt` 差分 |
| 0x08 | ARM-Thumb | 当前版本返回 `Unsupported` | 一致性工具保留扩展位 |
| 0x09 | SPARC | 当前版本返回 `Unsupported` | 一致性工具保留扩展位 |
| 0x0A | ARM64 | 当前版本返回 `Unsupported` | `xz-arm64`，官方 xz 5.8.3 校验 fixture |
| 0x21 | LZMA2 | 支持 | liblzma 双向 |

未实现的 filter 会明确报错，不会静默产出错误字节。

### 当前版本边界与补齐计划

delta、x86 是仅有的两个"长度 × 内容形态"全矩阵通过、且与 `liblzma` 双向互通的
filter：MoonXZ 写出的流 liblzma 能解，liblzma 写出的流 MoonXZ 也能解。

其余 BCJ filter 都写过实现，也都通过过最初的向量测试，但在补齐"多长度 × 多内容
形态"的矩阵后发现它们会静默损坏数据：

- **ARM、SPARC**：在特定字上地址运算溢出，编码后再解码无法还原原文，liblzma
  也会拒绝 MoonXZ 写出的流（`Corrupt input data`）
- **ARM64**：早先实现存在同类溢出；现在可由官方 `xz 5.8.3` 与 `lzma-mbt` 提供
  可执行对照，因此补齐路径已经明确
- **ARM-Thumb、PowerPC、IA64**：无法归纳出与 `liblzma` 一致的字节变换规则

BCJ 位域算错的后果是解码结果静默变成错误字节，block check 只能发现不一致、无法
区分"正确"与"看起来正确"。当前版本因此明确返回 `Unsupported`，而不是交付一个
"大多数情况下正确"的实现；后续版本会在同一套一致性语料上补齐并验收，而不是把
这些标准 filter 排除在项目目标之外。具体现象记录在 `docs/DESIGN.md`。

## 一致性与差分验证

`tools/conformance` 是一个独立的 MoonBit 模块，不进入库的公共依赖。它读取
`corpus/manifest.json`，校验每个 fixture 的 SHA-256，然后把同一用例分别交给
MoonXZ 与 `lzma-mbt`，输出逐项 JSON 报告：

```text
moon run tools/conformance/cmd/main -- run tools/conformance/corpus/manifest.json _build/conformance-report.json
```

当前语料覆盖 XZ / `.lzma`、四类 check、Delta / x86、六个未实现 BCJ 的拒绝路径、
ARM64 互操作、拼接流与 padding、128 KiB LZMA2 边界、1 字节分块解码、截断、损坏
校验和输出上限。ARM64 fixture 由
MoonBit 的 `lzma-mbt` 编码，再由官方 `xz 5.8.3` 独立解码确认，避免同源自证。

兼容矩阵、规范版本和每个支持结论对应的用例见 `docs/compatibility.md`；语料生成与
调用方法见 `tools/conformance/README.md`。当前一次完整运行的机器可读结果保存在
`docs/conformance-report.json`。

## CLI

```text
moon run cmd/main -- demo
moon run cmd/main -- compress <hex> [none|crc32|crc64|sha256]
moon run cmd/main -- decompress <hex>
moon run cmd/main -- roundtrip <hex>
moon run cmd/main -- lzma-decompress <hex>
moon run cmd/main -- lzma-roundtrip <hex>
moon run cmd/main -- compress-file <input> <output> [check] [none|x86|delta]
moon run cmd/main -- decompress-file <input> <output>
moon run cmd/main -- lzma-compress-file <input> <output>
moon run cmd/main -- lzma-decompress-file <input> <output>
```

十六进制命令保留了轻量测试入口，文件命令通过 `moonbitlang/x/fs` 读写
本地文件。库包本身仍然不依赖文件系统。

### 性能

基准测试在 `lib/moonxz_bench_test.mbt`，直接运行即可打印表格：

```text
moon test --release --target native
```

native、level 6、1 MiB 输入的参考数据（同一台机器上与 Python `liblzma` 对比）：

| 内容 | MoonXZ 输出 | liblzma 输出 | 压缩速度 | 解压速度 |
| --- | --- | --- | --- | --- |
| 重复文本 | 1752 B | 328 B | 约 68 MiB/s | 约 54 MiB/s |
| 半重复 | 525196 B | 525416 B | — | — |
| 随机 | 1048688 B | 1048688 B | 约 3.2 MiB/s | 约 35 MiB/s |

两点值得注意：

- **压缩速度强烈依赖数据的可压缩性。** 重复数据约 68 MiB/s，而随机数据只有
  约 3.2 MiB/s。随机数据每次匹配搜索都要走完整条哈希链才会放弃，因此慢得多。
  解压速度则稳定在 35–54 MiB/s。
- **半重复与随机数据的输出与 `liblzma` 基本持平**；重复数据仍有约 5 倍差距，
  原因是 LZMA2 压缩块的未压缩上限当前保守地停在 64 KiB，限制了可用匹配距离。
  提高该上限可以把它降到约 1.3 倍，但会让编码器写出的块超出本库解码器目前能
  正确处理的形状，因此暂未启用；实测数据与入手点记录在 `docs/DESIGN.md`。

## 流式解码与内存占用

`XzStreamDecoder` 面向输入分块到达、且不想把整条流放进内存的场景：

```text
let decoder = @moonxz.XzStreamDecoder::new()
// 每次拿到一段压缩数据就喂进去，然后尽量取出已解出的块
decoder.supply(chunk)
loop decoder.next() {
  Some(block) => handle(block)
  None => break          // 需要更多输入，除非已经调用 finish_input
}
// 输入结束时调用，之后 next 返回 None 即为流被截断
decoder.finish_input()
```

`next` 返回 `None` 表示"当前缓冲里还没有完整的单元"；调用 `finish_input` 之后
同一个 `None` 表示输入提前结束。已解码块占用的字节会被丢弃，所以常驻的只是
待处理输入加上单个块，而不是整条流。逐字节喂入也是支持的（含拼接流与 stream
padding），测试里就是这么验证的。

**边界说明**：`moonbitlang/x/fs` 只提供整文件读写，没有追加或流式写入接口，
因此文件 CLI 仍需要把压缩输入与解码输出各持有一份；流式解码器本身不依赖任何
运行时或 I/O，它解决的是库侧的窗口问题，不是 CLI 侧的文件缓冲问题。

## 验证

项目自带以下验证命令：

```text
moon check --deny-warn
moon test --deny-warn
moon fmt --check
moon test --target all --deny-warn
```

测试覆盖：

- CRC32 和 SHA-256 已知向量
- 空输入和普通输入 roundtrip
- None / CRC32 / CRC64 / SHA-256 四种 block check
- 多 LZMA2 chunk、压缩级别和字典大小组合，含 65536 字节 chunk 边界两侧
- liblzma 生成的 128 KiB / 256 KiB / 1 MiB 单块 fixture（控制字节 `0xE1` /
  `0xE3` / `0xEF`），覆盖 18 位未压缩长度字段的进位路径
- 重复数据和不可压缩数据的自动回退
- delta 和 x86 BCJ filter 的标准向量（liblzma 生成）
- 未实现 BCJ filter 明确返回 `Unsupported`
- `.lzma` 两种头形式的解码、编码绕回与损坏头部拒绝，含空输入的编码
- 超长声明长度字段必须被拒绝且不得 panic
- 逐字节截断：任何前缀都不得解出原始数据
- 单字节全量变异：任何变异都不得 panic，也不得静默产出与原文不同的数据
- 伪随机垃圾输入：与变异测试互补，覆盖完全没有合法结构的输入
- 声明膨胀：头部声明超大输出时必须在输出限制处失败
- 流式 Writer/Reader 的多 block 读写
- 流式 `XzStreamDecoder` 逐字节喂入与一次性解码逐字节一致，含拼接流与 padding；
  另覆盖外部 XZ 流省略 Block 压缩大小时的逐字节输入、截断检测与输出上限
- 文件 CLI 压缩、解压和内容一致性
- Python `lzma` 生成的压缩 XZ 测试向量
- 输出大小限制错误

`scripts/interop.py` 还可以调用 CLI 做额外的 Python `lzma` 双向互操作检查，
覆盖 XZ 四类 check、x86/delta 两个 filter、`.lzma` 的两种头形式，并断言
ARM、ARM-Thumb、PowerPC、SPARC、IA64 返回 `Unsupported`；ARM64 由一致性语料和
官方 xz 5.8.3 覆盖。

这些向量由 Python 3.14 的 `liblzma`（`xz-utils` 使用的同一份 C 实现）现场生成，
用于交叉验证 MoonXZ 的解码结果；`scripts/interop.py` 同时验证反方向，即
Python `lzma` 能正确解压 MoonXZ 写出的数据。

`tools/conformance` 提供更强的实现级差分检查：同一 fixture 同时运行 MoonXZ 与
`aurora0x27/lzma-mbt`，校验来源哈希并输出 JSON 报告。当前语料 24 个场景、48 个
实现级检查；运行方式与证据说明见 `tools/conformance/README.md` 和
`docs/compatibility.md`。

### 验收级自查

除单元测试外，仓库带一个**验收级自查脚本**，检查"文档声称的"与"代码实际做的"
是否一致——这类落差单元测试查不到：

```text
python scripts/self_audit.py .
```

它核对版本号与测试数量在各文档间是否一致、文档点名的 API 是否真实存在、
"不做"声明是否已被代码推翻、外部 liblzma 的边界尺寸能否精确解码、空输入能否
往返、畸形输入是否会 panic。输出 `PASS` / `FAIL` / `UNVERIFIED` 三种状态，
**`UNVERIFIED` 不算通过**。

这个方法的通用版本（项目无关、含可配置的审计脚本）已抽成独立 skill：
`docs/skills/moonbit-acceptance-review/`，可供其他 MoonBit 项目参考。
设计动机与失败案例复盘见 `docs/ACCEPTANCE_REVIEW_ANALYSIS.md`。

## 项目结构

```text
moon.mod                 模块元数据
moon.work                workspace：根库 + 一致性工具
lib/moon.pkg             库包配置
lib/moonxz.mbt           公共 API
lib/xz.mbt               XZ 容器解析和写入
lib/lzma1.mbt            .lzma 旧格式头部、解码和编码
lib/lzma2.mbt            LZMA2 chunk 解析
lib/lzma_decoder.mbt     LZMA 概率模型和状态机
lib/range_decoder.mbt    LZMA range decoder
lib/range_encoder.mbt    LZMA range encoder
lib/lzma_encoder.mbt     LZMA 编码状态机
lib/lzma2_encoder.mbt    LZMA2 压缩块编码和回退
lib/match_finder.mbt     Hash chain match finder
lib/filters.mbt          Delta 与 x86 BCJ filter
lib/streaming.mbt        流式 Reader / Writer 与有界窗口解码器
lib/check.mbt            CRC32 / CRC64 / SHA-256
lib/util.mbt             字节游标、VLI 和序列化辅助
cmd/main/                可运行 CLI
tools/conformance/       独立的一致性 / 差分验证模块
docs/compatibility.md     规范版本、支持矩阵和证据索引
docs/DESIGN.md           实现设计说明
```

## 互操作示例

下面验证 MoonXZ 写出的数据能被 Python 标准库解压：

```powershell
$xz = (moon run -q cmd/main -- compress 6869 sha256).Trim()
python -c "import lzma,sys; print(lzma.decompress(bytes.fromhex(sys.argv[1])))" $xz
```

输出应为：

```text
b'hi'
```

反向验证由测试中的 `decode Python lzma fixture` 等用例完成，覆盖 XZ 与
`.lzma` 两种格式以及各 BCJ filter。

## 开源与来源说明

MoonXZ 的 XZ 容器行为、LZMA 解码算法和 BCJ filter 语义参考了 XZ file format
specification 以及 `github.com/ulikunitz/xz` 的纯 Go 实现，并进行了 MoonBit
类型系统、错误处理和内存模型适配。x86 与 delta 的输出以 Python liblzma 生成的
向量做双向交叉验证。参考项目的
BSD-3-Clause 许可证和归属信息见 `THIRD_PARTY_NOTICES.md`。

文件 CLI 使用 `moonbitlang/x/fs`，该依赖及其 Apache-2.0 许可证信息也记录在
`THIRD_PARTY_NOTICES.md`。

本项目采用 Apache-2.0 许可证。
