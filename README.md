# ksu-remix

KernelSU 二改构建工程：**面向"原版发行版装上去显示未安装 / 拿不到 root"的 GKI 设备**，产出自编译内核 + 管理器 APK + 可刷入包。

二改基座默认 **sbsu**（`xc254726/sbsu`，BakaSU 派生，管理器已 rebrand 为 `rue` / `com.rue.manager`），跟 `main`。

> 本项目只做"构建与集成自动化"。内核代码来自各厂商公开源码，KernelSU 代码来自其上游仓库。
> 全部按 GPL-2.0 / GPL-3.0 分发，二改发布时必须保留版权声明与许可证（见 `NOTICE.md`）。

---

## 它解决什么问题

原版发行版在下列内核上拿不到 root：

| 失败原因 | 表现 | 本项目的处理 |
|---|---|---|
| 内核里没有 KSU 代码（只装了 APK） | 管理器显示"未安装" | 构建期强制 `CONFIG_KSU=y`（或 `=m` 走 LKM） |
| 挂钩方式与内核不兼容 | 显示已安装但授权无效 / panic | 基座走 tracepoint / LSM，另有 manual hook 兜底 |
| `.ko` 的 vermagic 与内核不匹配 | `insmod` 报 `invalid module format` | 锁定 `CONFIG_LOCALVERSION` 逐字符复刻内核版本串，含页大小后缀 |
| 页大小不符（4k / 16k） | 刷入即不开机 | `PAGE_SIZE` 参与构建，编译期强制校验 |
| vendor 模块符号 CRC 不匹配 | 能开机但无触控/无声音 | `CONFIG_MODVERSIONS` 可控，配套 `modules.load` 对表 |

**核心差异**：发行版只提供"刷按 KMI 分档的预编译镜像"这一条路，而厂商内核的版本串是逐字符唯一的；本项目从源码重建，把版本串、页大小、挂钩方式全部按目标机对齐。

---

## 二改基座

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/xc254726/sbsu |
| 分支 | `main`（2026-11-21 最新 `522e53b9`） |
| 上游 | BakaSU → `Baka-SU/BakaSU`（其 `kernel/setup.sh` 里 clone 的仍是 BakaSU） |
| 许可 | `kernel/` GPL-2.0-only；其余 GPL-3.0 |

挂钩方式是 `kernel/Kconfig` 里的一个 **choice，三选一**：

| 选项 | 对应 `HOOK_MODE` | 适用 |
|---|---|---|
| `CONFIG_KSU_TRACEPOINT_HOOK` | `upstream`（默认） | GKI 2.0 / 5.10+，官方路径 |
| `CONFIG_KSU_MANUAL_HOOK` | `manual` | 内核裁掉 tracepoint；兼容到 3.4 |
| `CONFIG_KSU_SUSFS` | `susfs` | 需要 SUSFS 隐藏能力（依赖 `THREAD_INFO_IN_TASK && 64BIT`） |

三选一意味着**必须恰好命中一个**。一个都没生效时，即使 `CONFIG_KSU=y` 也没有挂钩实现，
照样拿不到 root —— `scripts/config.sh` 会在 `olddefconfig` 之后强制校验这一点。

挂钩实现在 `kernel/hook/`：`lsm_hooks.c`（LSM）、`syscall_hook_manager.c`（syscall redirect）、
`tp_marker.c`（tracepoint）。没有 `CONFIG_KSU_KPROBES_HOOK` —— 那是 SukiSU/KowSU 的选项，填了也无效。

换基座只需改 `.env` 里的 `KSU_REPO` / `KSU_REF`。注意：`sbsu` 的 `kernel/setup.sh` **仍然硬编码
`git clone https://github.com/Baka-SU/BakaSU`**（它没把这个继承来的地址改掉），跑下去会把上游 BakaSU
当基座、并自行 `git checkout main`，你的 rebrand 和 `KSU_REF` 全被覆盖。
**因此本项目不调用它**，而是自己完成 symlink + `drivers/Makefile` + `drivers/Kconfig` 三步集成（见 `scripts/fetch.sh`）。

---

## 产物

| 文件 | 说明 |
|---|---|
| `Image` / `Image.gz` / `Image.lz4` | 编译出的内核镜像 |
| `boot-<release>.img` | 用原厂 `boot.img` 重打包、已含 KSU 的引导镜像 |
| `kernelsu.ko` | LKM 模式产物（`KSU_MODE=module` 时） |
| `out/apk/*.apk` | 管理器 APK，已注入配套 `ksud` 并重签（见 `docs/APK.md`） |

---

## 快速开始

### 1. 准备参数

```bash
cp .env.example .env
$EDITOR .env
```

必填项：

