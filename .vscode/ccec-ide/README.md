# ccec / asc 编辑器支持（VSCode）

让 VSCode 对 `.asc` 代码具备自动补全、跳转定义、hover 与符号索引能力。

编译仍然由 `bisheng`（`ccec`）完成，本目录下的东西**只服务于编辑器**，
不会被任何构建目标看到。

## 为什么需要它

`bisheng` 是 clang 的一个分支，带一套私有方言：

- `.asc` 语言本身，以及 `__gm__` / `__ubuf__` / `__simd_vf__` / `__global__`
  这类限定符；
- `[aicore]` 形式的属性表；
- `kernel<<<blocks, args>>>(...)` 启动语法；
- 一批 bisheng 私有的内建标量类型（`__bf16`、`__cce_half`、`__fp8e4m3` …）。

更关键的是：`bisheng` 驱动会**隐式 include** 自己资源目录下的一组头文件
（`tools/ccec_compiler/lib/clang/<ver>/include/__clang_cce_*.h`）。矢量寄存器
类型（`vector_f32`、`vector_bool` …）和寄存器级内建（`vlds` / `vmuls` /
`vsts` / `plt_b32` …）正是在那里声明的 —— 而你写的 kernel 恰恰要调它们。

clangd / cpptools 用的是**原版 clang 前端**，无法直接解析这些头文件，所以默认
情况下最需要补全的那部分 API 反而完全没有索引。

## 做了什么

`gen_ide_env.sh` 从本机 CANN 安装里取 5 个头文件，落到
`.vscode/ccec-ide/bisheng/`（已 gitignore），并改写掉原版 clang 无法解析的写法：

- `[aicore]` / `[aicpu]` / `[aicore, host]` 属性表 → 删除
- `__attribute__((clang_builtin_alias(__builtin_cce_*)))` → 删除属性
  （声明本身保留，所以补全照常可用）
- `__builtin_cce_*`（共 3091 个，多数是 token paste 拼出来的，源码里根本搜不到）
  → 由 bisheng 自己的预处理器展开后取出，逐个替换为可隐式转换为任意类型的桩，
  这样内建函数体也能通过解析

同时由 `.vscode/ccec-ide/` 下三个手写头文件补齐方言缺口：

- `asc_ide_prelude.h` —— 主编排：强制 include 上述改写后的头文件
- `cce_ide_scalar_types.h` —— bisheng 私有标量类型的替身。
  关键点：这些必须是**互不相同的类型**。若把 `__cce_half` 简单 `typedef` 成
  `short`，`vector_f16` 就会和 `vector_s16` 变成同一个类型，bisheng 里合法的
  重载会在 C++ 里变成重定义错误。
- 生成的 `__cce_ide_builtins.h` / `quant_mode_t.inc` 等

最后在仓库根目录生成 `compile_flags.txt`：CANN 的真实 include 路径（与
`ccec/*/CMakeLists.txt` 里 `target_include_directories` 一致）+ 方言宏定义 +
强制 include 上面的 prelude。

## 用法

```bash
# 生成编辑器侧环境（安装/切换 CANN 版本后重跑一次）
bash .vscode/ccec-ide/gen_ide_env.sh
# 或显式指定 CANN 根目录
bash .vscode/ccec-ide/gen_ide_env.sh /path/to/cann-9.3.0
```

脚本会按 `$ASCEND_HOME_PATH` 自动定位；没有就扫 `~/CANN/*/cann-*`。

然后在 VSCode 里装 **clangd** 扩展：

```
llvm-vs-code-extensions.vscode-clangd
```

（`.vscode/extensions.json` 已把它列为推荐项，打开工作区时会提示安装。）

装好后重新打开 `.asc` 文件即可。首次会在后台建索引，之后是即时的。

## 验证

用 clangd 18.1.3 对本仓库全部 6 个 `.asc` 逐个跑 `clangd --check`（它等于
「建 preamble + 建索引 + 在每个 token 上试补全」）：

| 文件 | 诊断 |
| --- | --- |
| `cycle_count_demo/cycle_count.asc` | 2（均为启动行） |
| `fill_zero_demo/fill_zero.asc` | 2（均为启动行） |
| `plt_demo/plt_demo.asc` | 2（均为启动行） |
| `pltm_demo/pltm_demo.asc` | 2（均为启动行） |
| `reduce_demo/reduce_demo.asc` | 2（均为启动行） |
| `simt_reduce_demo/simt_reduce.asc` | 3（启动行 + `modff`） |

把 `plt_demo.asc` 的启动行注释掉后再跑，结果是 `All checks completed, 0 errors` ——
也就是说你的代码里除了下面第 1 条之外没有任何诊断。

另外：CANN 的 `asc/impl/**` 内部仍有诊断（给真正的 bisheng 写的代码，clang 读不了）。
用系统 clang 14 做参考编译时能看到约 220 条；clangd 18 的 `--check` 只报主文件，
不把这些头文件的诊断算进来。它们不在你写的文件里，只在你主动打开那些头文件时
才可能提示，不影响补全和跳转。

## 已知边界

