# MoonXZ Progress

更新时间：2026-09-11

## 项目定位

- 项目名：MoonXZ
- 模块名：`lin2077-zeming/moonxz`
- 当前版本：`0.4.0`
- GitHub 仓库：https://github.com/lin2077-zeming/MoonXZ
- 当前分支：`main`
- 项目方向：纯 MoonBit 实现的 XZ / LZMA / LZMA2 压缩、解压、校验和工具库
- 许可证：Apache-2.0

## 当前状态摘要

项目已经具备完整的 XZ/LZMA2 解码和压缩编码能力，并新增了 `.lzma` 旧格式的
双向支持。filter 覆盖 delta 与 x86/ARM/ARM64/SPARC BCJ，另有三个 BCJ filter
明确标记为未实现并返回 `Unsupported`。支持多目标构建、流式 API、文件 CLI，
并与 Python `lzma` 做双向互操作验证。GitHub Actions 已在 Windows、Ubuntu、
macOS 三个平台通过。

当前尚未正式发布到 mooncakes.io，这是比赛最终验收前的主要未完成事项。

## 本轮（0.4.0）新增内容

### 新功能

- `.lzma` LZMA1 旧格式解码：13 字节头、属性字节分解、字典大小归一化、
  已声明大小与 EOS 标记两种终止方式
- `.lzma` LZMA1 旧格式编码
- 新公开 API：`decompress_lzma1`、`decompress_lzma1_with_limit`、
  `compress_lzma1`、`lzma1_properties`、`lzma1_declared_size`
- ARM、ARM64、SPARC 三个 BCJ filter
- CLI 新增 `lzma-decompress`、`lzma-roundtrip`、`lzma-compress-file`、
  `lzma-decompress-file`，`compress-file` 支持新的 filter 名

### 缺陷修复

- **LZMA2 多 chunk 解码进度计算错误**：进度必须相对 chunk 起点衡量，不能相对
  字典起点。原实现让前一个 chunk 的产出满足了下一个 chunk 的大小目标，导致
  第二个 chunk 一个字节都不解。该缺陷在 65536 字节以下的输入上不可见，
  因此需要 `n >= 70000` 的测试才能覆盖
- **重叠 match 拷贝可能越界 panic**：损坏输入下 `copy_match` 的索引缺少边界
  检查，新增显式校验并返回 `Corrupt`
- **LZMA2 框架缺少交叉校验**：chunk 声明的未压缩大小与实际产出大小、框架压缩
  长度与 block header 声明长度都不再被静默忽略

### 验证增强

- 测试数从 20 增至 32，四目标（wasm / wasm-gc / js / native）全绿
- 新增逐字节截断测试：任何前缀都不得解出原始数据
- 新增单字节全量变异测试：216 次变异中 210 次明确报错，其余 6 次为格式本身
  无法检测的情形（LZMA2 框架长度可被解码器重新推导），且没有任何一次变异
  静默产出与原文不同的数据
- 新增多 chunk 尺寸矩阵测试，覆盖 65535 / 65536 / 65537 / 70000 / 150000
- BCJ 向量全部由 Python 3.14 `liblzma` 生成并双向验证
- `scripts/interop.py` 扩展为覆盖 XZ 四类 check、四个 filter 和 `.lzma`

## 已完成事项

### 核心格式与算法

- XZ stream、block、index、footer 的解析和校验
- 多 block、拼接 stream、stream padding
- LZMA2 压缩块和未压缩块解码
- LZMA2 range encoder
- Hash chain match finder
- 压缩级别 0-9
- 可配置字典大小
- 压缩失败时自动回退到未压缩 LZMA2 块
- CRC32、CRC64、SHA-256 block check
- delta filter 与 x86/ARM/ARM64/SPARC BCJ filter
- `.lzma` LZMA1 解码与编码

### API 与工具

- 一次性 API：`compress`、`decompress`
- 配置 API：`CompressionOptions`
- 指定 check：`compress_with_check`
- 指定压缩级别和字典：`compress_with_options`
- 输出限制：`decompress_with_limit`
- `.lzma` API：`compress_lzma1`、`decompress_lzma1`、
  `decompress_lzma1_with_limit`、`lzma1_properties`、`lzma1_declared_size`
- 流式 `XzWriter`
- 流式 `XzReader`
- 十六进制 CLI 和文件 CLI（XZ 与 `.lzma`）
- CLI demo

### 工程化

