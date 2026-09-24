#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gen_ide_env.sh -- generate an editor-side "asc dialect" environment for VSCode.
#
# Why this exists
# ---------------
# ccec (bisheng) is a clang fork with a private language dialect: the `.asc`
# language, `__gm__` / `__ubuf__` / `__simd_vf__` qualifiers, `[aicore]`
# attribute lists, `kernel<<<blocks, args>>>` launch syntax, and a pile of
# bisheng-only builtin types (`__bf16`, `__cce_half`, `__fp8e4m3`, ...).
#
# The driver silently -includes a set of headers out of its resource directory
# (tools/ccec_compiler/lib/clang/*/include/__clang_cce_*.h). Those headers
# declare the vector register types (vector_f32, vector_bool, ...) and the
# register intrinsics (vlds / vmuls / vsts / plt_b32 / ...) that CANN's own
# asc/ headers and your kernels call. A stock clang frontend (what clangd and
# cpptools use) cannot parse them as-is, so out of the box you get no
# completion and no index for exactly the API you care about.
#
# What this script does
# ---------------------
# 1. Copies the four resource headers that matter into .vscode/ccec-ide/bisheng/
#    and rewrites the constructs stock clang chokes on:
#      - `[aicore]` / `[aicpu]` / `[aicore, host]` attribute lists  -> removed
#      - `__attribute__((clang_builtin_alias(__builtin_cce_*)))`    -> removed
#        (the declaration survives, so completion still works)
#      - bisheng-only builtin scalar types                         -> std types
#      - two ctor overloads that collapse into duplicates once the
#        __gm__/__ubuf__ qualifiers are neutralised
# 2. Extracts the QuantMode_t enumerator list (declared in
#    cce_aicore_intrinsics.h, a header we deliberately do not vendor).
# 3. Writes ./compile_flags.txt at the repo root: the real CANN include set
#    from CMake, plus the dialect defines clangd needs.
#
# These are editor-only artifacts. They are never seen by a bisheng build.
#
# Usage:  bash .vscode/ccec-ide/gen_ide_env.sh [CANN_ROOT]
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHIM_DIR="$REPO_ROOT/.vscode/ccec-ide"
OUT_DIR="$SHIM_DIR/bisheng"

CANN_ROOT="${1:-${ASCEND_HOME_PATH:-}}"
if [[ -z "$CANN_ROOT" ]]; then
  for c in "$HOME/CANN"/*/cann-* "$HOME/miniconda3/envs"/*/Ascend/cann-*; do
    [[ -d "$c/asc" ]] && CANN_ROOT="$c"
  done
fi
if [[ ! -d "$CANN_ROOT/asc" ]]; then
  echo "error: cannot locate a CANN install (looked at '$CANN_ROOT')." >&2
  echo "       pass it explicitly: bash $0 /path/to/cann-x.y.z" >&2
  exit 1
fi

RES_DIR="$(ls -d "$CANN_ROOT"/tools/ccec_compiler/lib/clang/*/include 2>/dev/null | head -1)"
if [[ ! -d "$RES_DIR" ]]; then
  echo "error: bisheng resource include dir not found under $CANN_ROOT/tools/ccec_compiler/lib/clang/" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# --- 1. vendor + patch ------------------------------------------------------
patch_header() { # $1 = header name
  local src="$RES_DIR/$1" dst="$OUT_DIR/$1"
  [[ -f "$src" ]] || { echo "  ! missing $src"; return 0; }
  sed -E \
    -e 's/\[\s*aicore\s*,\s*host\s*\]//g' \
    -e 's/\[\s*host\s*,\s*aicore\s*\]//g' \
    -e 's/\[\s*aicore\s*\]//g' \
    -e 's/\[\s*aicpu\s*\]//g' \
    -e 's/__attribute__\(\(clang_builtin_alias\([^)]*\)\)\)//g' \
    "$src" > "$dst"
  # int4x2_t has separate __gm__/__ubuf__ copy-ctors; once the qualifiers are
  # neutralised they become duplicate declarations of the same ctor.
  sed -i -E '/int4x2_t\(__(gm|ubuf)__ int4x2_t &x\)/ s|^|// |' "$dst"
  printf '  patched %s\n' "$1"
}

