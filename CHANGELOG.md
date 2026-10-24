# Changelog

## 0.4.5

- 新增独立的 `tools/conformance` MoonBit 模块。它由 JSON manifest 驱动，
  对同一组 fixture 同时运行 MoonXZ 与 `aurora0x27/lzma-mbt`，输出可机器读取的
  差分报告。外部 Python/`xz` 只负责生成和独立校验语料，验证主体仍在 MoonBit。
- 新增 24 个语料场景、48 个实现级检查，覆盖 XZ / `.lzma`、四类 check、
  Delta / x86、六种未实现 BCJ 的拒绝路径、ARM64 互操作、拼接流、
  128 KiB LZMA2 边界、
  1 字节分块解码、截断、校验损坏和输出上限。
- 修复流式解码器处理外部 XZ 流时的误报：当 Block Header 省略可选压缩大小时，
  尚未收全 LZMA2 数据会被误判为 `Truncated`。现在 `XzStreamDecoder` 等待更多
  输入，并在 `finish_input` 后仍能正确判断是否真正截断。新增外部 Python fixture
  的逐字节回归测试，测试数 46 → 47。
- ARM64 fixture 由 MoonBit `lzma-mbt` 编码，并使用官方 `xz 5.8.3` 独立解码校验；
  选择该向量是为了避免用同一个实现自证正确性。
- 新增 `docs/compatibility.md`，钉定 XZ Utils 5.8.3 的文件格式规范、完整支持矩阵、
  当前限制和每项结论对应的验证用例。

## 0.4.4

无功能变更。`0.4.3` 的代码是正确的，但它在 `Int` → `Int32` 迁移之前发布，
因此 mooncakes 上的源码写法与仓库当前状态不一致。本版只是让发布产物与仓库
字面一致，方便比对与复现。

- 仓库源码已在 `moonc v0.10.15+943464bfa` 上完成 `Int` → `Int32` 迁移
  （`Int` 现为别名，属语法层改写；46 个测试四个后端与 liblzma 互操作均通过）
- CI 增加 `moonc` 版本校验步骤：只提供 `latest` 无法固定版本，因此遇到未经本
  项目验证的编译器会直接失败并给出原因，避免再次把工具链换代误判为代码缺陷
- **请勿使用 `0.4.3` 及更早版本**：`0.4.2` 及更早存在 LZMA2 长度进位错误与
  长度校验整数溢出；`0.4.3` 已修复这些缺陷，仅缺少上述写法对齐

## 0.4.3

本次修复源自第一次验收的失败反馈，四个问题全部复现并修好。

- **工具链适配：`moonc v0.10.15`**。新编译器在 `moon fmt` 中把 `Int` 统一改写为
  `Int32`（`Int` 现在是其别名），并相应改写签名与常量类型。本库已在
  `moonc v0.10.15+943464bfa` 上重跑完整验证：`check --deny-warn`、四个后端的
  `test --deny-warn`、`fmt --check`、`bundle --all`、CLI 示例、基准与互操作脚本
  全部通过。CI 因此前"静默跟随 latest"而暴露过一次问题：0.10.15 的格式化结果
  与 0.10.14 不同，`moon fmt --check` 会失败，看起来像代码格式错误，实际是编译器
  换代。CI 现已加入版本校验步骤，遇到未经本项目验证的 `moonc` 会直接失败并指明
  原因，避免同类误判

- **修复：LZMA2 未压缩长度字段的进位错误（严重，影响所有 `moonc 0.10.14+`
  构建）**。18 位长度字段由控制字节低 5 位加 16 位低位组成，编码的是
  `(长度 - 1)`。原实现先给低位加一、再与高位相或：

  ```text
  ((control & 0x1F) << 16) | (read_u16_be() + 1)     // 错误
  (((control & 0x1F) << 16) | read_u16_be()) + 1     // 正确
  ```

  于是在长度不是 65536 整数倍时，低位为 `0xFFFF`，加一产生的进位在按位或时被
  丢弃，声明的长度会多出一个高位单位。liblzma 对 128 KiB 输出控制字节 `0xE1`
  配低位 `0xFFFF`，实测被读成 `0x30000` 而非 `0x20000`，随后"声明长度与实际产出
  不符"报错。**128 KiB / 256 KiB / 1 MiB 的合法 Python XZ 全部解码失败**。
  `lib/lzma2.mbt` 的同一处错误也在 `lib/xz.mbt` 的 `scan_lzma2_size` 里存在，
  一并修正。此前未被发现的原因：MoonXZ 自己的编码器把块上限保守地定在 64 KiB，
  自产数据永远走不到这条路径，只有外部产生的 ≥64 KiB 压缩块才会触发
- **修复：`lib/util.mbt` 的长度校验整数溢出与越界（严重）**。原检查写作
  `pos + length > data.length()`，而 `length` 来自不可信输入，二者相加可溢出成
  负数而通过检查，随后按该长度拷贝会读到缓冲区之外。改为 `length > remaining`
  形式，任何一项都不会溢出。`read_bytes` 与 `skip` 同步修正
- **修复：`.lzma` 空输入无法编码**。编码器直接拒绝空输入，使 `compress_lzma1`
  成为唯一不能编码空值的入口。现在头部的长度字段写 0、range encoder 正常收尾，
  liblzma 与本库都能正确解回空结果
