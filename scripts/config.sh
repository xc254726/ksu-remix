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
  # 挂钩方式是 choice 三选一，由 HOOK_MODE 决定
  case "$HOOK_MODE" in
    upstream) echo "CONFIG_KSU_TRACEPOINT_HOOK=y" ;;
    manual)   echo "CONFIG_KSU_MANUAL_HOOK=y" ;;
    susfs)    echo "CONFIG_KSU_SUSFS=y" ;;
    *) die "HOOK_MODE 只能是 upstream / manual / susfs，当前：$HOOK_MODE" ;;
  esac
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

# KSU 的 depends 不满足时，kconfig 会静默把 CONFIG_KSU 丢掉，不报任何错，
# 结果就是编出来的内核里没有 KSU，管理器又显示"未安装"。
want_ksu="y"; [[ "$KSU_MODE" == "module" ]] && want_ksu="m"
got_ksu=$(grep -E '^CONFIG_KSU=' "$OUT_DIR/.config" | tail -1 | cut -d= -f2- | tr -d '"')
if [[ "$got_ksu" != "$want_ksu" ]]; then
  warn "CONFIG_KSU 期望 '$want_ksu'，实际 '${got_ksu:-未设置}' —— 依赖没满足，被 kconfig 丢弃了"
  warn "对照 kernel/Kconfig 里 config KSU 的 depends 逐项检查"
  die "KSU 未生效，中止"
fi
log "ok  CONFIG_KSU=$got_ksu"

# 挂钩方式是 choice，必须且只能命中一个；一个都没有 = 内核里没有挂钩实现，
# 就算 CONFIG_KSU=y 也拿不到 root
HOOK_KEY=""
case "$HOOK_MODE" in
  upstream) HOOK_KEY=CONFIG_KSU_TRACEPOINT_HOOK ;;
  manual)   HOOK_KEY=CONFIG_KSU_MANUAL_HOOK ;;
  susfs)    HOOK_KEY=CONFIG_KSU_SUSFS ;;
esac
if ! grep -qE "^$HOOK_KEY=y" "$OUT_DIR/.config"; then
  warn "挂钩方式 $HOOK_MODE 未生效（$HOOK_KEY 不是 y）"
  grep -E '^CONFIG_KSU_(TRACEPOINT|MANUAL)_HOOK=|^CONFIG_KSU_SUSFS=' "$OUT_DIR/.config" || warn "  三个 hook 选项全都没出现在 .config 里"
  die "挂钩配置失败，中止"
fi
log "ok  $HOOK_KEY=y"

if grep -q '^CONFIG_MODVERSIONS=y' "$OUT_DIR/.config"; then
  warn "CONFIG_MODVERSIONS=y：vendor 模块的符号 CRC 必须与本内核一致，否则加载失败"
  warn "若刷入后掉硬件，把 config/ksu.fragment 里对应行打开（# CONFIG_MODVERSIONS is not set）再重编"
fi

log "config 完成"