echo "CANN root : $CANN_ROOT"
echo "resource  : $RES_DIR"
patch_header __clang_cce_defines.h
patch_header __clang_cce_types.h
# cce_aicore_intrinsics.h carries QuantMode_t / QuantMode_post / the ReluMode
# enums and is pulled in at the end of __clang_cce_types.h, so the vendored
# copy is what keeps QuantMode_t::NoQuant etc. completable. It is a flat list of
# enums plus clang_builtin_alias declarations; stripping the alias attribute
# leaves ordinary prototypes, which is exactly what an indexer wants.
patch_header cce_aicore_intrinsics.h
patch_header __clang_cce_vector_types.h
patch_header __clang_cce_vector_intrinsics.h
# These two declare the built-in variables kernels read directly: block_idx /
# block_num (blockIdx.x), and threadIdx / blockDim for the SIMT path. They use
# __declspec(property(...)) to turn field reads into builtin calls, which needs
# -fdeclspec (see the flags below).
patch_header __clang_cce_aicore_builtin_vars.h
patch_header __clang_cce_simt_builtin_vars.h

# --- 2. dialect defines -----------------------------------------------------
# One source of truth: the probe below and compile_flags.txt must agree, or the
# probe preprocesses different #if branches than the editor will.
DIALECT_DEFS=(
  "-D__bf16=__cce_ide_bf16_t"     # reserved type token in clang; cannot be typedef'd
  "-D__CCE__=1"
  "-D__NPU_ARCH__=3510"           # dav-3510 / Ascend 950 (CMAKE_ASC_ARCHITECTURES)
  "-D__CCE_VF_VEC_LEN__=256"
  "-D__CCE_AICORE__=310"
  "-D__CCE_ARCH__=100"
  "-D__CCE_IS_AICORE__=1"
  "-D__CCE_AICORE_SUPPORT_SIMT__=1"
  "-D__CCE_AICORE_ENABLE_MIX__=1"
  "-D__CCE_ENABLE_AUTO_INFER__=1"
  "-D__CCE_NEED_ADDR_TRANS=1"
  "-D__BISHENG_CCEC__=1"
  "-D__DAV_VEC__=1"
  "-D__DAV_CUBE__=1"
  "-D__ASC_FTZ__=1"
  "-D__ASC_USE_FAST_MATH__=1"
  "-D__BISHENG_SUPPORT_BFLOAT16__=1"
)

# --- 3. neutralise the bisheng-private builtins -----------------------------
# The bodies of the register intrinsics call bisheng-private builtins
# (__builtin_cce_vintlv_v64s32, __builtin_cce_plt_b32_v300, ...). Stock clang
# knows none of them, which accounts for the bulk of the diagnostics. Instead of
# inventing ~271 prototypes with guessed signatures, each name becomes a macro
# that yields a value convertible to whatever the call site expects, so the
# bodies parse and the surrounding declarations still reach the index.
VENDORED=(
  __clang_cce_defines.h
  __clang_cce_types.h
  cce_aicore_intrinsics.h
  __clang_cce_vector_types.h
  __clang_cce_vector_intrinsics.h
  __clang_cce_aicore_builtin_vars.h
  __clang_cce_simt_builtin_vars.h
)
#
# A source-level grep is not enough: most names are built by token pasting
# (__builtin_cce_vcvtff_##FROM##2##TO##_x), so only the un-suffixed prefix is
# visible in the text. Ask bisheng's own preprocessor for the expanded set, and
# fall back to the source scan if bisheng cannot run.
BUILTIN_LIST=""
BISHENG="$CANN_ROOT/bin/bisheng"
[[ -x "$BISHENG" ]] || BISHENG="$(command -v bisheng 2>/dev/null || true)"
if [[ -x "$BISHENG" ]]; then
  probe_asc="$(mktemp /tmp/ccec_ide_probe_XXXXXX.asc)"
  probe_pp="$(mktemp /tmp/ccec_ide_probe_XXXXXX.c)"
  : > "$probe_asc"
  if ASCEND_HOME_PATH="$CANN_ROOT" "$BISHENG" --asc-aicore-lang \
       --npu-arch=dav-3510 -std=c++17 "${DIALECT_DEFS[@]}" \
       -E -c "$probe_asc" > "$probe_pp" 2>/dev/null; then
    BUILTIN_LIST="$(grep -oE '(__builtin_cce_|__cce_simt_get_)[A-Za-z0-9_]+' "$probe_pp" | sort -u)"
  fi
  rm -f "$probe_asc" "$probe_pp"