- 库包位于 `lin2077-zeming/moonxz/lib`
- CLI 位于 `cmd/main`
- `moon check --deny-warn --target all` 通过
- `moon test --deny-warn --target all` 通过，32 个测试在四个目标全部通过
- `moon fmt --check` 通过
- `moon bundle --all` 通过
- Python `lzma` 双向互操作测试通过
- CI 中加入了 registry 更新、check、test、format、bundle、CLI smoke test
  和 Python interop

### 报告和文档

- `README.md` 包含功能矩阵、安装方式、API 示例、BCJ 支持范围、CLI 示例和
  验证命令
- `docs/DESIGN.md` 记录整体设计、分层、BCJ 实现陷阱、损坏输入测试策略和后续路线
- `docs/bundle-multiple-producers-fix.md` 记录 bundle 路径冲突的根因和修复
- `项目申报书.md` 已保留远端授权说明排版，并同步了当前能力
- `THIRD_PARTY_NOTICES.md` 记录参考实现和文件 CLI 依赖的许可证

## 关键决策

1. **纯 MoonBit 核心**

   解码和编码核心不依赖 C 库或平台 FFI，可在 wasm、wasm-gc、js 和
   native 目标运行。文件 CLI 单独依赖 `moonbitlang/x/fs`，不污染库核心。

2. **库包放在 `lib/`**

   MoonBit 的模块根包和 `moon bundle` 输出会争夺同一个
   `_build/<target>/release/bundle/<module>.core` 路径。把库代码放入 `lib/` 后，
   `moon bundle` 恢复正常。根目录不再声明普通库包。

3. **压缩级别策略**

   级别 0 使用未压缩 LZMA2 块；级别 1-9 使用 range encoder 和 hash chain
   match finder。编码结果过小时优先使用压缩块，否则自动回退到未压缩块。

4. **参考项目边界**

   这是原创 MoonBit 实现，不是直接移植。算法参考 XZ 格式规范和
   `github.com/ulikunitz/xz`，原项目许可证为 BSD-3-Clause；项目保留了
   来源和许可证说明。MoonXZ 自身采用 Apache-2.0。

5. **CLI 文件读写隔离**

   文件 CLI 使用 `moonbitlang/x/fs`，核心库继续只使用 `Bytes` 和内存 API。

6. **CI registry 必须显式更新**

   GitHub 干净 runner 只安装工具链时可能找不到 `moonbitlang/x`。CI 已在
   检查前执行 `moon update`，避免 registry cache 导致依赖解析失败。

7. **未实现的 filter 明确报错，不做近似实现**

   BCJ filter 的位域一旦算错，解码结果会静默变成错误字节。IA64、ARM-Thumb、
   PowerPC 三个 filter 目前按 id 识别后返回 `Unsupported`，这比给出一个
   未经验证的近似实现更安全，也让支持边界可测试。

8. **LZMA1 与 LZMA2 共用解码循环**

   `decode_stream` 用可选的 `target_size` 区分"解到 n 字节"和"解到结束标记"，
   LZMA2 chunk 与 `.lzma` 复用同一套状态机，避免两份实现漂移。

## 未完成代办

### 必做

- 正式执行 `moon publish`（当前版本 `0.4.0`）
- 在 mooncakes.io 确认 `lin2077-zeming/moonxz` 的 `0.4.0` 版本可见且可安装
- 发布后再次确认 GitHub README、mooncakes 页面和申报书信息一致
- 提交比赛报名和申报材料时使用最终仓库链接、最新 commit 和发布版本

### 可选后续

- 补齐 IA64、ARM-Thumb、PowerPC BCJ filter
- 更深的 match finder 调优和压缩率基准
- 大文件性能和内存基准
- 更大文件的流式 `.lzma` 支持
- 更多 filter 组合的互操作测试

## 新对话接手建议

先执行：

```text
git status --short --branch
moon version --all
moon update
moon check --deny-warn --target all
moon test --deny-warn --target all
moon fmt --check
moon bundle --all
python scripts/interop.py
```

如果本机 `python` 不在 PATH，可使用：

```text
C:\Users\LinZeming\AppData\Local\Python\bin\python.exe
```

然后检查：

```text
gh run list --repo lin2077-zeming/MoonXZ --limit 5
```

如果 CI 仍是绿的，剩余工作就是完成正式发布：

```text
moon login
moon publish
```

最后打开 mooncakes.io 确认模块、版本和 README 均已更新。
