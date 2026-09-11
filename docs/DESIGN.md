# MoonXZ 设计说明

## 目标

MoonXZ 的核心目标不是做一个只适用于示例数据的玩具压缩器，而是提供一个
可以处理标准 XZ 与旧格式 LZMA 数据、可以被其他实现交叉验证、并能在 MoonBit 的
wasm、wasm-gc、js 和 native 目标上运行的库。

实现采用“解码优先、编码渐进”的路线：

1. 先把标准 XZ 容器和 LZMA2 压缩块解码做正确。
2. 编码端先建立规范兼容的未压缩 LZMA2 块，随后加入 range encoder。
3. 使用 hash chain match finder 生成 literal 和普通 match，逐步完善压缩率。
4. 在 block 层增加 delta 与 BCJ filter，并提供流式读写和文件 CLI。
5. 补上 `.lzma` 旧格式，并把每个 filter 的输出与 `liblzma` 交叉验证。

## 分层

### XZ container

`lib/xz.mbt` 负责：

- stream header、footer 和 index 的 CRC32 校验
- block header 的 flags、VLI、filter 和 padding 解析
- block 数据、block padding 和 block check 的定位
- 多 block、拼接 stream 和四字节 stream padding
- block filter chain 解析与写入
- LZMA2 框架长度与 block header 声明长度的交叉校验

最后一项是刻意的冗余校验：LZMA2 chunk 自己记录了压缩长度，block header 也记录了
一次。解码器只用其中一方也能工作，但两者不一致时说明输入被篡改或结构错误，
因此直接报错而不是静默忽略。

### LZMA2

`lib/lzma2.mbt` 负责 chunk 层：

- EOS、未压缩 chunk、压缩 chunk
- 未压缩大小、压缩大小和属性字节
- 状态重置、属性重置和字典重置
- chunk 声明的未压缩大小与实际产出大小的交叉校验

`lib/lzma2_encoder.mbt` 负责 LZMA2 压缩块写入，并在压缩结果不划算时
自动回退为未压缩块。

多 chunk 解码有一个容易写错的点：进度必须相对 **chunk 起点** 衡量，而不能相对
字典起点。LZMA2 允许后续 chunk 沿用之前的字典（`dict_start` 停在旧位置），
如果拿字典起点算进度，前一个 chunk 的产出会错误地满足下一个 chunk 的大小目标，
于是第二个 chunk 会一个字节都不解。这个错误在 65536 字节以下的输入上完全不可见，
因为那时只有一个 chunk。

### LZMA1 / `.lzma`

`lib/lzma1.mbt` 负责旧格式容器：

- 13 字节头部：属性字节、字典大小、未压缩大小
- 属性字节到 `(lc, lp, pb)` 的分解
- 字典大小按参考实现的 `2^n` / `2^n + 2^(n-1)` 规则归一化
- 已声明大小与 EOS 标记两种终止方式
- `.lzma` 编码：写入精确大小，因此载荷不需要结束标记

解码循环本身与 LZMA2 共用：`decode_stream` 接受一个可选的 `target_size`，
`Some(n)` 表示"解到 n 字节就停"，`None` 表示"解到结束标记"。LZMA2 chunk 用前者，
未知大小的 `.lzma` 用后者。

### LZMA

`lib/lzma_decoder.mbt` 实现：

- literal、match、rep-match 的 12 状态机
- literal context 和 matched literal
- length coder
- distance slot、reverse tree 和 align bits
- 字典距离检查和重叠 match 复制

`lib/range_decoder.mbt` 实现 LZMA 使用的 32-bit range decoder、概率更新、
direct bits 和正反向 bit tree。

`lib/range_encoder.mbt` 实现对应的 range encoder 和 32 位溢出处理。

`lib/match_finder.mbt` 建立三字节 hash chain，搜索最长 match，并由压缩级别
控制链搜索深度。

`lib/lzma_encoder.mbt` 编码 literal、length 和 distance，并维护与解码器
一致的状态转换和概率模型。

### Filter

`lib/filters.mbt` 实现 XZ delta 和 BCJ filter。