fi
if [[ -z "$BUILTIN_LIST" ]]; then
  echo "  (bisheng probe unavailable; falling back to a source scan)"
  BUILTIN_LIST="$(grep -rhoE '__builtin_cce_[A-Za-z0-9_]*' "${VENDORED[@]/#/$OUT_DIR/}" | sort -u)"
fi
{
  echo "/* Generated by .vscode/ccec-ide/gen_ide_env.sh -- editor-only. */"
  echo "/* Stand-ins for bisheng's private __builtin_cce_* machine builtins. */"
  echo "#ifndef CODECWALE_CCEC_IDE_BUILTINS_H"
  echo "#define CODECWALE_CCEC_IDE_BUILTINS_H"
  echo "namespace __cce_ide {"
  echo "/* Implicitly converts to whatever type the call site expects. */"
  echo "struct any { template <class T> operator T() const; };"
  echo "}  // namespace __cce_ide"
  while IFS= read -r b; do
    [[ -n "$b" ]] && echo "#define $b(...) (::__cce_ide::any{})"
  done <<< "$BUILTIN_LIST"
  echo "#endif /* CODECWALE_CCEC_IDE_BUILTINS_H */"
} > "$OUT_DIR/__cce_ide_builtins.h"
echo "  neutralised $(grep -c '^#define __builtin_cce_' "$OUT_DIR/__cce_ide_builtins.h") __builtin_cce_* names"

# --- 3. compile_flags.txt --------------------------------------------------
INC_DIRS=(
  "$CANN_ROOT/asc"
  "$CANN_ROOT/asc/include"
  "$CANN_ROOT/asc/impl/c_api"
  "$CANN_ROOT/asc/impl/adv_api"
  "$CANN_ROOT/asc/impl/basic_api"
  "$CANN_ROOT/asc/impl/simt_api"
  "$CANN_ROOT/asc/impl/utils"
  "$CANN_ROOT/x86_64-linux/asc"
  "$CANN_ROOT/x86_64-linux/asc/include"
  "$CANN_ROOT/x86_64-linux/asc/impl/c_api"
  "$CANN_ROOT/x86_64-linux/asc/impl/adv_api"
  "$CANN_ROOT/x86_64-linux/asc/impl/basic_api"
  "$CANN_ROOT/x86_64-linux/asc/impl/simt_api"
  "$CANN_ROOT/x86_64-linux/asc/impl/utils"
  "$CANN_ROOT/x86_64-linux/include"
  "$CANN_ROOT/include"
)

FLAGS_FILE="$REPO_ROOT/compile_flags.txt"
{
  # NOTE: no comment lines here. compile_flags.txt is a bare one-flag-per-line
  # list and clangd's handling of '#' is version dependent. Provenance and
  # regeneration instructions live in .vscode/ccec-ide/README.md instead.
  echo "-xc++"                     # .asc has no standard language; force C++
  echo "-std=c++17"
  echo "-ferror-limit=0"           # keep indexing past dialect-specific errors
  echo "-Wno-unknown-attributes"
  echo "-Wno-ignored-attributes"
  echo "-Wno-macro-redefined"
  echo "-Wno-unknown-pragmas"
  echo "-Wno-reserved-macro-identifier"
  echo "-Wno-reserved-identifier"
  echo "-fdeclspec"                  # __declspec(property(...)) in the builtin-vars headers
  echo "-include$SHIM_DIR/asc_ide_prelude.h"
  for d in "${INC_DIRS[@]}"; do
    [[ -d "$d" ]] && echo "-I$d"
  done
  printf '%s\n' "${DIALECT_DEFS[@]}"
} > "$FLAGS_FILE"

echo "wrote     : $FLAGS_FILE"
echo "done."
