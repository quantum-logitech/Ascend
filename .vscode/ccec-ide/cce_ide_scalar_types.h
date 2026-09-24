/* ---------------------------------------------------------------------------
 * cce_ide_scalar_types.h -- editor-only stand-ins for bisheng's builtin scalar
 * types.
 *
 * bisheng has a set of private scalar types used as vector element types:
 *   __cce_half, __bf16, __hif8, __hif4x2, __fp8e4m3, __fp8e5m2, __fp8e8m0,
 *   __fp8e6m2, __fp4e2m1x2, __fp4e1m2x2
 *
 * These must be *distinct types*, not just typedefs of char/short. Collapsing
 * two of them onto the same underlying type makes e.g. vector_f8e4m3 and
 * vector_f8e5m2 the same vector type, which turns legal bisheng overloads into
 * C++ redefinition errors all over CANN's asc/impl tree.
 *
 * Enums with a fixed underlying type give distinct, ext_vector_type-compatible
 * element types. The 4-bit types are widened to 8 bits (no 4-bit C++ type
 * exists); that only changes a vector's byte size, which matters for codegen
 * and size static_asserts, not for parsing or completion.
 *
 * The real definitions come from bisheng itself; nothing here is compiled.
 * ------------------------------------------------------------------------- */
#ifndef CODECWALE_CCEC_IDE_SCALAR_TYPES_H
#define CODECWALE_CCEC_IDE_SCALAR_TYPES_H

/* 16-bit: distinct from each other and from every 8-bit enum below.
 *
 * `__bf16` is not typedef'd here: clang lexes it as a reserved type token (and
 * rejects it outright on targets without bf16 support), so gen_ide_env.sh
 * aliases it with `-D__bf16=__cce_ide_bf16_t` in compile_flags.txt. */
/* These must not be `short` / `unsigned short`: bisheng builds the integer
 * vector types out of exactly those (`vector_s16`, `vector_u16`), so a plain
 * typedef makes vector_f16 == vector_s16 and vector_bf16 == vector_u16. That
 * silently merges distinct overloads and produces thousands of "redefinition of
 * default argument" errors all over the intrinsics and CANN impl headers. */
enum __cce_ide_half_t : unsigned short {};
enum __cce_ide_bf16_t : unsigned short {};
typedef __cce_ide_half_t __cce_half;

/* The alignment-register payload. bisheng treats vector_align_data as a
 * builtin; the vendored headers declare `vector_align_data Data;` as a member
 * of `struct vector_align` and assume it exists. Leaving it undeclared makes
 * clang-14 recurse forever in ASTContext::getASTRecordLayout when that struct
 * is constructed. */
typedef unsigned int vector_align_data __attribute__((ext_vector_type(1)));

/* 8-bit floating point families (fp8 / hif8). */
enum __cce_ide_hif8_t : unsigned char {};
enum __cce_ide_fp8e4m3_t : unsigned char {};
enum __cce_ide_fp8e5m2_t : unsigned char {};
enum __cce_ide_fp8e8m0_t : unsigned char {};
enum __cce_ide_fp8e6m2_t : unsigned char {};

/* 4-bit packed-pair families, widened to 8 bits for the editor. */
enum __cce_ide_hif4x2_t : unsigned char {};
enum __cce_ide_fp4e2m1x2_t : unsigned char {};
enum __cce_ide_fp4e1m2x2_t : unsigned char {};

#define __hif8      __cce_ide_hif8_t
#define __hif4x2    __cce_ide_hif4x2_t
#define __fp8e4m3   __cce_ide_fp8e4m3_t
#define __fp8e5m2   __cce_ide_fp8e5m2_t
#define __fp8e8m0   __cce_ide_fp8e8m0_t
#define __fp8e6m2   __cce_ide_fp8e6m2_t
#define __fp4e2m1x2 __cce_ide_fp4e2m1x2_t
#define __fp4e1m2x2 __cce_ide_fp4e1m2x2_t

#endif /* CODECWALE_CCEC_IDE_SCALAR_TYPES_H */
