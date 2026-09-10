# Moon bundle 多生产者 panic 修复记录

## 问题现象

在 MoonBit 项目中执行：

```text
moon bundle
```

会触发工具链 panic：

```text
thread 'main' panicked at crates\moonbuild-rupes-recta\src\execution_plan\mod.rs:...
declared execution output has multiple producers:
...\_build\<target>\release\bundle\<module>.core
```

该问题最初在 MoonBit `0.1.20260824` 上出现。升级到
`0.1.20260904` 后，只要项目仍使用“模块根包”布局，问题依然存在。

## 这不是普通项目 bug

以下证据说明它首先来自 MoonBit 工具链对默认项目布局的处理方式：

- 使用 `moon new` 生成的官方模板也会复现相同 panic。
- `moon check`、`moon test`、`moon run` 均正常，只有 `moon bundle` 崩溃。
- 移除 CLI、测试文件后仍然复现，说明不是可执行包或测试包的问题。
- 升级 MoonBit 稳定版后仍然复现，说明不是简单版本回退能解决的问题。

因此，需要从 MoonBit 的 bundle 产物路径规划层面理解根因。

## 根因

`moon bundle` 的目标是把整个模块打包为：

```text
_build/<target>/release/bundle/<module-last-segment>.core
```

例如模块 `lin2077-zeming/moonxz` 会生成：

```text
_build/wasm/release/bundle/moonxz.core
```

与此同时，如果库源码位于模块根目录，即存在根包 `moon.pkg`，根包自身的
编译产物也会落在同一个位置：

```text
_build/wasm/release/bundle/moonxz.core
```

因为 mono 布局下，模块根包的 `package_dir` 不会追加额外的包名目录。

于是：

- 一个 action 负责编译根包，输出 `bundle/moonxz.core`
- 另一个 action 负责 bundle-core，也输出 `bundle/moonxz.core`

MoonBit 构建器发现同一个输出路径有两个 producer，直接 panic。

`moon new` 模板默认把库代码放在模块根目录，所以连模板都会触发。

## 修复方式

将库代码从模块根目录移动到非根子包中。

本项目最终布局：

```text
moon.mod
lib/
  moon.pkg
  moonxz.mbt
  xz.mbt
  lzma2.mbt
  lzma_decoder.mbt
  range_decoder.mbt
  check.mbt
  util.mbt
cmd/
  main/
```

调整后：

```text
_build/wasm/release/bundle/lib/lib.core
_build/wasm/release/bundle/moonxz.core
```

编译产物和 bundle 输出不再冲突。

CLI 的导入同步改为：

```text
import {
  "lin2077-zeming/moonxz/lib" @moonxz,
}
```

对应提交：

```text
a39f70a fix: move library package into lib for bundling
```

## 验证命令

修复后的完整验证：

```text
moon check --deny-warn --target all
moon test --deny-warn --target all
moon fmt --check
moon bundle --target wasm
moon bundle --all
python scripts/interop.py
```

全部通过。

## 经验总结

1. 当 `moon bundle` 报 `multiple producers` 时，先看冲突路径是否为
   `_build/<target>/.../bundle/<module>.core`。
2. 如果项目存在模块根包 `moon.pkg`，优先怀疑根包产物与 bundle 产物同路径。
3. `moon check` 和 `moon test` 不执行 bundle 阶段，因此它们通过不能排除
   该问题。
4. 通用解决方法是把库源码放入 `lib/` 或 `src/` 等非根子包，不在根目录
   声明普通库包。
5. 如果最终只需要 `moon test` 和发布，不依赖 `moon bundle`，工具链
   `moon publish --dry-run` 目前仍可完成打包校验。
