#!/usr/bin/env bash
# 编译内核并校验 vermagic 版本串
source "$(dirname "$0")/lib.sh"
load_env
: "${ARCH:=arm64}"
export ARCH

[[ -f "$OUT_DIR/.config" ]] || die "缺少 $OUT_DIR/.config，先跑 make config"
read -r BASE LOCALVER <<<"$(split_release "$KERNEL_RELEASE")"

log "编译 Image（jobs=$JOBS）"
make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 -j"$JOBS" Image

# ---- 关键校验：编出来的 kernel.release 必须逐字符等于目标版本串 ----
REL_FILE="$OUT_DIR/include/config/kernel.release"
[[ -f "$REL_FILE" ]] || die "找不到 $REL_FILE，编译未产生版本信息"
BUILT="$(tr -d '\n' <"$REL_FILE")"
if [[ "$BUILT" != "$KERNEL_RELEASE" ]]; then
  warn "构建产物版本串与目标不一致"
  warn "  目标：$KERNEL_RELEASE"
  warn "  实际：$BUILT"
  warn "刷入后 vendor 模块会因为 vermagic 不符而全部拒载（掉触控/声音/相机）"
  warn "检查 CONFIG_LOCALVERSION 是否被 defconfig 或其它 fragment 覆盖"
  [[ "${ALLOW_VERMAGIC_MISMATCH:-0}" == "1" ]] || die "中止（设 ALLOW_VERMAGIC_MISMATCH=1 可强制继续）"
else
  log "vermagic 校验通过：$BUILT"
fi

if [[ "$KSU_MODE" == "module" ]]; then
  log "编译模块（LKM 模式）"
  make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 -j"$JOBS" modules
  KO="$(find "$OUT_DIR" -name 'kernelsu.ko' -print -quit)"
  [[ -n "$KO" ]] || die "未找到 kernelsu.ko"
  cp -v "$KO" "$OUT_DIR/kernelsu.ko"
fi

# 收集内核镜像（不同 config 产出后缀不同）
for f in Image Image.gz Image.lz4 Image.gz-dtb; do
  [[ -f "$OUT_DIR/arch/$ARCH/boot/$f" ]] && cp -v "$OUT_DIR/arch/$ARCH/boot/$f" "$OUT_DIR/" || true
done

log "build 完成，产物在 $OUT_DIR"
