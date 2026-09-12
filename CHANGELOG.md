# Changelog

## 0.4.0

- 新增 LZMA1 / `.lzma` 旧格式解码：13 字节头解析、已声明大小与 EOS 标记两种
  终止方式，并用 Python `lzma` 的 `FORMAT_ALONE` 与流式压缩器双向验证
- 新增公开 API `decompress_lzma1`、`decompress_lzma1_with_limit`、
  `compress_lzma1`、`lzma1_properties`、`lzma1_declared_size`
- 明确 BCJ filter 的支持边界。只有 delta 与 x86 是交付的：
  - 两者都通过了"4 个 filter × 19 个长度 × 5 种内容形态"的全矩阵绕回测试
  - 两者都与 Python `liblzma` 双向互通（MoonXZ 写出的流 liblzma 能解，
    liblzma 写出的流 MoonXZ 也能解）
- **撤回 ARM、ARM64、SPARC 三个 BCJ filter**：它们曾经实现并通过最初的向量
  测试，但在补齐长度与内容形态矩阵后暴露出静默损坏数据——地址运算在特定字上
  溢出后编码解码不再互逆，`liblzma` 会以 `Corrupt input data` 拒绝 MoonXZ 写出
  的流。现在这些 filter id 返回 `Unsupported`
- ARM-Thumb、PowerPC、IA64 同样返回 `Unsupported`：无法归纳出与 `liblzma`
  一致的字节变换规则
- 修复 LZMA2 多 chunk 解码的进度计算错误：进度必须相对 chunk 起点衡量，不能
  相对字典起点，否则上一个 chunk 的产出会错误地满足下一个 chunk 的大小目标
- 修复重叠 match 拷贝在损坏输入下可能越界读取导致的 panic
- 新增 LZMA2 chunk 声明大小与实际产出大小的交叉校验，以及 LZMA2 框架长度与
  block header 声明长度的交叉校验
- 新增测试：全 filter × 长度 × 内容形态矩阵、单字节全量变异、逐字节截断、
  伪随机垃圾输入、`.lzma` 头部拒绝、多 chunk 尺寸矩阵、膨胀声明
- 测试数从 20 增至 34

### 关于测试维度的一条教训

三个被撤回的 filter 有同一个失效模式：把"看起来像分支的字"直接做无符号加减，
没有确认结果仍落在字段宽度内。它们躲过最初测试的原因是那些测试只用**一个重复
模式**配**一个方便的长度**——固定模式在不同长度下、以及固定长度下的不同模式，
触发问题的能力并不相同。新的矩阵测试同时遍历长度和内容形态。

## 0.3.0

- 实现 delta filter 和 x86 BCJ filter
- 实现流式 `XzWriter` 和 `XzReader`
- 增加 `compress-file` 和 `decompress-file` 文件 CLI
- 增加 delta/x86 标准向量、流式多 block 和文件绕回测试
- CLI 引入 `moonbitlang/x/fs`，库包仍保持无文件系统依赖

## 0.2.0

- 实现 LZMA range encoder
- 实现 hash chain match finder、压缩级别和字典大小参数
- 支持 LZMA2 压缩块编码，并在不划算时自动回退到未压缩块
- 增加压缩参数、store 模式和压缩率测试
- 使用 Go 参考实现交叉验证压缩输出

## 0.1.0

- 初始化 MoonBit 模块 `lin2077-zeming/moonxz`
- 实现 XZ stream header、footer 和 index 校验
- 实现 block header、VLI、filter 和 padding 解析
- 实现 LZMA2 未压缩块和压缩块解码
- 实现 LZMA literal、match、rep-match 状态机
- 实现 range decoder 和概率模型
- 实现 CRC32、CRC64/XZ 和 SHA-256
- 实现规范兼容的存储式 XZ 写入
- 增加多目标测试和 CLI 示例
- 将库包移动到 `lib/`，避免模块根包与 bundle 输出路径冲突
