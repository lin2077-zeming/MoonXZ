# MoonXZ

MoonXZ 是 MoonBit 生态中的纯 MoonBit XZ / LZMA / LZMA2 工具包。项目目标是为
MoonBit 补上标准 `.xz` 与旧格式 `.lzma` 的读取、校验和写入能力，并保持运行时
无关、无 FFI、可直接发布到 mooncakes.io。

当前版本是 `0.4.0`。解压端支持标准 XZ 容器、LZMA2 压缩块、`.lzma` 旧格式，
以及 delta 与 x86/ARM/ARM64/SPARC BCJ filter；压缩端具备 LZMA2 range encoder、
hash chain match finder、压缩级别和字典大小参数，并可写出 `.lzma`。默认压缩
级别为 6，字典大小为 8 MiB；级别 0 保留规范的未压缩 LZMA2 块模式。

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
| x86 / ARM / ARM64 / SPARC BCJ filter | 支持 |
| IA64 / ARM-Thumb / PowerPC BCJ filter | 未实现，返回 `Unsupported` |
| 流式 Reader / Writer | 支持 |
| 文件 CLI | 支持 |

## 安装与使用

发布到 mooncakes.io 后可以添加模块：

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
| 0x05 | PowerPC | 未实现，返回 `Unsupported` | — |
| 0x06 | IA64 | 未实现，返回 `Unsupported` | — |
| 0x07 | ARM | 支持 | liblzma 双向 |
| 0x08 | ARM-Thumb | 未实现，返回 `Unsupported` | — |
| 0x09 | SPARC | 支持 | liblzma 双向 |
| 0x0A | ARM64 | 支持 | 仅 MoonXZ 自身绕回 |
| 0x21 | LZMA2 | 支持 | liblzma 双向 |

未实现的 filter 会明确报错，不会静默产出错误字节。

### 关于 ARM64 的验证强度

`liblzma` 没有暴露 ARM64 filter，因此 ARM64 **没有**独立的交叉验证，只有
MoonXZ 自身的编码-解码绕回测试。它的位域处理遵循 xz 规范中 ARM64 BCJ 的定义，
但这一点没有第三方实现可以对照。

x86、ARM、SPARC 和 delta 四个 filter 则是真正双向验证过的：解码方向以
`liblzma` 生成的向量断言，编码方向由 Python `lzma` 解回原文。

### 为什么 ARM-Thumb 和 PowerPC 没有实现

两个 filter 都写过实现，但无法与 `liblzma` 对齐：`liblzma` 对这两个 filter 的
字节变换与 xz-embedded 参考实现给出的描述不一致，实测下来只有部分候选字会被
filter 命中，无法归纳出一条可依赖的规则。BCJ 位域算错的后果是解码结果静默变成
错误字节，而 block check 只能发现不一致、无法区分"正确"与"看起来正确"。

因此选择明确返回 `Unsupported`。这比交付一个未经验证的近似实现更安全，也让
支持边界可测试。它们的实现路线记录在 `docs/DESIGN.md`。

## CLI

```text
moon run cmd/main -- demo
moon run cmd/main -- compress <hex> [none|crc32|crc64|sha256]
moon run cmd/main -- decompress <hex>
moon run cmd/main -- roundtrip <hex>
moon run cmd/main -- lzma-decompress <hex>
moon run cmd/main -- lzma-roundtrip <hex>
moon run cmd/main -- compress-file <input> <output> [check] [none|x86|arm|arm64|sparc|delta]
moon run cmd/main -- decompress-file <input> <output>
moon run cmd/main -- lzma-compress-file <input> <output>
moon run cmd/main -- lzma-decompress-file <input> <output>
```

十六进制命令保留了轻量测试入口，文件命令通过 `moonbitlang/x/fs` 读写
本地文件。库包本身仍然不依赖文件系统。

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
- 重复数据和不可压缩数据的自动回退
- delta filter 和 x86 / ARM / ARM64 / SPARC BCJ filter 的标准向量
- 未实现 BCJ filter 明确返回 `Unsupported`
- `.lzma` 两种头形式的解码、编码绕回与损坏头部拒绝
- 逐字节截断：任何前缀都不得解出原始数据
- 单字节全量变异：任何变异都不得 panic，也不得静默产出与原文不同的数据
- 伪随机垃圾输入：与变异测试互补，覆盖完全没有合法结构的输入
- 声明膨胀：头部声明超大输出时必须在输出限制处失败
- 流式 Writer/Reader 的多 block 读写
- 文件 CLI 压缩、解压和内容一致性
- Python `lzma` 生成的压缩 XZ 测试向量
- 输出大小限制错误

`scripts/interop.py` 还可以调用 CLI 做额外的 Python `lzma` 双向互操作检查，
覆盖 XZ 四类 check、x86/ARM/SPARC/delta 四个 filter 以及 `.lzma` 的两种头形式。

这些向量由 Python 3.14 的 `liblzma`（`xz-utils` 使用的同一份 C 实现）现场生成，
用于交叉验证 MoonXZ 的解码结果；`scripts/interop.py` 同时验证反方向，即
Python `lzma` 能正确解压 MoonXZ 写出的数据。ARM64 没有这样的对照实现，因此只
有自带绕回测试，具体见上方"关于 ARM64 的验证强度"。

## 项目结构

```text
moon.mod                 模块元数据
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
lib/filters.mbt          Delta 与 x86/ARM/ARM64/SPARC BCJ filter
lib/streaming.mbt        流式 Reader / Writer
lib/check.mbt            CRC32 / CRC64 / SHA-256
lib/util.mbt             字节游标、VLI 和序列化辅助
cmd/main/                可运行 CLI
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
类型系统、错误处理和内存模型适配。x86、ARM、SPARC 与 delta 的输出以 Python
`liblzma` 生成的向量做交叉验证；ARM64 只有自带绕回验证。参考项目的
BSD-3-Clause 许可证和归属信息见 `THIRD_PARTY_NOTICES.md`。

文件 CLI 使用 `moonbitlang/x/fs`，该依赖及其 Apache-2.0 许可证信息也记录在
`THIRD_PARTY_NOTICES.md`。

本项目采用 Apache-2.0 许可证。
