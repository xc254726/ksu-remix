#!/usr/bin/env bash
# 构建环境体检。缺什么会直接说清楚怎么补。
source "$(dirname "$0")/lib.sh"

fail=0
chk() {
  if command -v "$1" >/dev/null 2>&1; then
    log "ok    $1  $("$1" --version 2>/dev/null | head -1)"
  else
    warn "缺失  $1  →  $2"; fail=1
  fi
}

log "检查编译工具链"
chk clang   "apt install clang lld llvm  （或使用 AOSP 预编译 clang）"
chk ld.lld  "apt install lld"
chk make    "apt install build-essential"
chk bc      "apt install bc"
chk bison   "apt install bison"
chk flex    "apt install flex"
chk git     "apt install git"
command -v python3 >/dev/null || { warn "缺失  python3  →  apt install python3"; fail=1; }

log "检查内核编译依赖（头文件）"
[[ -e /usr/include/openssl/ssl.h ]] || warn "缺 libssl-dev → apt install libssl-dev"
[[ -e /usr/include/elf.h ]]        || warn "缺 libelf-dev → apt install libelf-dev"

log "检查参数"
if [[ -f "$ROOT_DIR/.env" ]]; then
  load_env
  read -r BASE LOCALVER <<<"$(split_release "$KERNEL_RELEASE")"
  log "KERNEL_RELEASE = $KERNEL_RELEASE"
  log "  基础版本     = $BASE"
  log "  本地后缀     = ${LOCALVER:-(空)}"
  log "  页大小       = $(detect_page_size "$KERNEL_RELEASE")"
  log "KSU_MODE       = $KSU_MODE"
  log "HOOK_MODE      = $HOOK_MODE"
  [[ -n "${STOCK_BOOT:-}" ]] && log "STOCK_BOOT     = $STOCK_BOOT" || warn "未配置 STOCK_BOOT，只能编内核、不能出 boot.img"
else
  warn "没有 .env，先 cp .env.example .env 并填写"
  exit 1
fi

if [[ "$fail" == "1" ]]; then
  die "环境不完整，按上面提示补齐后再试"
fi
log "环境检查通过"
