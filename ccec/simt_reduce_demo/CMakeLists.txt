# ----------------------------------------------------------------------------------------------------------
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# This program is free software, you can redistribute it and/or modify it under the terms and conditions of
# CANN Open Software License Agreement Version 2.0 (the "License").
# Please refer to the License for details. You may not use this file except in compliance with the License.
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY, OR FITNESS FOR A PARTICULAR PURPOSE.
# See LICENSE in the root of the software repository for the full text of the License.
# ----------------------------------------------------------------------------------------------------------


cmake_minimum_required(VERSION 3.16)

set(CMAKE_ASC_RUN_MODE "npu" CACHE STRING "Run mode: npu, sim")
set(CMAKE_ASC_ARCHITECTURES "dav-3510" CACHE STRING "NPU architecture: dav-3510")

find_package(ASC REQUIRED)

project(kernel_samples LANGUAGES ASC CXX)

add_executable(demo
    simt_reduce.asc
)

# 混合编程模式（__global__ __vector__ kernel + asc_vf_call 启动 __simt_vf__/__simd_vf__）
# 不需要 --enable-simt（那是纯 SIMT __global__ kernel 的选项，参考 asc-devkit
# 05_simd_simt_hybrid 的 gather_and_adds 样例）。
# 头文件搜索路径补全同 reduce_demo：CANN 9.1.0-beta.3 的 asc_simd.h 在
# #if __NPU_ARCH__ 分支之前就无条件包含
# "instr_impl/npu_arch_2201/utils_impl/utils_impl.h"，该文件位于 asc/impl 树下，
# 需要显式加入 asc/impl 目录。
target_include_directories(demo PRIVATE
    ${ASCEND_CANN_PACKAGE_LINUX_PATH}/asc/include
    ${ASCEND_CANN_PACKAGE_LINUX_PATH}/asc/impl/c_api
    ${ASCEND_CANN_PACKAGE_LINUX_PATH}/asc/impl/adv_api
    ${ASCEND_CANN_PACKAGE_LINUX_PATH}/asc/impl/basic_api
    ${ASCEND_CANN_PACKAGE_LINUX_PATH}/asc/impl/simt_api
    ${ASCEND_CANN_PACKAGE_LINUX_PATH}/asc/impl/utils
    $ENV{ASCEND_HOME_PATH}/asc/include
    $ENV{ASCEND_HOME_PATH}/asc/impl/c_api
    $ENV{ASCEND_HOME_PATH}/asc/impl/adv_api
    $ENV{ASCEND_HOME_PATH}/asc/impl/basic_api
    $ENV{ASCEND_HOME_PATH}/asc/impl/simt_api
    $ENV{ASCEND_HOME_PATH}/asc/impl/utils
)

target_link_libraries(demo PRIVATE
    m
)

target_compile_options(demo PRIVATE
    $<$<COMPILE_LANGUAGE:ASC>:--npu-arch=${CMAKE_ASC_ARCHITECTURES}>
)
