#!/usr/bin/env bash
# 生成 .config：defconfig + 二改 fragment + 版本串/页大小锁定
source "$(dirname "$0")/lib.sh"
load_env
: "${ARCH:=arm64}"
export ARCH

read -r BASE LOCALVER <<<"$(split_release "$KERNEL_RELEASE")"
PS="$(detect_page_size "$KERNEL_RELEASE")"
[[ -n "$PS" ]] || die "无法从 KERNEL_RELEASE 推导页大小，请在 .env 里显式设置 PAGE_SIZE=4k 或 16k"

mkdir -p "$OUT_DIR"
log "生成 $DEFCONFIG → $OUT_DIR/.config"
make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 "$DEFCONFIG"

FRAG="$(mktemp)"
trap 'rm -f "$FRAG"' EXIT

{
  echo "CONFIG_LOCALVERSION=\"$LOCALVER\""
  echo "# CONFIG_LOCALVERSION_AUTO is not set"
  if [[ "$PS" == "4k" ]]; then
    echo "CONFIG_ARM64_4K_PAGES=y"
    echo "# CONFIG_ARM64_16K_PAGES is not set"
  else
    echo "CONFIG_ARM64_16K_PAGES=y"
    echo "# CONFIG_ARM64_4K_PAGES is not set"
  fi
  if [[ "$KSU_MODE" == "module" ]]; then
    echo "CONFIG_KSU=m"
  else
    echo "CONFIG_KSU=y"
  fi
} >"$FRAG"

log "合并二改配置（页大小=$PS，LOCALVERSION=$LOCALVER，KSU_MODE=$KSU_MODE）"
"$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m -O "$OUT_DIR" \
  "$OUT_DIR/.config" "$ROOT_DIR/config/ksu.fragment" "$FRAG" >/dev/null

make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 olddefconfig

# 复核，任何一项不达标直接退出——这三项错一个就刷不进或开不了机
assert_cfg() {
  local key="$1" want="$2" got
  got=$(grep -E "^$key=" "$OUT_DIR/.config" | tail -1 | cut -d= -f2- | tr -d '"')
  [[ "$got" == "$want" ]] || die "配置校验失败：$key 期望 '$want' 实际 '$got'"
  log "ok  $key=$got"
}
assert_cfg CONFIG_LOCALVERSION "$LOCALVER"
if [[ "$PS" == "4k" ]]; then assert_cfg CONFIG_ARM64_4K_PAGES "y"; else assert_cfg CONFIG_ARM64_16K_PAGES "y"; fi
if [[ "$KSU_MODE" == "module" ]]; then assert_cfg CONFIG_KSU "m"; else assert_cfg CONFIG_KSU "y"; fi

if grep -q '^CONFIG_MODVERSIONS=y' "$OUT_DIR/.config"; then
  warn "CONFIG_MODVERSIONS=y：vendor 模块的符号 CRC 必须与本内核一致，否则加载失败"
  warn "若刷入后掉硬件，把 config/ksu.fragment 里对应行打开（# CONFIG_MODVERSIONS is not set）再重编"
fi

log "config 完成"
