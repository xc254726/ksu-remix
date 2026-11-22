#!/usr/bin/env bash
# 公共函数。被其它脚本 source，不单独执行。
set -Eeuo pipefail

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
OUT_DIR="${OUT_DIR:-}"
KERNEL_DIR="${KERNEL_DIR:-$BUILD_DIR/kernel}"
KSU_DIR="${KSU_DIR:-$BUILD_DIR/KernelSU}"
export BUILD_DIR KERNEL_DIR KSU_DIR

load_env() {
  if [[ -f "$ROOT_DIR/.env" ]]; then
    # shellcheck disable=SC1091
    set -a; source "$ROOT_DIR/.env"; set +a
  fi
  [[ -n "${KERNEL_RELEASE:-}" ]] || die "KERNEL_RELEASE 未设置（见 .env.example）"
  [[ -n "${KERNEL_REPO:-}"    ]] || die "KERNEL_REPO 未设置"
  [[ -n "${KSU_REPO:-}"       ]] || die "KSU_REPO 未设置"
  : "${DEFCONFIG:=gki_defconfig}"
  : "${KSU_MODE:=builtin}"
  : "${HOOK_MODE:=kprobe}"
  : "${JOBS:=$(nproc 2>/dev/null || echo 4)}"
  OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
  mkdir -p "$OUT_DIR" "$BUILD_DIR"
  export DEFCONFIG KSU_MODE HOOK_MODE JOBS OUT_DIR
}

# 从 "6.6.66-android15-8-g...-4k" 拆出基础版本与本地版本后缀
split_release() {
  local r="$1" base rest
  if [[ "$r" == *-* ]]; then
    base="${r%%-*}"
    rest="-${r#*-}"
  else
    base="$r"; rest=""
  fi
  printf '%s\n%s\n' "$base" "$rest"
}

# 校验源码 Makefile 的版本与目标基础版本一致
check_source_version() {
  local base="$1" mk="$KERNEL_DIR/Makefile"
  [[ -f "$mk" ]] || die "找不到 $mk"
  local v p s src
  v=$(awk -F' = ' '/^VERSION = /{print $2}' "$mk")
  p=$(awk -F' = ' '/^PATCHLEVEL = /{print $2}' "$mk")
  s=$(awk -F' = ' '/^SUBLEVEL = /{print $2}' "$mk")
  src="$v.$p.$s"
  if [[ "$src" != "$base" ]]; then
    warn "源码版本 $src 与目标内核 $base 不一致"
    warn "这意味着固件版本与厂商公开源码错配，编出的内核大概率刷了不开机"
    warn "请改用对应固件版本的源码，或从设备 dump 内核后对比"
    return 1
  fi
  log "源码版本校验通过：$src"
}

# 推导页大小
detect_page_size() {
  local r="$1"
  if [[ -n "${PAGE_SIZE:-}" ]]; then echo "$PAGE_SIZE"; return; fi
  case "$r" in
    *-16k) echo "16k" ;;
    *-4k)  echo "4k"  ;;
    *)     echo ""    ;;
  esac
}
