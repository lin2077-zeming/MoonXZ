# Changelog

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
