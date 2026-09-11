# MoonXZ Progress

更新时间：2026-09-11

## 项目定位

- 项目名：MoonXZ
- 模块名：`lin2077-zeming/moonxz`
- 当前版本：`0.3.0`
- GitHub 仓库：https://github.com/lin2077-zeming/MoonXZ
- 当前分支：`main`
- 项目方向：纯 MoonBit 实现的 XZ / LZMA2 压缩、解压、校验和工具库
- 许可证：Apache-2.0

## 当前状态摘要

项目已经具备完整的 XZ/LZMA2 解码和压缩编码能力，支持多目标构建、流式
API、delta/x86 BCJ filter、文件 CLI 和 Python `lzma` 互操作测试。
GitHub Actions 已配置并在 Windows、Ubuntu、macOS 三个平台通过。

当前尚未正式发布到 mooncakes.io，这是比赛最终验收前的主要未完成事项。

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
- delta filter
- x86 BCJ filter

### API 与工具

- 一次性 API：`compress`、`decompress`
- 配置 API：`CompressionOptions`
- 指定 check：`compress_with_check`
- 指定压缩级别和字典：`compress_with_options`
- 输出限制：`decompress_with_limit`
- 流式 `XzWriter`
- 流式 `XzReader`
- 十六进制 CLI
- 文件 CLI：`compress-file`、`decompress-file`
- CLI demo

### 工程化

- 库包位于 `lin2077-zeming/moonxz/lib`
- CLI 位于 `cmd/main`
- `moon check --deny-warn --target all` 通过
- `moon test --deny-warn --target all` 通过，20 个测试在 wasm、wasm-gc、js、native 全部通过
- `moon fmt --check` 通过
- `moon bundle --all` 通过
- Python `lzma` 双向互操作测试通过
- CI 中加入了 registry 更新、check、test、format、bundle、CLI smoke test 和 Python interop
- 最新 CI 运行：`34611135510`，Windows、Ubuntu、macOS 全部成功

### 报告和文档

- `README.md` 包含功能矩阵、安装方式、API 示例、CLI 示例和验证命令
- `docs/DESIGN.md` 记录整体设计、分层和后续路线
- `docs/bundle-multiple-producers-fix.md` 记录 bundle 路径冲突的根因和修复
- `项目申报书.md` 已保留远端授权说明排版，并同步了当前压缩编码器能力
- `THIRD_PARTY_NOTICES.md` 记录参考实现和文件 CLI 依赖的许可证

## 关键决策

1. **纯 MoonBit 核心**

   解码和编码核心不依赖 C 库或平台 FFI，可在 wasm、wasm-gc、js 和
   native 目标运行。文件 CLI 单独依赖 `moonbitlang/x/fs`，不污染库核心。

2. **库包放在 `lib/`**

   MoonBit 的模块根包和 `moon bundle` 输出会争夺同一个
   `_build/<target>/release/bundle/<module>.core` 路径。把库代码放入
   `lib/` 后，`moon bundle` 恢复正常。根目录不再声明普通库包。

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

## 未完成代办

### 必做

- 正式执行 `moon publish`
- 在 mooncakes.io 确认 `lin2077-zeming/moonxz` 的 `0.3.0` 版本可见且可安装
- 发布后再次确认 GitHub README、mooncakes 页面和申报书信息一致
- 提交比赛报名和申报材料时使用最终仓库链接、最新 commit 和发布版本

### 可选后续

- 更深的 match finder 调优和压缩率基准
- 大文件性能和内存基准
- 更完整的损坏输入和 fuzz 测试集
- 更多 filter 兼容性测试
- LZMA1 `.lzma` 旧格式（当前不支持）

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
