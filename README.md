# ksu-remix

KernelSU 二改构建工程：**面向"原版发行版装上去显示未安装 / 拿不到 root"的 GKI 设备**，产出自编译内核 + 管理器 APK + 可刷入包。

二改基座默认 **BakaSU**（`Baka-SU/BakaSU`，原 ReSukiSU），版本 `v4.2.0-rc3`（最新测试版）。

> 本项目只做"构建与集成自动化"。内核代码来自各厂商公开源码，KernelSU 代码来自其上游仓库。
> 全部按 GPL-2.0 / GPL-3.0 分发，二改发布时必须保留版权声明与许可证（见 `NOTICE.md`）。

---

## 它解决什么问题

原版发行版在下列内核上拿不到 root：

| 失败原因 | 表现 | 本项目的处理 |
|---|---|---|
| 内核里没有 KSU 代码（只装了 APK） | 管理器显示"未安装" | 构建期强制 `CONFIG_KSU=y`（或 `=m` 走 LKM） |
| 挂钩方式与内核不兼容 | 显示已安装但授权无效 / panic | 二改基座用 LSM hook + syscall redirect，另有 manual hook 兜底 |
| `.ko` 的 vermagic 与内核不匹配 | `insmod` 报 `invalid module format` | 锁定 `CONFIG_LOCALVERSION` 逐字符复刻内核版本串，含页大小后缀 |
| 页大小不符（4k / 16k） | 刷入即不开机 | `PAGE_SIZE` 参与构建，编译期强制校验 |
| vendor 模块符号 CRC 不匹配 | 能开机但无触控/无声音 | `CONFIG_MODVERSIONS` 可控，配套 `modules.load` 对表 |

**核心差异**：发行版只提供"刷按 KMI 分档的预编译镜像"这一条路，而厂商内核的版本串是逐字符唯一的；本项目从源码重建，把版本串、页大小、挂钩方式全部按目标机对齐。

---

## 二改基座

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/Baka-SU/BakaSU |
| 默认版本 | `v4.2.0-rc3`（2026-09-22，prerelease） |
| 比 tag 更新 | `main`（2026-11 仍在提交，属更前沿但未打标） |
| 许可 | `kernel/` GPL-2.0-only；其余 GPL-3.0-or-later；图标另有分层许可 |

BakaSU 的挂钩实现位于 `kernel/hook/`：`lsm_hooks.c`（LSM）、`syscall_hook_manager.c`（syscall redirect）、
`tp_marker.c`（tracepoint）。三种模式（Tracepoint Syscall Redirect / Manual Hook / SUSFS Inline Hook）
由基座自身决定，**不需要 `CONFIG_KSU_KPROBES_HOOK`** —— 那是 SukiSU/KowSU 的选项，填了也无效。

换基座只需改 `.env` 里的 `KSU_REPO` / `KSU_REF`。注意：上游 `kernel/setup.sh` 硬编码
`git clone ReSukiSU/ReSukiSU` 并自己 checkout `main`，会忽略 `KSU_REF`，**因此本项目不调用它**，
而是自己完成 symlink + `drivers/Makefile` + `drivers/Kconfig` 三步集成（见 `scripts/fetch.sh`）。

---

## 产物

| 文件 | 说明 |
|---|---|
| `Image` / `Image.gz` / `Image.lz4` | 编译出的内核镜像 |
| `boot-<release>.img` | 用原厂 `boot.img` 重打包、已含 KSU 的引导镜像 |
| `kernelsu.ko` | LKM 模式产物（`KSU_MODE=module` 时） |
| 管理器 APK | 由基座仓库的 `manager/` 构建，需与内核版本配套 |

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
# 二改基座（默认 BakaSU 最新测试版）
KSU_REPO="https://github.com/Baka-SU/BakaSU"
KSU_REF="v4.2.0-rc3"
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

### 3. 云端构建（推荐）

推到 GitHub，在 **Actions → build → Run workflow** 填参数即可。

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

**默认不要开**：BakaSU 自带 LSM + syscall redirect 已经能覆盖绝大多数 GKI 2.0 内核，
重复挂钩会引起重复处理甚至 panic。

---

## 目录结构

```
config/          kconfig fragment（KSU 开关、输入子系统、版本串/页大小占位）
patches/         manual hook 接管点模板与报告
scripts/         fetch / config / build / pack / doctor / gen-manual-hook
ci/              GitHub Actions 工作流源文件
docs/            原理说明、风险与合规
```

---

## 风险声明

内核级改动一旦出错会直接变砖。发布前请：

1. 确认目标设备 **Bootloader 已解锁**（否则任何镜像都刷不进去）
2. 保留原厂 `boot.img`，随时能回刷
3. 先在真机上验证能开机、硬件正常，再谈 root
4. 对外发布时标注清楚"仅限 XX 内核版本"，版本串不一致的机器不要刷

详见 `docs/RISKS.md`。
