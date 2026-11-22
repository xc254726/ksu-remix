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

# 只读取 .env，不做必填校验。APK 相关脚本不需要 KERNEL_RELEASE。
load_env_soft() {
  if [[ -f "$ROOT_DIR/.env" ]]; then
    # shellcheck disable=SC1091
    set -a; source "$ROOT_DIR/.env"; set +a
  fi
  : "${KSU_REPO:=https://github.com/xc254726/sbsu}"
  : "${KSU_REF:=main}"
  : "${APK_BUILD_TYPE:=release}"
  : "${KSUD_ARCHES:=arm64-v8a}"
  OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
  mkdir -p "$OUT_DIR" "$BUILD_DIR"
  export APK_BUILD_TYPE KSUD_ARCHES OUT_DIR
}

load_env() {
  load_env_soft
  [[ -n "${KERNEL_RELEASE:-}" ]] || die "KERNEL_RELEASE 未设置（见 .env.example）"
  [[ -n "${KERNEL_REPO:-}"    ]] || die "KERNEL_REPO 未设置"
  [[ -n "${KSU_REPO:-}"       ]] || die "KSU_REPO 未设置"
  : "${DEFCONFIG:=gki_defconfig}"
  : "${KSU_MODE:=builtin}"
  : "${HOOK_MODE:=upstream}"
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

# ---------------- APK 侧辅助 ----------------

# Android ABI → Rust target triple（与 sbsu 的 repack_apk.py 保持一致）
abi_to_triple() {
  case "$1" in
    arm64-v8a)   echo "aarch64-linux-android" ;;
    armeabi-v7a) echo "armv7-linux-androideabi" ;;
    x86)         echo "i686-linux-android" ;;
    x86_64)      echo "x86_64-linux-android" ;;
    riscv64)     echo "riscv64-linux-android" ;;
    *) return 1 ;;
  esac
}

# Android ABI → 源码里 userspace/ksud/bin/<dir> 的目录名
abi_to_ksud_dir() {
  case "$1" in
    arm64-v8a)   echo "aarch64" ;;
    armeabi-v7a) echo "arm" ;;
    x86)         echo "x86" ;;
    x86_64)      echo "x86_64" ;;
    riscv64)     echo "riscv64" ;;
    *) return 1 ;;
  esac
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

# 确保 KernelSU 二改源已在 $KSU_DIR。
# 用 --filter=blob:none 的 partial clone：保留完整提交历史（manager 的
# versionCode = 30000 + git rev-list --count HEAD + 700 要用），但省流量。
ensure_ksu_dir() {
  if [[ -d "$KSU_DIR/.git" ]]; then
    [[ -f "$KSU_DIR/manager/gradlew" ]] && return 0
    # 克隆被中途打断时会留下 .git 但工作区是空的，这里做一次修复，
    # 否则后面会以「找不到 gradlew」的形式误报成源码结构问题。
    warn "已有 $KSU_DIR 但工作区不完整（上次克隆可能被中断）"
    if [[ -f "$KSU_DIR/.git/index.lock" ]]; then
      die "存在 $KSU_DIR/.git/index.lock。确认没有 git 进程在跑后执行 rm -f 该文件，或直接删掉 $KSU_DIR 重来"
    fi
    log "尝试强制检出修复"
    git -C "$KSU_DIR" checkout -f HEAD >/dev/null 2>&1 || true
    [[ -f "$KSU_DIR/manager/gradlew" ]] \
      || die "修复失败：$KSU_DIR 不可用，删掉后重跑（rm -rf \"$KSU_DIR\"）"
    return 0
  fi

  log "克隆二改源：$KSU_REPO ($KSU_REF) → $KSU_DIR"
  mkdir -p "$(dirname "$KSU_DIR")"
  git clone --branch "$KSU_REF" --filter=blob:none "$KSU_REPO" "$KSU_DIR" \
    || die "克隆失败：$KSU_REPO"
  [[ -f "$KSU_DIR/manager/gradlew" ]] \
    || die "克隆完成但工作区为空，检查网络或改用完整克隆（去掉 --filter）"
  log "已克隆：$(git -C "$KSU_DIR" rev-parse --short HEAD)"
}

# 输出 java 主版本号（如 21）。找不到 java 时返回非零。
java_major() {
  need_cmd java || return 1
  local v
  v=$(java -version 2>&1 | head -1)
  if [[ "$v" =~ version\ \"([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

# 定位 NDK：优先环境变量，其次常见 SDK 目录下版本号最大的一个
find_ndk() {
  local cand pick
  for cand in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}"; do
    [[ -n "$cand" && -d "$cand" ]] && { echo "$cand"; return 0; }
  done
  for cand in "${ANDROID_SDK_ROOT:-}/ndk" "${ANDROID_HOME:-}/ndk" \
              "$HOME/Android/Sdk/ndk" "/usr/local/lib/android/sdk/ndk" \
              "$HOME/Library/Android/sdk/ndk" "$LOCALAPPDATA/Android/Sdk/ndk"; do
    [[ -n "$cand" && -d "$cand" ]] || continue
    pick=$(ls -1 "$cand" 2>/dev/null | sort -V | tail -1)
    [[ -n "$pick" ]] && { echo "$cand/$pick"; return 0; }
  done
  return 1
}