支持范围是有意收窄的：

| filter id | 名称 | 状态 |
| --- | --- | --- |
| 0x03 | delta | 支持 |
| 0x04 | x86 | 支持 |
| 0x05 | PowerPC | 未实现 |
| 0x06 | IA64 | 未实现 |
| 0x07 | ARM | 支持 |
| 0x08 | ARM-Thumb | 未实现 |
| 0x09 | SPARC | 支持 |
| 0x0A | ARM64 | 支持 |
| 0x21 | LZMA2 | 支持 |

未实现的 filter 按 id 识别后返回 `Unsupported`。这比"近似实现"更可取：BCJ
filter 的写入位置和位域一旦算错，解码结果会静默变成错误字节；block check 只能
发现不一致，无法区分"应该正确"和"看起来正确"。

已实现的 x86、ARM、ARM64、SPARC 都有双向验证：

- 解码方向：以 `liblzma` 生成的 XZ 向量做断言
- 编码方向：MoonXZ 写出的流由 Python `lzma` 解回原文

实现 BCJ filter 时有两个已知陷阱：

1. **运算符优先级。** MoonBit 的 `|` 比 `<<` 结合更紧，所以 `a | (b << 11)`
   会被解析成 `(a | b) << 11`。所有位域都必须先单独移位到自己的绑定里、
   再逐步合并。
2. **过短输入。** `liblzma` 对太短的输入会跳过 BCJ filter，此时压缩流里存的就是
   原始字节。测试向量必须足够长，否则会得到"filter 没生效"的假象。

### Streaming 和 CLI

`lib/streaming.mbt` 提供按 block 工作的 `XzWriter` 和 `XzReader`。
`XzWriter` 每次 `write` 产生一个完整 block，`finish` 产生 index 和
footer；`XzReader` 每次 `read_block` 返回一个已校验和过滤的 block。

`cmd/main` 提供十六进制命令和文件命令，覆盖 XZ 与 `.lzma`。文件命令使用
`moonbitlang/x/fs`，但库包本身不依赖它，仍可在 wasm、wasm-gc、js 和
native 目标中使用。

### 校验

`lib/check.mbt` 实现 XZ 支持的四类 check：

- none
- CRC32
- CRC64/XZ
- SHA-256

这些实现都只依赖 MoonBit 标准库。

## 错误模型

公共 API 使用 `XzError`，将错误分为：

- `InvalidHeader`
- `Truncated`
- `Unsupported`
- `Corrupt`
- `ChecksumMismatch`
- `OutputLimitExceeded`

解析函数不通过静默截断来容忍损坏输入。对于超过限制的输出，会直接返回
`OutputLimitExceeded`，防止解压炸弹。

## 损坏输入的测试策略

策略是穷举而不是抽样：对一条有效流逐字节、逐位翻转，并断言

1. 任何变异都不会 panic；
2. 任何变异都不会静默解出与原文不同的数据；
3. 绝大多数变异（当前 216 次中 210 次）被明确报错。

这套测试确实发现了两个真实缺陷：一个重叠 match 拷贝在损坏输入下可能越界读取并
panic，以及 LZMA2 框架长度缺少与 block header 的交叉校验。

少数变异确实无法检测，这是格式本身的性质：LZMA2 chunk 框架记录的压缩长度可以
由解码器扫描到达终止符重新推导，因此翻转这类字节不会改变任何解出的字节。把
这类情况写进断言说明，比为了凑一个"100% 检测率"而放宽断言更有价值。

## 后续路线

### 0.5.0

- 补齐 IA64、ARM-Thumb、PowerPC BCJ filter
- 更细的错误定位
- 压缩率和性能基准
- 更大文件的流式 `.lzma` 支持

## 许可证策略

项目自身使用 Apache-2.0。参考的 `ulikunitz/xz` 使用 BSD-3-Clause，
其许可证全文和归属信息保存在 `LICENSES/BSD-3-Clause-ulikunitz-xz.txt`
和 `THIRD_PARTY_NOTICES.md`。后续如果引入新的参考实现或测试向量，必须
在同一位置补充来源和许可证。
