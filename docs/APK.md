# 管理器 APK 构建

内核和 APK 是一套东西，不能混搭：管理器通过 `ksud` 与内核侧 KSU 通信，协议、模块格式、
LKM late-load 都跟内核里的 KSU 版本绑定。用官方 APK 配自编内核，典型症状是"显示已安装，
但装模块失败 / late-load 无效"。所以本项目自己出 APK。

## 三段式流程

gradle 只编 Java/Kotlin 和 `app/src/main/cpp` 里的 C/C++，**不产 `libksud.so`**。
所以 APK 要分三步：

| 步骤 | 命令 | 产物 | 依赖 |
|---|---|---|---|
| 1. 编 APK | `make manager` | `manager/app/build/outputs/apk/<type>/*.apk`（无 ksud） | JDK 21 + Android SDK + NDK |
| 2. 编 ksud | `make ksud` | `target/<triple>/release/ksud` | Rust nightly + cargo-ndk + NDK |
| 3. 注入重签 | `bash scripts/pack-apk.sh` | `dist/*.apk` → 汇总到 `out/apk/` | python3 + keytool |

一步到位：`make apk`（= manager + ksud + pack）。

第 3 步调的是二改源自带的 `repack_apk_multi.py`，它把 `ksud` 改名成 `lib/<abi>/libksud.so`
塞进 APK，并删掉旧 ABI 的残留，最后重签。

## 前置条件

| 项 | 版本 | 说明 |
|---|---|---|
| JDK | **21** | AGP 9.4.1 要求，JDK 17 会直接报错 |
| Android SDK | compileSdk 37 / buildTools 36.1.0 | AGP 会自动下载，也可预先 `sdkmanager --install` |
| NDK | `30.0.16248370` | 与二改源 `manager/gradle/libs.versions.toml` 的 `ndk` 一致；少了会在 `ndkVersion` 处报错 |
| Rust | nightly + `rust-src` | `cargo-ndk` 要用 `-Z` 不稳定参数 |
| cargo-ndk | 最新 | `cargo install cargo-ndk --locked` |
| python3 | 3.8+ | 跑 repack 脚本 |

环境变量：`ANDROID_HOME`（或 `ANDROID_SDK_ROOT`）+ `ANDROID_NDK_HOME`。
`find_ndk` 会自动从常见 SDK 目录挑版本号最大的 NDK，挑不到才报错。

## 版本号为什么会算错

二改源 `manager/build.gradle.kts` 里：

```kotlin
extra["managerVersionCode"] = 30000 + getGitCommitCount() + 700   // git rev-list --count HEAD
extra["managerVersionName"] = getGitDescribe()                     // git describe --tags --always
```

**versionCode 依赖完整提交历史**。浅克隆（`--depth=1`）会让提交数变成 1，versionCode 变成
30701，比官方版本小得多 → 覆盖安装会被系统拒绝。

本项目克隆二改源时不加 `--depth`，改用 `--filter=blob:none`（保留历史，只省 blob 流量）。
`scripts/build-manager.sh` 还会检查提交数，小于 100 就自动 `git fetch --unshallow`。
想关掉：`MANAGER_DEEPEN=0`。

## 签名

| 情况 | 结果 |
|---|---|
| 设了 `KEYSTORE_FILE` + `KEY_ALIAS` + `KEYSTORE_PASSWORD` | 用你的签名，适合对外发布 |
| 没设 | `pack-apk.sh` 生成临时 PKCS12：`out/remix-signing.jks`，密码写 `out/remix-signing.txt` |

**签名不同装不上**：系统只认同签名的升级。换成自己的签名后，必须先卸载官方 rue
（卸载会丢模块列表和已授权应用），或者用官方签名私钥。

## ABI

默认只出 `arm64-v8a`（这也就是真机需要的那个）。要全 ABI：

```bash
KSUD_ARCHES="arm64-v8a,armeabi-v7a,x86_64" make apk
```

`riscv64` 没接：上游走的是另一套流程（`setup-rust-build.sh` + 自定义 cargo config），
脚本会明确报错而不是静默出错。

因为 gradle 侧 `abiFilters` 四个 ABI 都开，未注入的 ABI 会留下空的 `lib/<abi>/`。
不影响 arm64 设备安装，但包体会偏大。

## 产物校验

`pack-apk.sh` 结束时会做两件事，任一条不过就 fail：

1. `unzip -l` 里必须出现 `lib/<abi>/libksud.so`（证明注入成功）
2. 有 `apksigner` 就 `--print-certs` 验签

最终产物在 `out/apk/`，同时打印 sha256。

## 装机顺序

1. 先解决内核侧：刷 `boot-<release>.img`，或 LKM 模式装 `kernelsu.ko`
2. 再装 APK
3. 打开管理器 —— 显示"工作中"才算成功；显示"未安装"说明内核侧没生效，**跟 APK 无关**
4. 签名与已装版本不同 → 先卸载旧管理器

## 常见失败

| 现象 | 原因 | 处理 |
|---|---|---|
| `gradlew: Permission denied` | 克隆到 Windows 后丢了可执行位 | `chmod +x manager/gradlew` |
| `Android Gradle plugin requires Java 21` | JDK 版本低 | 装 JDK 21，`JAVA_HOME` 指过去 |
| `NDK not found` / `ndkVersion` 报错 | NDK 缺失或版本不符 | 装 `ndk;30.0.16248370`，设 `ANDROID_NDK_HOME` |
| `-Z build-std-features requires -Z build-std` | cargo 版本收紧 | 脚本已自动补 `-Z build-std=std,panic_abort` 重试 |
| versionCode 只有 3 万多 | 浅克隆 | 让脚本 `--unshallow`，或手动 `git fetch --unshallow` |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 签名与已装版本不同 | 先卸载旧 APK |
| 装好后仍显示"未安装" | 内核里没有 KSU | 回到内核侧，不是 APK 问题 |
