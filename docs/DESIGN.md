# MoonXZ 设计说明

## 目标

MoonXZ 的核心目标不是做一个只适用于示例数据的玩具压缩器，而是提供一个
可以处理标准 XZ 数据、可以被其他实现交叉验证、并能在 MoonBit 的
wasm、wasm-gc、js 和 native 目标上运行的库。

初版采用“解码优先、编码渐进”的路线：

1. 先把标准 XZ 容器和 LZMA2 压缩块解码做正确。
2. 编码端先实现规范兼容的未压缩 LZMA2 块，建立互操作基线。
3. 后续在稳定的容器和 API 之上增加 range encoder、match finder 和 filter。

## 分层

### XZ container

`xz.mbt` 负责：

- stream header、footer 和 index 的 CRC32 校验
- block header 的 flags、VLI、filter 和 padding 解析
- block 数据、block padding 和 block check 的定位
- 多 block、拼接 stream 和四字节 stream padding
- 存储式 XZ 写入

### LZMA2

`lzma2.mbt` 负责 chunk 层：

- EOS、未压缩 chunk、压缩 chunk
- 未压缩大小、压缩大小和属性字节
- 状态重置、属性重置和字典重置

### LZMA

`lzma_decoder.mbt` 实现：

- literal、match、rep-match 的 12 状态机
- literal context 和 matched literal
- length coder
- distance slot、reverse tree 和 align bits
- 字典距离检查和重叠 match 复制

`range_decoder.mbt` 实现 LZMA 使用的 32-bit range decoder、概率更新、
direct bits 和正反向 bit tree。

### 校验

`check.mbt` 实现 XZ 支持的四类 check：

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

## 后续路线

### 0.2.0

- 实现 LZMA range encoder
- 实现 hash chain match finder
- 支持压缩级别和字典大小参数
- 与 Python `lzma` 做编码结果双向交叉验证

### 0.3.0

- delta filter
- x86 BCJ filter
- 文件 CLI
- 流式 reader / writer

### 0.4.0

- 更细的错误定位
- 更完整的损坏输入测试集
- 压缩率基准和性能基准

## 许可证策略

项目自身使用 Apache-2.0。参考的 `ulikunitz/xz` 使用 BSD-3-Clause，
其许可证全文和归属信息保存在 `LICENSES/BSD-3-Clause-ulikunitz-xz.txt`
和 `THIRD_PARTY_NOTICES.md`。后续如果引入新的参考实现或测试向量，必须
在同一位置补充来源和许可证。
