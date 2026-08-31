# simt_reduce_demo

使用 **SIMT 编程模式**实现向量归约求和（ReduceSum），结构与 `ccec/reduce_demo` **完全对齐**：
GM→UB 搬运 → SIMT VF 归约 → UB→GM 搬出，并用 ccec 内建 `get_sys_cnt()` 统计各阶段硬件 cycle 数，便于分析**单 AI Core** 上 SIMT VF 的运行开销。

参考样例：
- asc-devkit `05_simd_simt_hybrid/.../simd_simt_gather_and_adds`：混合编程模式（`__global__ __vector__` + `asc_vf_call`）
- asc-devkit `03_simt_api/.../atomic_histogram`：SIMT `asc_atomic_add` 写 UB（block-local atomic）
- 同 workspace `ccec/reduce_demo`：cycle 统计与 host 结构模板

## 核心结论：atomic add 可以写 UB

**可以。** `asc_atomic_add` 提供 `__gm__` 与 `__ubuf__` 两套重载：

```c
// simt_api/device_atomic_functions.h
__SIMT_DEVICE_FUNCTIONS_DECL__ inline int32_t asc_atomic_add(__ubuf__ int32_t *address, int32_t val);
__SIMT_DEVICE_FUNCTIONS_DECL__ inline uint32_t asc_atomic_add(__ubuf__ uint32_t *address, uint32_t val);
__SIMT_DEVICE_FUNCTIONS_DECL__ inline float   asc_atomic_add(__ubuf__ float   *address, float   val);
// ... 以及 __gm__ 版本（额外支持 int64/uint64）
```

底层 ccec 内建 `atomicAdd` 同样支持 UB（`__clang_cce_simt_atomic.h` 中 `__CCE__ATOM_S_BUILTIN` 生成 `atomicAdd(__ubuf__ float*)` 等重载，走 ATOM/RED 指令）。

支持类型：

| 地址空间 | 支持类型 |
| --- | --- |
| `__gm__` | int32 / uint32 / float / int64 / uint64 |
| `__ubuf__` | int32 / uint32 / float（无 int64/uint64 重载） |

**重要语义**：UB 是每个 AI Core（block）私有的本地存储。`asc_atomic_add` 写 UB 只对**本 block 内线程**可见；多 block 场景必须先在各 block 内归约出 block 局部和，再由 block 内 thread 0 合并到 GM 全局结果。本样例 `NUM_BLOCKS = 1`，单 block 内 atomic 到 UB 即得到最终和。

## 文件结构

- `simt_reduce.asc`：混合编程模式 kernel（SIMT VF 归约 + cycle 统计）+ host 侧入口
- `data_utils.h`：输入/输出文件读写辅助工具（`ReadFile` / `WriteFile`），与 asc-devkit 一致
- `CMakeLists.txt`：ASC CMake 构建脚本，目标 `dav-3510`（混合模式，**不需要** `--enable-simt`）
- `scripts/gen_data.py`：数据生成脚本（4096 个 float32，golden[0] = sum）

## 构建与运行

```bash
# 1. 加载 CANN 环境（以 CANN 9.1.0-beta.3 conda 环境为例）
source /home/xinyang/miniconda3/envs/Ascend950_9.1.0-beta.3/Ascend/cann-9.1.0-beta.3/set_env.sh

# 2. 生成测试数据
cd ccec/simt_reduce_demo
python3 scripts/gen_data.py

# 3. 构建（混合模式：__global__ __vector__ + asc_vf_call，无需 --enable-simt）
cmake -B build -DCMAKE_ASC_RUN_MODE=npu -DCMAKE_ASC_ARCHITECTURES=dav-3510
cmake --build build

# 4. 运行（需在带 Ascend 设备的服务器上执行，host 侧 device_id = 2）
./build/demo
```

预期输出（服务器实测）：

```
Kernel cycle stats
 GM->UB copy: ... cycles
 SIMT VF reduce: ... cycles     <- 单 AI Core 上 SIMT VF 归约的硬件 cycle 数
 UB->GM copy: ... cycles
 kernel total: ... cycles
Output sum: <sum>
Golden sum: <sum>
test pass!
```

**注意**：host 侧 `device_id = 2`，运行时请按环境修改（`npu-smi info` 确认设备号）。本机（WSL 开发机）无 NPU 设备，`aclInit` 失败后 kernel 启动阻塞（timeout），需在服务器上运行。

## 与 reduce_demo 的对比

| 项目 | reduce_demo（SIMD） | simt_reduce_demo（SIMT） |
| --- | --- | --- |
| kernel 声明 | `__vector__ __global__` | `__global__ __vector__`（混合） |
| 归约实现 | `__simd_vf__` + vlds/vcadd/vsts | `__simt_vf__` + 线程循环 + `asc_atomic_add` |
| 归约启动 | kernel 内直接调用 | `asc_vf_call<simt_reduce_sum>(dim3(THREADS), ...)` |
| 逻辑核心数 | `NUM_BLOCKS = 1` | `NUM_BLOCKS = 1` |
| cycle 统计 | `get_sys_cnt()`（noinline） | `get_sys_cnt()`（noinline） |
| 编译选项 | 无 | 无（混合模式无需 `--enable-simt`） |
| 启动语法 | `<<<blocks, 0>>>` | `<<<blocks, dyn_ub_size, stream>>>`（SIMT 线程工作区） |