- **新增：有界窗口的流式解码 `XzStreamDecoder`**。`XzReader` 需要整个压缩流在
  内存里，新类型改为"送一段、取一块"：`supply` 追加输入，`next` 取出一块，
  已解码块占用的字节由 `compact` 丢弃，因此常驻内存是待处理输入加单个块，
  而不是整条流的全部字节。支持一次一个字节地喂入（含拼接流与 stream padding），
  并在输入耗尽时明确区分"还要更多数据"与"流被截断"。文件 CLI 已改用它
- 新增回归测试（测试数 38 → 46）：
  - liblzma 生成的 128 KiB / 256 KiB / 1 MiB 单块 fixture，控制字节分别为
    `0xE1` / `0xE3` / `0xEF`，全部覆盖进位路径
  - 空输入 `.lzma` 的编码与解码
  - 超长声明长度字段必须被拒绝且不 panic
  - 流式解码器逐字节喂入必须与一次性解码逐字节一致，含拼接流与 padding
  - 流式解码器的截断检测与输出上限
- 新增脚本：`scripts/repro_lzma2_chunk.py` 复现并展示块控制字节，
  `scripts/fuzz_cli.py` 用小样本畸形输入搜寻 panic（CI 之外按需运行）
- `scripts/interop.py` 增加 128 KiB / 256 KiB 不可压缩输入用例，使该边界在
  CI 中持续被覆盖
- 文档：README 的 filter 支持表原先只列了 3 个未实现的 BCJ filter（实际 6 个），
  小节标题写作"为什么只交付 x86 一个 BCJ filter"（实际交付 delta 与 x86 两个），
  两处已改正

## 0.4.2

- **适配 MoonBit 工具链更新**（`moonc v0.10.12` → `v0.10.14`）。新版把
  `implicit_impl_as_method` 报为警告，导致 `moon check --deny-warn` 直接失败，
  也就是 CI 的检查步骤会挂。已为 `CheckKind` 和 `XzError` 补上显式的
  `pub extend ... with Eq::{...}` / `... with @debug.Debug::{to_repr}` 声明
- 这是为满足"验收版本 `0.10.14+`"而发布的补丁：`0.4.1` 在 `0.10.14` 上
  `moon check --deny-warn` 会失败（3 个 `implicit_impl_as_method`），请勿用
  `0.4.1` 在 `0.10.14+` 上构建，改用 `0.4.2`
- 补全公共 API 的文档注释（`crc32`、`crc64`、`check_bytes`、`CheckKind::id` /
  `size` / `from_id`、`compress_with_check`、`XzWriter::new` / `write` / `finish`、
  `XzReader::new`），启用 `missing_doc` 后不再有警告
- 修正两处新工具链提示的问题：`LzmaDecoder` 的结构体字面量补上类型前缀；
  `RangeEncoder::new` 的 `hint` 参数默认值从未被使用，改为必填
- 说明：`unnecessary_annotation` 在跨包引用上会误报。按提示去掉
  `@moonxz.CheckKind::` 里的类型路径会让构建直接失败（实测 `The type/trait
  CheckKind is not found`），因此保留原写法；该警告默认关闭，不影响 `--deny-warn`
- 文档：统一 README、CLI banner（原先仍打印 `MoonXZ 0.4.0`）、`Progress.md` 和
  申报书中的版本号。**注意 mooncakes 页面上的 README 仍是 0.4.2 发布时的旧快照**
  （其中"当前版本"写着 `0.4.1`）：mooncakes 只在发布时抓取一次 README，已发布
  版本无法修改，而 README 是在 0.4.2 发布之后才更正。实际安装到的就是 `0.4.2`，
  可核对 tarball 内 `moon.mod` 的 `version = "0.4.2"`。如需让页面同步，只能发布
  下一个版本（仅重新抓取 README，代码无需改动）

- 压缩性能：match finder 增加 nice-length 提前退出，并按级别收紧链搜索深度。
  此前只有找到"更长的匹配"才会停止搜索，在重复数据上每个候选都要比较数百字节，
  拖慢了整个编码器。各级别的 depth / nice length 现在按参考编码器的形状设定
- 压缩性能：range encoder 的输出缓冲按输入大小预分配。字面量路径频繁触发
  重规范化，让数组从小容量反复增长会不断重分配并复制已有内容
- 新增基准测试（`lib/moonxz_bench_test.mbt`）：按级别、按尺寸、按内容形态测量
  压缩与解压，并输出 README 引用的压缩率表，使文档里的数字可以被重新生成而不是
  被信任
- 修正对 `monotonic_clock_end` 单位的理解：它返回微秒而非毫秒。此前据此得出的
  "编码 1 MiB 需要 43 秒"的结论是错的，实际约 65 MiB/s
- 新增测试：压缩必须真正缩小可压缩数据（不得回退为存储），且不可压缩数据的
  膨胀必须局限于分帧开销

## 0.4.1

- **安全修复**：撤回 ARM、ARM64、SPARC 三个 BCJ filter。它们在特定字上地址运算
  溢出，编码后再解码无法还原原文，会静默损坏数据；`liblzma` 也会拒绝 MoonXZ
  写出的流。`0.4.0` 包含这三个 filter，请勿使用该版本处理需要 ARM/ARM64/SPARC
  filter 的数据
- 这三个 filter id 现在返回 `Unsupported`
- 新增"全 filter × 长度 × 内容形态"矩阵回归测试（4 × 19 × 5）

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
