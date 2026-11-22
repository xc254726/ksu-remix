#!/usr/bin/env bash
# 拉取内核源码 + 集成 KernelSU
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

log "拉取 KernelSU：$KSU_REPO ($KSU_REF)"
if [[ -d "$KSU_DIR/.git" ]]; then
  git -C "$KSU_DIR" fetch --depth=1 origin "$KSU_REF" || true
  git -C "$KSU_DIR" checkout FETCH_HEAD 2>/dev/null || true
else
  git clone --depth=1 --branch "$KSU_REF" "$KSU_REPO" "$KSU_DIR"
fi

log "集成 KernelSU 到内核树（复用上游 setup.sh）"
if [[ -f "$KSU_DIR/kernel/setup.sh" ]]; then
  ( cd "$KERNEL_DIR" && bash "$KSU_DIR/kernel/setup.sh" )
elif [[ -d "$KSU_DIR/kernel" ]]; then
  warn "上游未提供 setup.sh，改用目录拷贝方式"
  rm -rf "$KERNEL_DIR/KernelSU"
  cp -a "$KSU_DIR" "$KERNEL_DIR/KernelSU"
  # 顶部 Makefile 挂载子目录
  grep -q 'obj-\$(CONFIG_KSU)' "$KERNEL_DIR/Makefile" || \
    printf '\nobj-$(CONFIG_KSU) += KernelSU/kernel/\n' >>"$KERNEL_DIR/Makefile"
  # 纳入 Kconfig
  grep -q 'source "KernelSU/kernel/Kconfig"' "$KERNEL_DIR/Kernel/Kconfig" 2>/dev/null || \
    printf '\nsource "KernelSU/kernel/Kconfig"\n' >>"$KERNEL_DIR/Kernel/Kconfig" 2>/dev/null || true
else
  die "KernelSU 源码结构异常，找不到 kernel/ 目录"
fi

if [[ "$HOOK_MODE" == "manual" ]]; then
  log "HOOK_MODE=manual，检查五个接管点"
  bash "$ROOT_DIR/scripts/gen-manual-hook.sh" || warn "接管点检查未通过，编译前需手工补齐"
fi

log "fetch 完成"
