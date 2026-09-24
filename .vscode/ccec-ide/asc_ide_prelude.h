/* ---------------------------------------------------------------------------
 * asc_ide_prelude.h -- editor-only adaptation layer for the ccec / asc dialect.
 *
 * Force-included (first, before anything else) by ./compile_flags.txt so that a
 * stock clang frontend -- clangd here -- sees roughly what bisheng sees:
 *
 *   - the private storage / core qualifiers resolve to nothing
 *   - the vector register types (vector_f32, vector_bool, ...) exist
 *   - the register intrinsics (vlds, vmuls, vsts, plt_b32, ...) are declared and
 *     therefore completable / navigable
 *   - QuantMode_t is declared (bisheng keeps it in a header we do not vendor)
 *
 * Nothing in here is ever compiled by the real bisheng build; bisheng injects
 * its own resource headers and defines all of these itself. This file exists
 * purely so the editor and the compiler agree on names.
 * ------------------------------------------------------------------------- */
#ifndef CODECWALE_CCEC_ASC_IDE_PRELUDE_H
#define CODECWALE_CCEC_ASC_IDE_PRELUDE_H

/* The wrapper header bisheng normally -includes pulls these in first; the
 * vendored headers below assume uint32_t / int8_t / size_t already exist. */
#include <stdint.h>
#include <stddef.h>

/* Stand-ins for bisheng's private scalar types. Must come first: the vendored
 * headers below typedef their vector types in terms of these. */
#include "cce_ide_scalar_types.h"

/* Bisheng's auto-injected resource headers, vendored and rewritten by
 * gen_ide_env.sh. Order matches the driver's own include order, with the
 * builtin stand-ins injected before the headers that call them. */
#include "bisheng/__clang_cce_defines.h"
#include "bisheng/__cce_ide_builtins.h"
#include "bisheng/__clang_cce_types.h"
#include "bisheng/cce_aicore_intrinsics.h"
#include "bisheng/__clang_cce_vector_types.h"
#include "bisheng/__clang_cce_vector_intrinsics.h"

/* Built-in variables kernels read directly: block_idx / block_num, and
 * threadIdx / blockDim on the SIMT path. These live in bisheng's resource dir,
 * not in CANN's headers, so without them every kernel that reads a block index
 * gets an "undeclared identifier" squiggle. */
#include "bisheng/__clang_cce_aicore_builtin_vars.h"
#include "bisheng/__clang_cce_simt_builtin_vars.h"

/* The qualifier objects kernels use unqualified -- POST_UPDATE, NORM, MODE_ZEROING,
 * ROUND_R, PART_EVEN, RS_ENABLE, PIPE_*, EVENT_ID* -- are declared in namespace
 * __cce_simd and re-exported into namespace __cce_scalar by the intrinsics
 * header ("because vector interface may be invoked inside aicore functions
 * which runs within VEC_SCOPE"). bisheng makes them visible to kernel code; a
 * namespace directive reproduces that. Declared after the include so it also
 * covers names added by later headers. */
using namespace __cce_scalar;

/* aicore-side helpers -- asc_atomic_add, asc_syncthreads and friends -- are
 * declared in namespace __asc_aicore, and kernels call them unqualified because
 * bisheng parses an aicore function body inside its own VEC_SCOPE, where that
 * namespace is in scope. Forward-declare the namespace, then name it in a
 * using-directive, so clang's lookup finds members added later by CANN headers. */
namespace __asc_aicore {}
using namespace __asc_aicore;

/* CANN's asc headers reference __host_aicore__; bisheng's defines header does
 * not provide it (only its own sys_macros.h does, and that one wants to expand
 * it to `[ host, aicore ]`, which stock clang cannot parse). Must be defined
 * before any CANN header is pulled in, so the `#ifndef` guard there is taken. */
#ifndef __host_aicore__
#define __host_aicore__
#endif

#endif /* CODECWALE_CCEC_ASC_IDE_PRELUDE_H */
