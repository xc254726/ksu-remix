#!/usr/bin/env bash
# 编译 rue 管理器 APK（gradle）
#
# 只出「没有 ksud 的 APK」——lib/<abi>/libksud.so 由 scripts/pack-apk.sh 注入。
# 要能装模块/加载 LKM，必须再跑一次 pack-apk.sh（或 make apk 一步到位）。
#
# 用法: ./scripts/build-manager.sh [release|debug]
# 可选环境变量:
#   KSU_PACKAGE_NAME  覆盖 applicationId（默认 com.rue.manager）
#   KSU_NAME          覆盖应用显示名（默认 rue）
#   KEYSTORE_FILE     签名用 keystore 路径（不填则产出未签名 APK）
#   KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD
#   GRADLE_ARGS       追加给 gradlew 的参数
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env_soft

BUILD_TYPE="${1:-$APK_BUILD_TYPE}"
case "$BUILD_TYPE" in
  release) TASK="assembleRelease" ;;
  debug)   TASK="assembleDebug" ;;
  *) die "构建类型只能是 release 或 debug，收到：$BUILD_TYPE" ;;
esac

ensure_ksu_dir
MANAGER_DIR="$KSU_DIR/manager"
[[ -f "$MANAGER_DIR/gradlew" ]] || die "找不到 $MANAGER_DIR/gradlew，二改源结构不对"

# ---- JDK：AGP 9.x 要求 17+，上游 CI 用 21，这里按 21 卡 ----
JDK="$(java_major || true)"
if [[ -z "$JDK" ]]; then
  die "找不到 java。装 JDK 21 并设好 JAVA_HOME"
fi
if (( JDK < 21 )); then
  die "当前 JDK 主版本是 $JDK，AGP 9.4 需要 21。装 JDK 21 后重试（不要用 JDK 17）"
fi
log "JDK: $JDK"

# ---- 版本号依赖完整提交历史 ----
# manager/build.gradle.kts: versionCode = 30000 + git rev-list --count HEAD + 700
COUNT="$(git -C "$KSU_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
if (( COUNT < 100 )); then
  warn "二改源只有 $COUNT 个提交，像是浅克隆 → versionCode 会算错（可能导致无法覆盖安装）"
  if [[ "${MANAGER_DEEPEN:-1}" == "1" ]]; then
    log "补全提交历史（--unshallow）"
    git -C "$KSU_DIR" fetch --unshallow --filter=blob:none 2>/dev/null \
      || git -C "$KSU_DIR" fetch --unshallow 2>/dev/null \
      || warn "补历史失败，继续用当前历史编译"
    COUNT="$(git -C "$KSU_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
    log "提交数：$COUNT"
  fi
fi

SHA="$(git -C "$KSU_DIR" rev-parse HEAD)"

# ---- Android SDK：只在缺 local.properties 且环境里有 SDK 时补 ----
if [[ ! -f "$MANAGER_DIR/local.properties" ]]; then
  SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [[ -n "$SDK" && -d "$SDK" ]]; then
    printf 'sdk.dir=%s\n' "$SDK" >"$MANAGER_DIR/local.properties"
    log "写入 local.properties: sdk.dir=$SDK"
  else
    warn "未设置 ANDROID_HOME / ANDROID_SDK_ROOT，交给 gradle 自行查找 SDK"
  fi
fi

# ---- 签名配置：清了再写，避免重复运行时键值叠加 ----
PROPS="$MANAGER_DIR/gradle.properties"
sed -i.bak -E '/^KEY_/d; /^KEYSTORE_/d' "$PROPS" 2>/dev/null || true
rm -f "$PROPS.bak"
if [[ -n "${KEYSTORE_FILE:-}" ]]; then
  [[ -f "$KEYSTORE_FILE" ]] || die "KEYSTORE_FILE 指向的文件不存在：$KEYSTORE_FILE"
  [[ -n "${KEY_ALIAS:-}" && -n "${KEYSTORE_PASSWORD:-}" ]] || die "给了 KEYSTORE_FILE 就必须同时给 KEY_ALIAS / KEYSTORE_PASSWORD"
  {
    echo "KEYSTORE_FILE=$KEYSTORE_FILE"
    echo "KEYSTORE_PASSWORD=$KEYSTORE_PASSWORD"
    echo "KEY_ALIAS=$KEY_ALIAS"
    echo "KEY_PASSWORD=${KEY_PASSWORD:-$KEYSTORE_PASSWORD}"
  } >>"$PROPS"
  log "已配置签名：$KEYSTORE_FILE（alias=$KEY_ALIAS）"
else
  warn "没有签名配置，将产出未签名 APK；装机前需要自己签（pack-apk.sh 会生成临时签名）"
fi

# ---- 编译 ----
# 从 Windows 克隆过来会丢可执行位，这里兜一下
GRADLE_CMD=(./gradlew)
if [[ ! -x "$MANAGER_DIR/gradlew" ]]; then
  chmod +x "$MANAGER_DIR/gradlew" 2>/dev/null || true
  [[ -x "$MANAGER_DIR/gradlew" ]] || GRADLE_CMD=(bash ./gradlew)
fi

GRADLE=("${GRADLE_CMD[@]}" "$TASK" "-Pcommit=$SHA")
[[ -n "${KSU_PACKAGE_NAME:-}" ]] && GRADLE+=("-PKSU_PACKAGE_NAME=$KSU_PACKAGE_NAME")
[[ -n "${KSU_NAME:-}"         ]] && GRADLE+=("-PKSU_NAME=$KSU_NAME")
# shellcheck disable=SC2206
[[ -n "${GRADLE_ARGS:-}"      ]] && GRADLE+=(${GRADLE_ARGS})

log "构建：${GRADLE[*]}"
log "（首次运行要下 gradle 9.8.0 + AGP 依赖 + NDK，几分钟到十几分钟属正常）"
( cd "$MANAGER_DIR" && "${GRADLE[@]}" )

APK_OUT="$MANAGER_DIR/app/build/outputs/apk/$BUILD_TYPE"
APK="$(ls -1t "$APK_OUT"/*.apk 2>/dev/null | head -1 || true)"
[[ -n "$APK" ]] || die "gradle 成功但 $APK_OUT 下没有 apk"

mkdir -p "$OUT_DIR/apk"
cp -f "$APK" "$OUT_DIR/apk/"
log "APK 产物：$APK"
printf '  版本名 %s\n' "$(basename "$APK")"
printf '  大小   %s\n' "$(du -h "$APK" | cut -f1)"
printf '  sha256 %s\n' "$(sha256sum "$APK" | cut -d' ' -f1)"
warn "此 APK 尚未注入 ksud，装机会缺模块管理能力；请继续 make apk"
