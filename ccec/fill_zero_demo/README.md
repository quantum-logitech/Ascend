# fill_zero_demo

对一块**大于 256B**（> 1 个 VF 帧，VL=256B）的 UB 空间 fill 0 的性能对比样例：
把同一块 16KB（4096 float = 64 帧）UB 用 4 种写法填 0，用 `get_sys_cnt()` 统计
每轮平均 cycle，并把结果搬回 GM 逐元素校验全 0，供分析哪种 fill 优化最合理。

## 文件结构

| 文件 | 说明 |
| --- | --- |
| `fill_zero.asc` | kernel 主体 + host 侧入口，4 种 fill0 候选 + cycle 统计 + 校验 |
| `CMakeLists.txt` | ASC CMake 构建脚本，目标架构 `dav-3510`，运行模式 `npu` |

## 构建与运行

```bash
cmake -B build -DCMAKE_ASC_RUN_MODE=npu -DCMAKE_ASC_ARCHITECTURES=dav-3510
cmake --build build
./build/demo [device_id]
```

## 4 种 fill0 候选（v0..v3）

| 变体 | 写法 | 说明 |
| --- | --- | --- |
| v0 | `asc_duplicate_scalar` + `asc_storealign`，每帧 | c_api 风格，每帧重新生成零寄存器 |
| v1 | `asc_duplicate_scalar` 一次 + 循环 `asc_storealign` | c_api 风格，零寄存器提升到循环外 |
| v2 | cce `vdup` + `vsts`，每帧 | 裸内建，每帧重新生成零寄存器 |
| v3 | cce `vdup` 一次 + 循环 `vsts` | 裸内建，零寄存器提升到循环外 |

## 三个候选优化方向的调研结论（写入本样例前核实）

1. **是否存在"硬件指令直接给整块 UB 填 0"？**
   3510 的 c_api / cce 只暴露**寄存器级** duplicate（`asc_duplicate_scalar` /
   cce 内建 `vdup`：标量广播成一个全零向量寄存器），以及单帧 store
   （`asc_storealign` / `vsts`，一帧 = 256B）。**没有**公开的"整块 UB dst
   fill"指令/接口。因此 >256B 的整块 fill 必然拆成
   "生成全零寄存器（1 次或每帧）+ 逐帧 vsts"；v0..v3 覆盖这两种组合。

2. **是不是有专门的全零寄存器，只用循环遍历存出 0？**
   没有硬件"恒零向量寄存器"的概念；寄存器必须先被 vdup/duplicate_scalar
   写成 0 才能 store。但该"生成 0"的动作可以**只做一次、提出循环**
   （v1/v3），循环体内只剩纯 store —— 这已经是"循环遍历存 0"的最优形态。
   v0/v2（每帧生成）与 v1/v3（一次生成）的 cycle 差，就是"每帧 vdup 的
   代价"，可直接用于判断是否需要编译器做循环不变量提升。

3. **能不能用 vlds 的 mask+init 顺带造出全零寄存器、省掉 vdups？**
   V300 (3510) 的普通对齐 load `vlds` **不带 predication / mask / init**
   语义（见 plt_demo 注释：load 无 mask 输入，总是整帧读入），所以"靠 load
   的 mask+init 生成全零寄存器"在当前指令面上**不可行**。本样例用
   "零寄存器提升到循环外"（v1/v3）逼近这一思路想验证的收益：全零寄存器只
   生成一次后，fill 退化为纯 store 带宽问题。

## 测量口径

- 被测块长 `FILL_LEN = 4096` float（16KB），`ITERATIONS = 8` 轮；
  每变体独立 UB 缓冲 + 独立 GM 输出段，互不干扰。
- 时间戳用 ccec 内建 `get_sys_cnt()`（PIPE_S），按 cycle_count_demo 的
  结论：`noinline` 包装防 CSE；每次读计数前先做 `PIPE_V -> PIPE_S` 同步。
- vector 指令全部放在 `__simd_vf__` 函数内；`get_sys_cnt()` 留 kernel 主体。
- 输出 `per-fill cycles` = 该变体 `ITERATIONS` 轮总 cycle / `ITERATIONS`。

## 如何继续分析

- 改 `FILL_LEN`（块大小）与 `ITERATIONS`（轮数）观察标量/向量开销占比；
- 在 `fill_zero.asc` 中新增变体即可对比：如不同 unroll 的 vsts 循环、
  `repeat` 形式的长 store、以及是否用 `MODE_MERGING` 的 vdup 等；
- 若只关心小尾巴（不足 64 lane 的末尾），可参照 plt_demo/pltm_demo 用
  `plt_b32` / `pltm_b32` 生成部分 mask，只对尾部 store 一次。
