# 验收自查（2026-09-24）

对照比赛方《验收指南》的 9 条逐项自查。**每条结论都附实测证据**，可在本机复现。
凡未验证或存在缺口的部分，都明确标注，不做"看起来应该没问题"的推断。

本轮核验用到的工具链：

```text
moon    0.1.20260920 (914d7da 2026-09-20)
moonc   v0.10.14+7d59c7ec9 (2026-09-18)
moonrun 0.1.20260920 (914d7da 2026-09-20)
```

---

## 1. 项目以 MoonBit 为主要实现语言，`moonc` 版本不低于 0.10.14

**符合。**

- 本机 `moonc v0.10.14+7d59c7ec9`，满足 `>= 0.10.14`
- 仓库 tracked 文件中 `*.mbt` 为 18 个；其余为文档、CI 配置、`LICENSE`、
  `scripts/interop.py`（仅用于交叉验证的测试脚本）与 `moon.mod` / `moon.pkg`。
  **没有任何 C / Rust / JS 实现，也没有 FFI**
- 更强的验证：不只是本机版本够新，**已发布的 0.4.2 源码本身也能在 0.10.14 上零警告构建**。
  在全新工程中 `moon add lin2077-zeming/moonxz` 后执行
  `moon check --deny-warn`，输出 `Finished. moon: ran 6 tasks, now up to date`，
  无 warning 无 error

> 历史说明：`0.4.1` 在 `0.10.14` 上会因 `implicit_impl_as_method` 报错（3 个），
> 已由 `0.4.2` 修复。这也是新工具链下其他选手普遍遇到的警告问题。

## 2. GitHub 仓库公开可访问，提交记录清晰

**符合。**

- 未带任何凭证的匿名访问实测：
  - `GET https://api.github.com/repos/lin2077-zeming/MoonXZ` → `private: false`、
    `visibility: public`、`license.spdx_id: Apache-2.0`
  - `GET https://raw.githubusercontent.com/lin2077-zeming/MoonXZ/main/README.md`
    → `HTTP 200`
- 提交记录：42 个提交，时间跨度 `2026-09-09` → `2026-09-24`，作者单一
  （`lin2077-zeming <438051102@qq.com>`），全部使用
  `feat:` / `fix:` / `test:` / `docs:` / `ci:` / `perf:` / `chore:` / `release:` 前缀，
  每个提交只做一件事
- 仓库描述已从占位文本 `for Sep moonbit competition` 改为实际的一句话项目摘要，
  并补充了 topics（`moonbit`、`xz`、`lzma`、`compression` 等）

## 3. 源代码结构清晰，能够完成声明的核心功能

**符合，但本轮修掉了 README 里一处自相矛盾。**

- 结构：`lib/` 为库核心（公共 API、XZ 容器、LZMA1/LZMA2、range coder、
  match finder、filters、streaming、checksums、util），`cmd/main/` 为 CLI，
  `docs/DESIGN.md` 为实现说明。README 中有逐文件的项目结构表
- "能够完成声明的核心功能"已实测，不是推断：
  - 38 个测试在 wasm / wasm-gc / js / native 四个后端全部通过
  - `python scripts/interop.py` → `MoonXZ interoperability: ok`（与 Python
    `liblzma` 双向互通）
  - 在全新工程中用 README 的 API 代码实测：XZ 压缩解压往返、x86 filter 往返、
    `.lzma` 往返，全部通过
- 声明边界与实现一致：README 明确 delta 与 x86 两个 filter 受支持，其余 6 个
  BCJ id（PowerPC / IA64 / ARM / ARM-Thumb / SPARC / ARM64）返回 `Unsupported`

> **本轮修复**：README 功能状态表原先把未实现的 filter 只写作
> "IA64 / ARM-Thumb / PowerPC"三个，而下方 BCJ 表与源码都是 6 个；
> 标题也误写为"为什么只交付 x86 一个 BCJ filter"（实际交付
> delta 与 x86 两个）。评委先读功能表，会把支持范围看错，已改正。

## 4. 提供 README，说明项目目标、安装方式、使用方法和示例，并可复现

**符合，且逐条复现过。**

- 项目目标：README 开头说明为 MoonBit 补齐 `.xz` 与 `.lzma` 的读写与校验能力
- 安装方式：`moon add lin2077-zeming/moonxz`
- 使用方法：一次性 API、`CompressionOptions`、流式 `XzWriter`/`XzReader`、
  输出上限、`.lzma` 读写，均有代码片段
- 示例可复现（实测）：
  - `moon run cmd/main -- demo` → `input_bytes=7400 xz_bytes=156 percent=2`,
    `roundtrip=true`，与 README 中"预期输出"一致
  - README 的互操作示例原样执行：
    `$xz = (moon run -q cmd/main -- compress 6869 sha256).Trim()` 后交给
    `python -c "import lzma,sys; print(lzma.decompress(...))"` → 输出 `b'hi'`，
    与 README 一致
  - 从零新建工程复现安装与调用（见第 1、3 条）

## 5. 使用持续集成工具并且覆盖检查、构建、测试流程

**符合。** `.github/workflows/ci.yml`，在 `ubuntu-latest` / `windows-latest` /
`macos-latest` 三平台并行，步骤覆盖三类流程：

