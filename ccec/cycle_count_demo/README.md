# cycle_count_demo

最小 AI Core cycle 统计样例：直接调用 ccec 编译器内建 `get_sys_cnt()`，统计 kernel 各阶段（GM→UB 搬运、vector 计算、UB→GM 搬出及总耗时）的硬件 cycle 数。

## 文件结构

| 文件 | 说明 |
| --- | --- |
| `cycle_count.asc` | kernel 主体与 host 侧入口，使用 `get_sys_cnt()` 统计 cycle |
| `data_utils.h` | 输入/输出文件读写辅助工具（`ReadFile` / `WriteFile`） |
| `CMakeLists.txt` | ASC CMake 构建脚本，目标架构 `dav-3510`，运行模式 `npu` |

## 构建与运行

```bash
cmake -B build -DCMAKE_ASC_RUN_MODE=npu -DCMAKE_ASC_ARCHITECTURES=dav-3510
cmake --build build
./build/demo
```

## 实现要点

- 使用 `__attribute__((noinline))` 包装 `get_sys_cnt()`，避免 Release（-O2/-O3）下编译器做 CSE / 常量折叠导致各时间戳相等。
- 标量 `get_sys_cnt()` 留在 `__vector__` kernel 主体（标量上下文）；所有 vector 指令（`vlds`/`vadd`/`vsts`）放入独立的 `__simd_vf__` 函数，二者不可混写，否则后端报 `Do not know how to split the result of this operator!`。
- **每次 `get_sys_cnt()` 调用前，必须插入被测流水线到 PIPE_S 的同步**（`asc_sync_notify(from, PIPE_S, ...)` + `asc_sync_wait(from, PIPE_S, ...)`），否则 PIPE_S 可能越过下游同步提前执行，读到的计数器早于真实完成时刻，导致 cycle 差值偏小甚至为 0。
- 用 `PIPE_MTE3 → PIPE_S` 的精确同步替代原 `asc_sync()`，避免全流水线排空 + barrier 握手协议的开销污染单阶段测量。

## 关于 `get_sys_cnt`

### 功能说明

读取当前系统 cycle 计数器，返回 `int64_t` 类型的当前计数值。该计数器为只读系统计数器，宽度 64bit，复位值为 0，随系统时钟持续递增，反映硬件运行以来的累计 cycle 数，常用于性能统计、耗时测量与执行序的时序判断。本接口在 AIC 与 AIV 上均可调用，返回值含义一致。

### 函数原型

`get_sys_cnt()` 是 ccec 编译器内建，对应 `clang_builtin_alias(__builtin_cce_get_sys_cnt)`，在 device 代码中可直接调用，无需包含额外头文件。

```c
__aicore__ int64_t get_sys_cnt();
```

### 返回值

返回系统 Cycle 数。

### 流水类型

PIPE_S

### 约束说明

- **该接口走 PIPE_S 标量流水，与 PIPE_MTE2 / PIPE_V / PIPE_MTE3 等其他流水异步。若要测试其他流水线的指令耗时，必须在调用该接口前插入对应流水线到 PIPE_S 的同步。**
- 本接口为只读查询接口，读取的是只读系统计数器，不修改任何寄存器或存储状态，可在 AIC 与 AIV 上下文中调用。
- 返回值由系统时钟计数器实时提供，随系统时钟持续递增，不反映核函数（Kernel）启动配置或其他静态参数。

### 产品支持情况

| 产品 | 支持 |
| --- | --- |
| Ascend 950PR / Ascend 950DT | 支持 |
| Atlas A3 训练系列产品 / Atlas A3 推理系列产品 | 支持 |
| Atlas A2 训练系列产品 / Atlas A2 推理系列产品 | 支持 |
| Atlas 200I/500 A2 推理产品 | 不支持 |
| Atlas 推理系列产品 AI Core | 不支持 |
| Atlas 推理系列产品 Vector Core | 不支持 |
| Atlas 训练系列产品 | 不支持 |

### Cycle 换算为时间

| 产品 | 频率 | 换算公式（time 单位 us） |
| --- | --- | --- |
| Ascend 950PR / Ascend 950DT | 1 GHz | `time = cycle数 / 1000` |
| Atlas A3 训练 / 推理系列产品 | 50 MHz | `time = cycle数 / 50` |
| Atlas A2 训练 / 推理系列产品 | 50 MHz | `time = cycle数 / 50` |
