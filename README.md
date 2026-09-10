# MoonXZ

MoonXZ 是 MoonBit 生态中的纯 MoonBit XZ / LZMA2 工具包。项目目标是为
MoonBit 补上标准 `.xz` 格式的读取、校验和写入能力，并保持运行时无关、无
FFI、可直接发布到 mooncakes.io。

当前版本是 `0.2.0`。解压端支持标准 XZ 容器和 LZMA2 压缩块；压缩端已经
加入 LZMA2 range encoder、hash chain match finder、压缩级别和字典大小
参数。默认压缩级别为 6，字典大小为 8 MiB；级别 0 保留规范的未压缩
LZMA2 块模式。

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
| CRC32 / CRC64 / SHA-256 block check | 支持 |
| 输出大小限制和错误分类 | 支持 |
| Delta / BCJ / 多 filter chain | 暂不支持 |
| LZMA1 `.lzma` 旧格式 | 暂不支持 |

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

指定压缩级别和字典大小：

```moonbit
let options = @moonxz.CompressionOptions::new(level=9, dict_size=8 * 1024 * 1024)
let encoded = @moonxz.compress_with_options(input, options)
```

限制解压输出大小，避免恶意输入造成内存膨胀：

```moonbit
let decoded = @moonxz.decompress_with_limit(encoded, 16 * 1024 * 1024)
```

## CLI

```text
moon run cmd/main -- demo
moon run cmd/main -- compress <hex> [none|crc32|crc64|sha256]
moon run cmd/main -- decompress <hex>
moon run cmd/main -- roundtrip <hex>
```

CLI 使用十六进制作为输入和输出，避免当前初版引入额外的平台文件 IO 依赖。
库 API 直接使用 `Bytes`，后续会在 `0.2.0` 增加文件模式。

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
- 多 LZMA2 chunk、压缩级别和字典大小组合
- 重复数据和不可压缩数据的自动回退
- Python `lzma` 生成的压缩 XZ 测试向量
- 输出大小限制错误

`scripts/interop.py` 还可以调用 CLI 做额外的 Python `lzma` 双向互操作检查。

## 项目结构

```text
moon.mod                 模块元数据
lib/moon.pkg             库包配置
lib/moonxz.mbt           公共 API
lib/xz.mbt               XZ 容器解析和存储式写入
lib/lzma2.mbt            LZMA2 chunk 解析
lib/lzma_decoder.mbt     LZMA 概率模型和状态机
lib/range_decoder.mbt    LZMA range decoder
lib/range_encoder.mbt    LZMA range encoder
lib/lzma_encoder.mbt     LZMA 编码状态机
lib/lzma2_encoder.mbt    LZMA2 压缩块编码和回退
lib/match_finder.mbt     Hash chain match finder
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

反向验证由测试中的 `decode Python lzma fixture` 用例完成。

## 开源与来源说明

MoonXZ 的 XZ 容器行为和 LZMA 解码算法参考了 XZ file format specification
以及 `github.com/ulikunitz/xz` 的纯 Go 实现，并进行了 MoonBit 类型系统、
错误处理和内存模型适配。参考项目的 BSD-3-Clause 许可证和归属信息见
`THIRD_PARTY_NOTICES.md`。

本项目采用 Apache-2.0 许可证。
