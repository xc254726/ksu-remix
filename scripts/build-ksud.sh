#!/usr/bin/env bash
# 编译 ksud（Rust）——APK 里 lib/<abi>/libksud.so 的来源
#
# 为什么单独一步：gradle 只编 Java/Kotlin + cpp 里的 C/C++，不产 libksud.so。
# 管理器要装模块、late-load LKM，靠的是这个 Rust 二进制。sbsu 的官方流程是
# 先编 ksud，再用 repack_apk_multi.py 把它塞进 APK 的 lib/<abi>/。
#
# 用法: ./scripts/build-ksud.sh [abi ...]
#       默认取 $KSUD_ARCHES（arm64-v8a）
# 产物: $KSU_DIR/target/<triple>/release/ksud
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env_soft

ARCHES=("$@")
if [[ ${#ARCHES[@]} -eq 0 ]]; then
  IFS=',' read -r -a ARCHES <<<"$KSUD_ARCHES"
fi
[[ ${#ARCHES[@]} -gt 0 ]] || die "没有指定任何 ABI"

ensure_ksu_dir
[[ -d "$KSU_DIR/userspace/ksud" ]] || die "找不到 $KSU_DIR/userspace/ksud，二改源结构不对"

# ---- 前置条件 ----
need_cmd cargo  || die "缺少 cargo。装 Rust：curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
need_cmd rustup || die "缺少 rustup"
need_cmd clang  || die "缺少 clang（编 lkm bootstrap 用）"

if ! rustup toolchain list 2>/dev/null | grep -q '^nightly'; then
  die "缺少 nightly 工具链。执行：rustup toolchain install nightly --profile minimal --component rust-src"
fi

if ! cargo ndk --version >/dev/null 2>&1; then
  die "缺少 cargo-ndk。执行：cargo install cargo-ndk --locked"
fi

NDK_DIR="$(find_ndk)" || die "找不到 Android NDK。设置 ANDROID_NDK_HOME 后重试"
export ANDROID_NDK_HOME="$NDK_DIR"
export ANDROID_NDK_ROOT="$NDK_DIR"
log "NDK: $NDK_DIR"

PKG="${KSU_PACKAGE_NAME:-}"
if [[ -n "$PKG" ]]; then
  log "KSU_PACKAGE_NAME=$PKG（编进 ksud，需与 APK 的 applicationId 一致）"
else
  log "KSU_PACKAGE_NAME 未设置，沿用二改源里的默认值"
fi

# lkm bootstrap 目标文件：build.rs 期望它已存在（上游 CI 也是先单独编一次）
BOOTSTRAP_SRC="$KSU_DIR/userspace/ksud/src/lkm_image_bootstrap.S"
BOOTSTRAP_OBJ="$KSU_DIR/userspace/ksud/.lkm_image_bootstrap.o"
if [[ -f "$BOOTSTRAP_SRC" ]]; then
  log "编译 lkm bootstrap: $BOOTSTRAP_OBJ"
  clang --target=aarch64-linux-gnu -c -nostdlib -o "$BOOTSTRAP_OBJ" "$BOOTSTRAP_SRC" \
    || warn "bootstrap 编译失败，交给 build.rs 自行处理"
fi

build_one() {
  local abi="$1" triple ksud_dir bin
  triple="$(abi_to_triple "$abi")" || die "未知 ABI: $abi（支持 arm64-v8a / armeabi-v7a / x86_64 / x86）"
  ksud_dir="$(abi_to_ksud_dir "$abi")"

  if [[ "$abi" == "riscv64" ]]; then
    die "riscv64 需要上游专用流程（setup-rust-build.sh + 自定义 cargo config），本项目不出这个 ABI"
  fi

  log "== $abi → $triple =="

  if ! rustup target list --installed --toolchain nightly 2>/dev/null | grep -qx "$triple"; then
    log "安装 target $triple"
    rustup target add --toolchain nightly "$triple"
  fi

  # 预置二进制目录：rust-embed 会把这里的东西编进 ksud，.ko 有就带上，没有也能编
  mkdir -p "$KSU_DIR/userspace/ksud/bin/$ksud_dir"

  local ko
  ko=$(ls -1 "$KSU_DIR"/aarch64-android*-lkm/*kernelsu.ko 2>/dev/null | head -1 || true)
  if [[ "$abi" == "arm64-v8a" && -n "$ko" ]]; then
    log "带上 LKM：$(basename "$ko")"
    cp -f "$ko" "$KSU_DIR/userspace/ksud/bin/$ksud_dir/"
  fi

  # 上游 CI 的原始命令。build-std-features 单独出现时部分 cargo 版本会报错，
  # 因此失败后自动补 -Z build-std 重试一次（会重编 std，明显更慢，但能过）。
  local args=(-P 26 -t "$triple" -r -Z build-std-features=optimize_for_size -Z trim-paths)
  if ! ( cd "$KSU_DIR/userspace/ksud" && cargo +nightly ndk b "${args[@]}" ); then
    warn "$abi 首次编译失败，补 -Z build-std=std,panic_abort 重试"
    ( cd "$KSU_DIR/userspace/ksud" && cargo +nightly ndk b "${args[@]}" -Z build-std=std,panic_abort )
  fi

  bin="$KSU_DIR/target/$triple/release/ksud"
  [[ -f "$bin" ]] || die "编译结束但找不到 $bin"
  log "ok  $bin  ($(du -h "$bin" | cut -f1))"
}

for abi in "${ARCHES[@]}"; do
  abi="$(echo "$abi" | tr -d '[:space:]')"
  [[ -n "$abi" ]] && build_one "$abi"
done

log "ksud 全部完成"
for abi in "${ARCHES[@]}"; do
  abi="$(echo "$abi" | tr -d '[:space:]')"
  [[ -n "$abi" ]] || continue
  triple="$(abi_to_triple "$abi")"
  printf '  %-12s %s\n' "$abi" "$KSU_DIR/target/$triple/release/ksud"
done