```bash
# 目标设备真正的内核版本串，取自设备上的 `uname -r`
KERNEL_RELEASE="6.6.66-android15-8-gd43086512890-abogki423825152-4k"
# 内核源码
KERNEL_REPO="https://github.com/realme-kernel-opensource/realme-cn_gt7-AndroidV-kernel-source"
KERNEL_REF="master"
DEFCONFIG="gki_defconfig"
# 二改基座（默认 sbsu，跟 main）
KSU_REPO="https://github.com/xc254726/sbsu"
KSU_REF="main"
# builtin：KSU 编进内核；module：编成 kernelsu.ko
KSU_MODE="builtin"
# upstream：用基座自带 hook；manual：额外插 syscall 接管点
HOOK_MODE="upstream"
# 需要重打包时提供原厂 boot.img
STOCK_BOOT="/path/to/stock-boot.img"
```

### 2. 本地构建

Linux 环境，装好 `git make clang lld llvm bc bison flex libssl-dev`：

```bash
make doctor     # 环境体检 + 版本串拆解
make fetch      # 拉内核源码 + 集成 KSU
make config     # 套用二改配置（含版本串锁定）
make kernel     # 编译并校验 vermagic
make pack       # 重打包 boot.img
```

产物落在 `out/`。

### 3. 出管理器 APK

APK 必须跟内核配套，所以也自己编。除了上面的内核工具链，还需要 **JDK 21**、
**Android SDK（compileSdk 37 / buildTools 36.1.0）**、**NDK 30.0.16248370**、
**Rust nightly + cargo-ndk**。

```bash
make ksud      # 编 Rust 版 ksud（APK 里 libksud.so 的来源）
make manager   # 编 rue 管理器 APK（此时还没有 ksud）
make apk       # = manager + ksud + 注入重签，出最终 APK
```

最终 APK 在 `out/apk/`，脚本会 `unzip -l` 校验 `lib/<abi>/libksud.so` 确实在包里。
默认只出 `arm64-v8a`，要其他 ABI：`KSUD_ARCHES="arm64-v8a,x86_64" make apk`。

没给签名会**自动生成临时签名**（`out/remix-signing.jks`）。它和官方 rue 的签名不同，
装了官方版必须先卸载。细节与常见报错见 **[docs/APK.md](docs/APK.md)**。

### 4. 云端构建（推荐）

推到 GitHub，在 **Actions → build → Run workflow** 填参数即可。两个 job 可独立开关：

- `build_kernel` → 出内核 / `boot.img`
- `build_apk` → 出管理器 APK（自动装 JDK 21 + NDK + Rust，编 ksud 再注入）

> 工作流文件位于 `ci/build.yml`。因 gh token 缺 `workflow` scope，尚未移入 `.github/workflows/`，
> 启用方式见 `ci/README.md`。

---

## 关键机制

### 版本串锁定

`uname -r` 的完整字符串（例如 `6.6.66-android15-8-gd43086512890-abogki423825152-4k`）被拆成两部分：

- `6.6.66` → 必须与源码 `Makefile` 的 `VERSION.PATCHLEVEL.SUBLEVEL` 一致，否则告警（`STRICT_VERSION=1` 时直接中止）
- `-android15-8-gd43086512890-abogki423825152-4k` → 原样写入 `CONFIG_LOCALVERSION`，并关掉 `CONFIG_LOCALVERSION_AUTO`

编完后 `scripts/build.sh` 读 `include/config/kernel.release` 与目标逐字符比对，不一致即 fail——
这一步卡住的是"编出来了但刷上去掉触控/没声音"这类隐性故障。

### 页大小

`-4k` → `CONFIG_ARM64_4K_PAGES=y`；`-16k` → `CONFIG_ARM64_16K_PAGES=y`。从版本串自动推导，可用 `PAGE_SIZE` 覆盖。

### manual hook 兜底

`HOOK_MODE=manual` 时，`scripts/gen-manual-hook.sh` 先扫描内核树定位五个接管点并出报告
（`patches/manual-hook/REPORT.md`），模板见 `patches/manual-hook/README.md`。

**默认不要开**：基座自带的 Tracepoint / LSM 挂钩已经能覆盖绝大多数 GKI 2.0 内核，
重复挂钩会引起重复处理甚至 panic。

---

## 目录结构

```
config/          kconfig fragment（KSU 开关、输入子系统、版本串/页大小占位）
patches/         manual hook 接管点模板与报告
scripts/         fetch / config / build / pack / build-ksud / build-manager / pack-apk
ci/              GitHub Actions 工作流源文件
docs/            原理说明（WHY / APK / RISKS）与合规
```

---

## 风险声明

内核级改动一旦出错会直接变砖。发布前请：

1. 确认目标设备 **Bootloader 已解锁**（否则任何镜像都刷不进去）
2. 保留原厂 `boot.img`，随时能回刷
3. 先在真机上验证能开机、硬件正常，再谈 root
4. 对外发布时标注清楚"仅限 XX 内核版本"，版本串不一致的机器不要刷

详见 `docs/RISKS.md`。
