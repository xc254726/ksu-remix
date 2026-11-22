#!/usr/bin/env bash
# 拉取内核源码 + 集成 KernelSU（sbsu / BakaSU / KowSU 通用）
#
# 注意：sbsu 自带的 kernel/setup.sh 仍硬编码 `git clone Baka-SU/BakaSU`
# 并自行 checkout main，会忽略这里的 KSU_REF、也会把你的 rebrand 覆盖掉。
# 因此本脚本自行完成集成，不调用上游 setup.sh。
source "$(dirname "$0")/lib.sh"
load_env

log "拉取内核源码：$KERNEL_REPO ($KERNEL_REF)"
if [[ -d "$KERNEL_DIR/.git" ]]; then
  log "已存在，跳过克隆（删除 $KERNEL_DIR 可强制重来）"
else
  # 内核树很大，用 partial clone + 单分支，能省一半以上流量
  git clone --depth=1 --branch "$KERNEL_REF" \
    --filter=blob:none --no-checkout "$KERNEL_REPO" "$KERNEL_DIR"
  git -C "$KERNEL_DIR" sparse-checkout disable 2>/dev/null || true
  git -C "$KERNEL_DIR" checkout "$KERNEL_REF"
fi

read -r BASE LOCALVER <<<"$(split_release "$KERNEL_RELEASE")"
log "基础版本=$BASE  本地后缀=${LOCALVER:-(空)}"

# 源码版本不匹配时只警告不中断，方便先看代码；要强制中断设 STRICT_VERSION=1
if ! check_source_version "$BASE"; then
  [[ "${STRICT_VERSION:-0}" == "1" ]] && die "STRICT_VERSION=1，中止"
fi

log "拉取 KernelSU 二改源：$KSU_REPO ($KSU_REF)"
if [[ -d "$KSU_DIR/.git" ]]; then
  git -C "$KSU_DIR" fetch --depth=1 origin "$KSU_REF"
  git -C "$KSU_DIR" -c advice.detachedHead=false checkout FETCH_HEAD
else
  git clone --depth=1 --branch "$KSU_REF" "$KSU_REPO" "$KSU_DIR"
fi
KSU_HEAD="$(git -C "$KSU_DIR" rev-parse --short HEAD)"
log "KernelSU 版本：$KSU_REF @ $KSU_HEAD"

# ---- 集成：symlink + Makefile + Kconfig（等价于上游 setup.sh 的三步）----
DRV="$KERNEL_DIR/drivers"
[[ -d "$KERNEL_DIR/common/drivers" ]] && DRV="$KERNEL_DIR/common/drivers"
[[ -d "$DRV" ]] || die "找不到 drivers/ 目录，内核树结构异常"

log "建立符号链接：$DRV/kernelsu → $KSU_DIR"
ln -sfn "$KSU_DIR" "$DRV/kernelsu"

if grep -q 'kernelsu' "$DRV/Makefile"; then
  log "drivers/Makefile 已包含 kernelsu，跳过"
else
  log "drivers/Makefile 追加 obj-\$(CONFIG_KSU)"
  printf 'obj-$(CONFIG_KSU) += kernelsu/\n' >>"$DRV/Makefile"
fi

if grep -q 'drivers/kernelsu/Kconfig' "$DRV/Kconfig"; then
  log "drivers/Kconfig 已包含，跳过"
else
  log "drivers/Kconfig 挂载 kernelsu/Kconfig"
  # 必须放在 menu 之前，否则 source 不被解析
  sed -i '1i source "drivers/kernelsu/Kconfig"' "$DRV/Kconfig"
fi

if [[ "$HOOK_MODE" == "manual" ]]; then
  log "HOOK_MODE=manual，检查接管点"
  bash "$ROOT_DIR/scripts/gen-manual-hook.sh" || warn "接管点检查未通过，编译前需手工补齐"
fi

log "fetch 完成（KSU $KSU_REF @ $KSU_HEAD）"
