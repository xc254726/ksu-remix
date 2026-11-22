#!/usr/bin/env bash
# 把 ksud 注入 APK，出可直接刷的最终包
#
# 做的事：调用二改源自带的 repack_apk_multi.py，把
#   $KSU_DIR/target/<triple>/release/ksud
# 改名塞进 APK 的 lib/<abi>/libksud.so，然后重签。
# 管理器的模块安装、late-load LKM 全靠这个二进制。
#
# 用法: ./scripts/pack-apk.sh [release|debug]
# 可选环境变量:
#   APK_ARCHES   要注入的 ABI，逗号分隔，默认取 KSUD_ARCHES（arm64-v8a）
#   KEYSTORE_FILE / KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD  签名（不给则自动生成临时签名）
#   APK_STRIP=0  不裁剪符号（默认裁）
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env_soft

BUILD_TYPE="${1:-$APK_BUILD_TYPE}"
ensure_ksu_dir

ARCH_CSV="${APK_ARCHES:-$KSUD_ARCHES}"
IFS=',' read -r -a ARCHES <<<"$ARCH_CSV"
[[ ${#ARCHES[@]} -gt 0 ]] || die "APK_ARCHES 为空"

APK_DIR="$KSU_DIR/manager/app/build/outputs/apk/$BUILD_TYPE"
APK="$(ls -1t "$APK_DIR"/*.apk 2>/dev/null | head -1 || true)"
[[ -n "$APK" ]] || die "找不到 $APK_DIR/*.apk，先跑 make manager"
log "输入 APK：$APK"

# ---- ksud 检查：缺了就别浪费一次重打包 ----
PROFILE="$BUILD_TYPE"
[[ -n "${KSUD_PROFILE:-}" ]] && PROFILE="$KSUD_PROFILE"
MISSING=()
for abi in "${ARCHES[@]}"; do
  abi="$(echo "$abi" | tr -d '[:space:]')"
  [[ -n "$abi" ]] || continue
  triple="$(abi_to_triple "$abi")" || die "未知 ABI: $abi"
  [[ -f "$KSU_DIR/target/$triple/$PROFILE/ksud" ]] || MISSING+=("$abi")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  die "缺少 ksud：${MISSING[*]}。先跑 make ksud KSUD_ARCHES=\"$ARCH_CSV\""
fi

# ---- 签名：没给就生成临时签名，保证 APK 能装 ----
SIGN_ARGS=()
if [[ -n "${KEYSTORE_FILE:-}" ]]; then
  [[ -f "$KEYSTORE_FILE" ]] || die "KEYSTORE_FILE 不存在：$KEYSTORE_FILE"
  SIGN_ARGS=(-K "$KEYSTORE_FILE" -A "${KEY_ALIAS:?给了 KEYSTORE_FILE 就要给 KEY_ALIAS}" \
             -P "${KEYSTORE_PASSWORD:?给了 KEYSTORE_FILE 就要给 KEYSTORE_PASSWORD}" \
             -S "${KEY_PASSWORD:-$KEYSTORE_PASSWORD}")
  log "签名：$KEYSTORE_FILE"
else
  KS="$OUT_DIR/remix-signing.jks"
  PWF="$OUT_DIR/remix-signing.txt"
  need_cmd keytool || die "缺少 keytool（JDK 自带），或手动提供 KEYSTORE_FILE"
  if [[ ! -f "$KS" ]]; then
    # 注意别用 head -c 截断：上游进程会收 SIGPIPE，配合 pipefail 会直接把脚本带崩
    PW="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
    log "生成临时签名：$KS"
    keytool -genkeypair -alias remix -keyalg RSA -keysize 2048 -validity 10000 \
      -storetype PKCS12 -keystore "$KS" \
      -storepass "$PW" -keypass "$PW" \
      -dname "CN=ksu-remix, O=ksu-remix, C=CN" >/dev/null 2>&1 \
      || die "生成 keystore 失败"
    printf 'keystore=%s\nalias=remix\npassword=%s\n' "$KS" "$PW" >"$PWF"
    chmod 600 "$PWF" 2>/dev/null || true
  fi
  PW="$(grep '^password=' "$PWF" | cut -d= -f2-)"
  SIGN_ARGS=(-K "$KS" -A remix -P "$PW" -S "$PW")
  warn "用的是自动生成的签名（$KS）"
  warn "它和官方 rue 的签名不同：装了官方版必须先卸载，之后也只能用这个签名覆盖升级"
fi

# ---- strip：需要 NDK 里的 llvm-strip ----
STRIP_ARGS=()
if [[ "${APK_STRIP:-1}" == "1" ]]; then
  if NDK_DIR="$(find_ndk)"; then
    STRIP_BIN="$(ls -1 "$NDK_DIR"/toolchains/llvm/prebuilt/*/bin/llvm-strip 2>/dev/null | head -1 || true)"
  fi
  if [[ -n "${STRIP_BIN:-}" ]]; then
    STRIP_ARGS=(--strip)
    log "裁剪符号：$STRIP_BIN"
  else
    warn "找不到 llvm-strip，跳过 --strip（APK 会大几 MB，功能无影响）"
  fi
fi

ARCH_ARGS=()
for abi in "${ARCHES[@]}"; do
  abi="$(echo "$abi" | tr -d '[:space:]')"
  [[ -n "$abi" ]] && ARCH_ARGS+=(-a "$abi")
done

# repack 内部要 zipalign + apksigner（重签和对齐），都在 build-tools 里，
# 只装 platform-tools 是不够的，这里提前说清楚，别等跑到一半才报错。
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
for tool in zipalign apksigner; do
  if need_cmd "$tool"; then continue; fi
  if [[ -n "$SDK_ROOT" ]] && compgen -G "$SDK_ROOT/build-tools/*/$tool*" >/dev/null; then continue; fi
  die "缺少 $tool（Android SDK build-tools）。装法：sdkmanager --install \"build-tools;36.1.0\""
done

log "重打包：${ARCH_ARGS[*]}"
( cd "$KSU_DIR" && python3 repack_apk_multi.py repack \
    -b "$BUILD_TYPE" -t "$BUILD_TYPE" \
    "${ARCH_ARGS[@]}" "${SIGN_ARGS[@]}" "${STRIP_ARGS[@]}" )

# ---- 校验：ksud 真的在包里 ----
OUT_APK="$(ls -1t "$KSU_DIR/dist"/*.apk 2>/dev/null | head -1 || true)"
[[ -n "$OUT_APK" ]] || die "repack 未在 $KSU_DIR/dist 产出 apk"

need_cmd unzip || die "缺少 unzip，无法校验产物"
LIST="$(unzip -l "$OUT_APK")"
for abi in "${ARCHES[@]}"; do
  abi="$(echo "$abi" | tr -d '[:space:]')"
  [[ -n "$abi" ]] || continue
  grep -q "lib/$abi/libksud.so" <<<"$LIST" \
    || die "产物里没有 lib/$abi/libksud.so，注入失败"
  log "ok  含 lib/$abi/libksud.so"
done

mkdir -p "$OUT_DIR/apk"
FINAL="$OUT_DIR/apk/$(basename "$OUT_APK")"
cp -f "$OUT_APK" "$FINAL"

log "最终 APK：$FINAL"
printf '  大小   %s\n' "$(du -h "$FINAL" | cut -f1)"
printf '  sha256 %s\n' "$(sha256sum "$FINAL" | cut -d' ' -f1)"
if need_cmd apksigner; then
  apksigner verify --print-certs "$FINAL" 2>/dev/null | head -3 || warn "apksigner 校验未通过"
else
  warn "没有 apksigner，跳过签名校验（用 keytool 也能查：apksigner 在 build-tools 里）"
fi