1. **`kernel<<<blocks, args>>>(...)` 启动那一行**报两个 `expected expression`。
   这是 CUDA 风格的启动语法，原版 clang 只在 CUDA 语言模式下解析它。每个 kernel
   文件只有宿主侧这一行受影响，其余代码完全正常。
   试过 `-xcuda` 绕开：语法能过，但 clang 转而索要它自己的 CUDA 运行时符号
   `__cudaPushCallConfiguration`（自造声明不被接受），比这一个语法点更脆弱，
   因此没有采用。

2. `simt_reduce.asc` 里额外的一条 `redefinition of 'modff'`：CANN 的
   `asc/impl/simt_api/math_functions_impl.h` 定义了设备侧
   `inline float modff(float, float*)`，与 glibc 的 `modff` 同名。
   **bisheng 对这种情况不报错**（已实测，bisheng 编译该文件零输出），这是
   clang 与 bisheng 前端的一处语义差异，无法在 clang 侧消除。
   它定位在 `#include` 那一行，看起来扎眼但不影响任何补全/跳转。
   想彻底安静的话，在 `.clangd` 里加：

   ```yaml
   Diagnostics:
     Suppress: [redefinition]
   ```

   （代价是会一并屏蔽你自己代码里真正的重定义错误，所以默认没开。）

3. `compile_flags.txt` 里的 `-D__NPU_ARCH__=3510`、`-D__CCE_VF_VEC_LEN__=256`
   对应 `CMAKE_ASC_ARCHITECTURES=dav-3510`。换目标架构时要同步改
   `gen_ide_env.sh` 后重新生成。

## 文件清单

入库（`git` 跟踪）：

| 文件 | 说明 |
| --- | --- |
| `.vscode/ccec-ide/gen_ide_env.sh` | 生成器：改写 bisheng 头文件 + 产出 `compile_flags.txt` |
| `.vscode/ccec-ide/asc_ide_prelude.h` | 方言适配主编排头（强制 include） |
| `.vscode/ccec-ide/cce_ide_scalar_types.h` | 私有标量类型的替身（必须互不相同） |
| `.clangd` | clangd 行为微调（无绝对路径） |
| `.vscode/settings.json` | `*.asc` → C++ 关联、clangd 参数 |
| `.vscode/extensions.json` | 推荐 clangd 扩展 |
| `.vscode/tasks.json` | 「重新生成 IDE 环境」任务 |

生成（gitignore，脚本重建）：

| 文件 | 说明 |
| --- | --- |
| `compile_flags.txt` | 编译参数（含 CANN 绝对路径与方言宏） |
| `.vscode/ccec-ide/bisheng/*.h` | 改写后的 bisheng 资源头文件 |
| `.vscode/ccec-ide/bisheng/__cce_ide_builtins.h` | `__builtin_cce_*` / `__cce_simt_get_*` 桩 |

## 环境（已在本机配好）

- **clangd 18.1.3** 装在 `~/.local/bin/clangd`，配套头文件在 `~/.local/lib/clang/18`
  （clangd 按「二进制上一级 /lib/clang/<ver>」找内建头，两者必须一起放）。
- **clangd 扩展** `llvm-vs-code-extensions.vscode-clangd` v0.6.0 已装到远端
  `~/.vscode-server/extensions/`。
- **`clangd.path` 必须显式固定**，写在远端 Machine 设置里：

  ```
  ~/.vscode-server/data/Machine/settings.json
  { "clangd.path": "/home/xinyang/.local/bin/clangd" }
  ```

  原因：这个 VSCode 是 **WSL remote**，服务端由 `wslServer.sh` 以**非登录 shell**
  拉起，它拿到的 PATH 是

  ```
  /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:...
  ```

  **不含 `~/.local/bin`**。也就是说 `~/.profile` 里那行 PATH 追加对扩展宿主无效，
  扩展找不到 `clangd` 就会弹「是否下载」。写死 `clangd.path` 最省事。
  （若不想写死，删掉该设置也可以：扩展会提示下载自己的 clangd 到 globalStorage。）

  注意这台机器 `sudo` 需要密码，所以没法把 clangd 放进 `/usr/local/bin`。

## 排障

装完扩展（或改了工作区设置）**必须 reload 窗口**，否则扩展不会加载 ——
VSCode 只在启动时枚举扩展。判断方法：

```bash
ls ~/.vscode-server/data/User/globalStorage/ | grep clangd   # 有目录 = 激活过
ls .cache/clangd                                             # 有目录 = 索引过本仓库
```

两个都没有，说明扩展还没跑起来。

reload 之后：

- 打开 `.asc`，右下角语言应显示 **C++**（靠 `.vscode/settings.json` 的
  `files.associations`）；
- `输出` 面板下拉选 **clangd** 可看服务日志；
- 输入 `vs` + `Ctrl+Space` 应能列出 `vsts` / `vst` / `vscatter` / `vsqrt` …；
- `Ctrl+点击` `vlds` 应跳到 `.vscode/ccec-ide/bisheng/__clang_cce_vector_intrinsics.h`。