## 实现说明

### SIMT VF 归约函数

```c
__simt_vf__ __launch_bounds__(SIMT_THREADS) inline void simt_reduce_sum(
    __ubuf__ float* x_local, __ubuf__ float* y_local, uint32_t length, uint32_t out_align)
```

1. thread 0 清零 `y_local[0..out_align-1]`（避免搬运未初始化数据），`asc_syncthreads()` 保证清零可见
2. 每线程 **grid-stride 循环**（`stride = blockDim.x`）读 UB 元素，寄存器内累加局部和（避免逐元素 atomic 竞争）
3. `asc_atomic_add(&y_local[0], partial)` 原子累加到 UB（竞争范围 = block 内线程数）
4. `asc_syncthreads()` 保证所有线程完成 UB 原子累加后再返回

### kernel 主流程与 cycle 统计

```
t0 ── GM->UB 搬运（PIPE_MTE2）── t1 ── SIMT VF 归约（PIPE_V）── t3 ── UB->GM 搬出（PIPE_MTE3）── t4
cycles[0] = t1-t0  GM->UB 搬运
cycles[1] = t3-t2  SIMT VF reduce（t2 在 SIMT VF 启动前取）
cycles[2] = t4-t0  kernel 总耗时
cycles[3] = t4-t3  UB->GM 搬出
```

关键约束（3510 后端实测）：

1. **混合模式 kernel 声明为 `__global__ __vector__`**，不需要 `--enable-simt`（那是纯 SIMT `__global__` kernel 的选项）。用 `--enable-simt` 编译混合代码会报 `__shared__ local variables not allowed in __host__ functions`。
2. **头文件**：需同时包含 `simt_api/asc_simt.h`（SIMT 线程/atomic）与 `c_api/asc_simd.h`（搬运/同步 `asc_copy_*`/`asc_sync_*`）。
3. **`get_sys_cnt()` 必须 noinline 包装**：它是 ccec 编译器内建，Release（-O2/-O3）下多次调用会被 CSE/常量折叠合并，导致各时间戳相等、cycle 差值为 0。
4. **计时前必须同步到 PIPE_S**：`get_sys_cnt()` 走 PIPE_S 标量流水线，与被测的 PIPE_MTE2/PIPE_V/PIPE_MTE3 异步。每次读计数器前必须插入对应流水线到 PIPE_S 的同步（`asc_sync_notify(from, PIPE_S, ...)` + `asc_sync_wait(from, PIPE_S, ...)`）。
5. **SIMT VF 完成后用 PIPE_V → PIPE_S 同步**：确保 t3 读到 SIMT VF 真实完成后的计数器（SIMT VF 归入 vector 流水执行）。

## 关键 SIMT API 使用说明

### asc_vf_call

```c
template <auto funcPtr, typename... Args> __aicore__ inline void asc_vf_call(dim3 threadNums, Args&&... args);
```

- 在 `__vector__` kernel 主体中启动 SIMT VF 函数（`__simt_vf__`），`threadNums` 为线程数
- 示例：`asc_vf_call<simt_reduce_sum>(dim3(SIMT_THREADS), x_local, y_local, length, out_align);`

### asc_atomic_add

```c
template <typename T> T asc_atomic_add(T* address, T val);  // T: int32/uint32/float/int64/uint64
```

- 对 `address` 指向的地址做原子加，返回旧值（可忽略）
- `address` 可为 `__gm__` 或 `__ubuf__` 指针；类型匹配对应重载
- 走 PIPE 原子指令（ATOM/RED），硬件保证多线程并发下的原子性

### asc_syncthreads

```c
void asc_syncthreads();
```

- block 内线程屏障：所有线程到达后才继续
- 用于：清零 UB 后、读取 UB 原子结果前、block 归约合并前

### __launch_bounds__

```c
__simt_vf__ __launch_bounds__(SIMT_THREADS) inline void func(...)
```

- 编译期声明本 SIMT VF 的最大线程数，帮助编译器分配寄存器/资源
- 与 `asc_vf_call(dim3(SIMT_THREADS), ...)` 的线程数对应

## 产品支持情况

| 产品 | 支持 |
| --- | --- |
| Ascend 950PR / Ascend 950DT | 支持 |
| Atlas A3 训练系列产品 / Atlas A3 推理系列产品 | 支持 |
| Atlas A2 训练系列产品 / Atlas A2 推理系列产品 | 支持 |
| Atlas 200I/500 A2 推理产品 | 不支持 |
| Atlas 推理系列产品 AI Core / Vector Core | 不支持 |
| Atlas 训练系列产品 | 不支持 |
