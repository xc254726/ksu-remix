#!/usr/bin/env bash
# 用原厂 boot.img 重打包出含 KSU 内核的引导镜像
source "$(dirname "$0")/lib.sh"
load_env

[[ -n "${STOCK_BOOT:-}" ]] || die "未设置 STOCK_BOOT（原厂 boot.img 路径）"
[[ -f "$STOCK_BOOT" ]]     || die "STOCK_BOOT 不存在：$STOCK_BOOT"

# 优先用 .env 指定，其次找 PATH，最后找常见位置
MB="${MAGISKBOOT:-}"
if [[ -z "$MB" ]] || [[ ! -x "$MB" ]]; then
  MB="$(command -v magiskboot || true)"
fi
[[ -n "$MB" ]] || die "找不到 magiskboot。从 Magisk 的 AnyKernel3/tools 或官方发布包里取，放到 PATH 或用 MAGISKBOOT= 指定"

WORK="$BUILD_DIR/pack"
rm -rf "$WORK"; mkdir -p "$WORK"
cp "$STOCK_BOOT" "$WORK/boot.img"

log "解包 boot.img"
( cd "$WORK" && "$MB" unpack boot.img >/dev/null )

KERNEL_BIN=""
for c in Image.lz4 Image.gz Image; do
  [[ -f "$OUT_DIR/$c" ]] && { KERNEL_BIN="$OUT_DIR/$c"; break; }
done
[[ -n "$KERNEL_BIN" ]] || die "out/ 里没有内核镜像，先跑 make kernel"
log "替换内核：$(basename "$KERNEL_BIN")"
cp "$KERNEL_BIN" "$WORK/kernel"

log "重打包"
( cd "$WORK" && "$MB" repack boot.img >/dev/null )

TARGET="$OUT_DIR/boot-${KERNEL_RELEASE}.img"
cp "$WORK/new-boot.img" "$TARGET"
log "产出：$TARGET  ($(du -h "$TARGET" | cut -f1))"

cat <<'EOF'

刷入方法（Bootloader 已解锁）：
  fastboot flash boot_a boot-<release>.img
  fastboot flash boot_b boot-<release>.img     # A/B 设备建议两个槽都刷，防止切换槽后失效

注意：
  - 重打包会破坏 AVB 签名。解锁设备通常只弹橙字警告，不影响开机
  - 若刷后卡 logo，回刷原厂 boot.img 即可恢复：
      fastboot flash boot_a <stock-boot.img>
EOF
