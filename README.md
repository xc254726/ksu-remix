# ksu-remix

KernelSU 二改构建工程：**面向"原版 KowSU 装上去显示未安装 / 拿不到 root"的 GKI 设备**，产出自编译内核 + 管理器 APK + 可刷入包。

> 本项目只做"构建与集成自动化"，内核代码来自各厂商公开源码，KernelSU 代码来自其上游仓库。
> 全部按 GPL-2.0 / GPL-3.0 分发，二改发布时必须保留版权声明与许可证。

---

## 它解决什么问题

原版 KernelSU / KowSU 在下列内核上拿不到 root：

| 失败原因 | 原版表现 | 本项目的处理 |
|---|---|---|
| 内核里没有 KSU 代码（只装了 APK） | 管理器显示"未安装" | 二改内核对 `CONFIG_KSU=y` 或 `CONFIG_KSU=m` 强制开启 |
| kprobe 被厂商裁剪 / 符号被改 | 加载后无反应，或直接 panic | 提供 syscall 直插（manual hook）兜底路径 |
| `.ko` 的 vermagic 与内核不匹配 | `insmod` 报 `invalid module format` | 锁定 `CONFIG_LOCALVERSION` 精确复刻内核版本串，含页大小后缀 |
| 页大小不符（4k / 16k） | 刷入即不开机 | `PAGE_SIZE` 参与构建，编译期强制校验 |
| vendor 模块符号 CRC 不匹配 | 能开机但无触控/无声音 | `CONFIG_MODVERSIONS` 可控，配套 `modules.load` 对表 |

**核心差异点**：原版只给一条路（kprobe），二改给两条（kprobe + manual hook），并在构建期就把版本串钉死，而不是让你去"撞"一个刚好匹配的成品包。

---

## 产物

| 文件 | 说明 |
|---|---|
| `Image.lz4` / `Image.gz` | 编译出的内核镜像 |
| `boot-<release>.img` | 用你的原厂 `boot.img` 重打包、已含 KSU 的引导镜像 |
| `KernelSU-remix-<ver>.apk` | 二改管理器（与内核版本必须配套） |
| `kernelsu.ko` | LKM 模式产物（`KSU_MODE=module` 时） |

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
# KernelSU 二改源
KSU_REPO="https://github.com/KOWX712/KernelSU"
KSU_REF="master"
# builtin：KSU 编进内核；module：编成 kernelsu.ko
KSU_MODE="builtin"
# 需要重打包时提供原厂 boot.img
STOCK_BOOT="/path/to/stock-boot.img"
```

### 2. 本地构建

Linux 环境，装好 `git make clang lld llvm bc bison flex libssl-dev`：

```bash
make fetch      # 拉内核源码 + 集成 KSU
make config     # 套用二改配置（含版本串锁定）
make kernel     # 编译
make pack       # 重打包 boot.img
```

产物落在 `out/`。

### 3. 云端构建（推荐）

推到 GitHub，在 **Actions → build → Run workflow** 填参数即可。CI 会把 `boot-*.img`、APK、`.ko` 作为 artifact 和 Release 附件发出。

矩阵构建时一次出多个 KMI × 页大小组合，适合做成对外发布的改版包。

---

## 关键机制

### 版本串锁定

`uname -r` 的完整字符串（例如 `6.6.66-android15-8-gd43086512890-abogki423825152-4k`）会被拆成两部分：

- `6.6.66` → 必须与源码 `Makefile` 的 `VERSION.PATCHLEVEL.SUBLEVEL` 完全一致，否则脚本直接报错退出（这是源码版本错配的早期信号，别硬编）
- `-android15-8-gd43086512890-abogki423825152-4k` → 原样写入 `CONFIG_LOCALVERSION`，同时关掉 `CONFIG_LOCALVERSION_AUTO`

这样编出来的内核 vermagic 与设备上运行的内核逐字符相同，vendor 模块的 `vermagic` 校验才能通过。

### 页大小

`-4k` 后缀 → `CONFIG_ARM64_4K_PAGES=y`；`-16k` → `CONFIG_ARM64_16K_PAGES=y`。脚本从版本串自动推导，也可用 `PAGE_SIZE` 强制覆盖。

### manual hook 兜底

`config/ksu-manual.fragment` 对应的补丁在 `patches/manual-hook/`。当目标内核的 kprobe 不可用时，构建脚本会按 `HOOK_MODE=manual` 自动打入 `fs/exec.c`、`fs/open.c`、`fs/read_write.c`、`fs/stat.c`、`drivers/input/input.c` 五个接管点。

---

## 目录结构

```
config/          kconfig fragment（KSU 开关、版本串、页大小、MODVERSIONS）
patches/         manual hook 补丁
scripts/         fetch / config / build / pack
.github/         CI 工作流（矩阵构建 + 发布）
docs/            原理说明、风险与合规
```

---

## 风险声明

内核级改动一旦出错会直接变砖。发布前请：

1. 确认目标设备 **Bootloader 已解锁**（否则任何镜像都刷不进去）
2. 保留原厂 `boot.img`，随时能回刷
3. 先在真机上验证 `Image` 能开机、硬件正常，再谈 root
4. 对外发布时标注清楚"仅限 XX 内核版本"，版本串不一致的机器不要刷

详见 `docs/RISKS.md`。