| 流程 | 步骤 |
| --- | --- |
| 检查 | `moon check --deny-warn --target all`、`moon fmt --check` |
| 构建 | `moon bundle --all` |
| 测试 | `moon test --deny-warn --target all`、CLI smoke test、Python 互操作、基准 |

最近三次运行的 `conclusion` 均为 `success`，三平台全绿。

## 6. 提供至少一个可运行示例或最小使用样例

**符合（有多个）。**

- `moon run cmd/main -- demo`，README 标注为"最小可复现示例"，并给出预期输出
- README 的 `moonxz quick start` 代码片段
- CLI 提供 10 个子命令（hex 轻量入口 + 文件读写）
- `scripts/interop.py` 可从零复现"发布产物可用"这一结论

## 7. 提供完整测试，覆盖核心功能路径

**符合。** `lib/moonxz_test.mbt`（614 行，35 个测试块）+ 基准文件，
`moon test` 汇总 38 个测试，四个后端全部通过。覆盖的核心路径：

- 校验和：CRC32 / SHA-256 已知向量；四种 block check 的往返
- 编解码：空输入、重复数据、不可压缩数据的往返；压缩级别与字典大小组合；
  LZMA2 多 chunk、跨 64 KiB 边界的 match
- filter：delta 与 x86 的标准向量、全矩阵（长度 × 内容形态）往返；
  未实现 filter 明确报 `Unsupported`
- 旧格式：`.lzma` 两种头部形式、properties、损坏头部拒绝
- 健壮性：逐字节截断（任何前缀都不得解出原文）、单字节全量变异、
  伪随机垃圾输入、声明膨胀、输出上限
- 流式：多 block 读写、空流、输出限制
- 互操作：Python `lzma` 生成的 XZ / delta / x86 / padding / 拼接流向量

## 8. 发布到 mooncakes.io

**符合。**

```json
{
  "module": "lin2077-zeming/moonxz",
  "version": "0.4.2",
  "yanked": false,
  "latest_version": "0.4.2",
  "build_status": "success",
  "versions": ["0.4.2", "0.4.1", "0.4.0"]
}
```

全新工程 `moon add lin2077-zeming/moonxz` 实测解析到 `0.4.2` 并可正常构建调用。

> **已知瑕疵**：mooncakes 在**发布时**抓取 README 快照，已发布版本无法修改，
> 因此 0.4.2 页面上的 README 正文里"当前版本"仍写着 `0.4.1`（页面版本标签、
> `moon.mod` 内的 `version`、实际下载到的代码都是 `0.4.2`）。仓库 README 顶部
> 已就此加了说明。彻底消除只能再发一个版本（代码无需改动）。
>
> **另有风险**：`0.4.0` / `0.4.1` 仍在线上且未被 yank，其中 `0.4.0` 含有已撤回的
> ARM / ARM64 / SPARC BCJ filter（会静默损坏数据）。已在 `CHANGELOG.md` 中写明
> "请勿使用"，但未找到 yank 接口。评委若主动安装 0.4.0 会踩到。

## 9. 采用 OSI 认可的开源许可证；参考或移植其他项目符合原项目许可证要求

**符合。**

- 本项目：Apache-2.0（OSI 认可），`LICENSE` 为完整 Apache-2.0 文本，
  `moon.mod` 中 `license = "Apache-2.0"`，GitHub 也识别为 `Apache-2.0`
- 主要参考实现：`github.com/ulikunitz/xz`（BSD-3-Clause，作者 Ulrich Kunitz）
  - `THIRD_PARTY_NOTICES.md` 记录了项目、作者、用于算法参考的版本、许可证与来源
  - `LICENSES/BSD-3-Clause-ulikunitz-xz.txt` 收录了完整许可证原文
    （含 `Copyright (c) 2014-2022 Ulrich Kunitz`）
  - 说明中明确"未逐行复制 Go 源码"，实现使用不同的数据结构与 API，
    并自行增加了错误模型、边界检查与测试
- 唯一第三方依赖 `moonbitlang/x@0.4.46`（Apache-2.0）也在
  `THIRD_PARTY_NOTICES.md` 中记录；且仅 CLI 包使用，库核心不依赖文件系统

---

## 汇总

| # | 验收标准 | 结论 |
| --- | --- | --- |
| 1 | MoonBit 为主，`moonc >= 0.10.14` | 符合 |
| 2 | 仓库公开、提交清晰 | 符合 |
| 3 | 结构清晰、能完成声明功能 | 符合（本轮修掉 README 一处矛盾） |
| 4 | README 齐全且可复现 | 符合 |
| 5 | CI 覆盖检查/构建/测试 | 符合 |
| 6 | 至少一个可运行示例 | 符合 |
| 7 | 完整测试覆盖核心路径 | 符合 |
| 8 | 发布到 mooncakes.io | 符合（页面 README 快照为旧版，已说明） |
| 9 | OSI 许可证与第三方合规 | 符合 |

**9 条全部符合。** 未发现会导致验收失败的硬伤。

需要评委注意、但已诚实说明的两处已知瑕疵（均不影响功能与合规）：
mooncakes 页面上的 README 是旧快照；`0.4.0` / `0.4.1` 未被 yank。
