# 为什么原版显示"未安装"，二改版能做到

## 一、root 权限的真正来源

KernelSU 的权限模型是：内核里跑着一段代码，拦截特定系统调用（`execve`、`open`、`stat`、`read`），
当检测到"受信任的进程请求 su"时，就在内核态把该进程的凭据提升为 root。

管理器 APK 不提供 root，它只做两件事：

1. 通过一个字符设备 / 特殊 ioctl 与内核里的那段代码通信
2. 展示授权界面，把用户的选择写进内核

所以 **只装 APK 必然显示"未安装"**——内核里没有可供通信的一端。这不是 bug，是设计。

判断链：

```
管理器显示"未安装"
        │
        ├── 内核里没有 KSU 代码 ────────────► 必须刷入含 KSU 的内核（本项目）
        ├── 有 KSU 但版本串不匹配 ──────────► 重编 / 换匹配的 .ko（本项目）
        └── 有 KSU 但管理器签名不同 ────────► 换配套的 APK（本项目产物）
```

## 二、原版在什么内核上会哑火

KernelSU 的挂钩方式经历了三代：

| 代际 | 方式 | 失效条件 |
|---|---|---|
| 早期 | 直接改系统调用表 | 内核开了只读 syscall table |
| 主流 | kprobe 动态插桩 | 内核裁剪 kprobe、`CONFIG_KPROBES=n`、或厂商魔改了被插桩的函数 |
| 较新 | tracepoint / LSM hook | 内核把对应 tracepoint 裁掉，或 LSM 钩子链被厂商重排 |
| 兜底 | 手工在源码里插入调用点（manual hook） | 需要能编内核 |

BakaSU v4.2.0 采用的是 **LSM hook（`kernel/hook/lsm_hooks.c`）+ syscall redirect
（`syscall_hook_manager.c`）+ tracepoint marker** 的组合，比单纯依赖 kprobe 的内核
更容易在厂商裁剪过的 GKI 内核上挂住。它同时保留 Manual Hook 与 SUSFS Inline Hook
两条可选路径，都在基座内部实现，不需要外部 kconfig 开关。

原版给终端用户只提供"刷预编译镜像"这一条路，而这些镜像按 **GKI KMI + 页大小** 分档，
并不会针对某一台设备的厂商内核做适配。厂商（尤其是联发科平台）常在 GKI 基础上改符号、
加自己的 LSM 钩子、裁掉调试特性，于是预编译镜像要么 `vermagic` 不匹配、要么 kprobe 挂不上。

**结果就是你看到的现象：装得上、显示未安装、怎么弄都没 root。**

## 三、二改版的两条差异

### 差异一：挂钩策略不只有一种

BakaSU 内置三种模式，编译进内核后按内核能力生效：

| 模式 | 原理 | 适用 |
|---|---|---|
| Tracepoint Syscall Redirect | 在 tracepoint 处重定向 syscall，默认模式 | GKI 2.0（5.10+），arm64 / x86_64 |
| Manual Hook | 直接在源码插入调用点，兼容到 3.4~6.18 | 内核裁掉 tracepoint 时 |
| SUSFS Inline Hook | 由 SUSFS 提供的 inline 挂钩 | 需要 SUSFS 隐藏能力时 |

本项目的 `HOOK_MODE` 只控制**是否再额外注入一层自己的 syscall 接管点**：

- `upstream`（默认）：完全用基座自带实现，不要重复挂钩
- `manual`：基座挂不上时叠加，接管点如下

| 文件 | 函数 | 作用 |
|---|---|---|
| `fs/exec.c` | `do_execveat_common` | 拦截 `execve`，实现 `su` 命令替换 |
| `fs/open.c` | `do_faccessat` | 拦截 `access`，处理权限探测 |
| `fs/read_write.c` | `vfs_read` | 拦截读，用于隐藏与重定向 |
| `fs/stat.c` | `vfs_statx` / `vfs_fstatat` | 拦截 `stat`，处理路径伪装 |
| `drivers/input/input.c` | `input_handle_event` | 音量键触发的安全模式 |

两套同时生效会重复处理同一次系统调用，轻则行为异常，重则 panic，所以默认关闭。

### 差异二：版本串被钉死

`vermagic` 是内核在 `include/generated/utsrelease.h` 里写死的一串版本标识，
内核模块在 `insmod` 时会被逐一比对，差一个字符就 `invalid module format`。

厂商内核的版本串通常长这样：

```
6.6.66 - android15-8 - gd43086512890 - abogki423825152 - 4k
└─┬──┘   └────┬────┘   └─────┬──────┘   └──────┬──────┘   └┬┘
 基础版本   KMI 版本      源码提交哈希       厂商编译号     页大小
```

其中 `gd43086512890` 是厂商构建时那次提交的哈希，`abogki423825152` 是联发科 GKI 的编译流水号。
这两个字段**不可能靠"猜"或"随便找个包"对上**，只能从设备 `uname -r` 抄下来写进 `CONFIG_LOCALVERSION`。

这就是为什么"别人发的成品包"在你机器上必然失败——它签的是别人的版本串。

## 四、代价

- 必须能拿到目标设备的公开内核源码；不开源的内核无法用这条路
- 源码版本必须与设备上的内核版本对齐；厂商只同步到某个固件版本时，超前的系统版本无解
- 编译一次几十分钟到数小时，需要 CI 或一台够用的 Linux 机器
- 刷入有变砖风险，必须保留原厂镜像
