# manual hook 补丁说明

这里放的是**接管点模板**，不是可直接 `git apply` 的成品补丁。

原因：`do_execveat_common` / `do_faccessat` / `vfs_read` / `vfs_statx` 这四个函数的签名在
5.10、5.15、6.1、6.6 之间都改过（参数从 `struct filename *` 变成 `const struct filename *`、
`int flags` 变成 `unsigned int flags` 等）。写死一份 diff，套到别的树上必然冲突。

正确做法：先跑 `make fetch`（`HOOK_MODE=manual` 时会自动生成报告），拿到真实签名，再按下面模板改。

---

## 1. execve —— `fs/exec.c`

定位：`do_execveat_common`

```c
#ifdef CONFIG_KSU
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
                               void *argv, void *envp, int *flags);
#endif

static int do_execveat_common(int fd, struct filename *filename,
                              struct user_arg_ptr argv,
                              struct user_arg_ptr envp,
                              int flags)
{
#ifdef CONFIG_KSU
    ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
#endif
    return __do_execve_file(fd, filename, argv, envp, flags, NULL);
}
```

要点：`filename` 可能是 `const struct filename *`，那就把 `&filename` 转成 `(struct filename **)`，
或改用上游 KernelSU 在该版本树里已有的声明。

## 2. access —— `fs/open.c`

定位：`do_faccessat`

```c
#ifdef CONFIG_KSU
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
                                int *mode, int *flags);
#endif
...
long do_faccessat(int dfd, const char __user *filename, int mode, int flags)
{
#ifdef CONFIG_KSU
    ksu_handle_faccessat(&dfd, &filename, &mode, &flags);
#endif
```

6.6 里 `do_faccessat` 是四参数版本（多了 `flags`），5.10 及更早是三参数，按实际传。

## 3. read —— `fs/read_write.c`

定位：`vfs_read`

```c
#ifdef CONFIG_KSU
extern bool ksu_vfs_read_hook __read_mostly;
extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
                               size_t *count_ptr, loff_t **pos);
#endif
...
ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)
{
#ifdef CONFIG_KSU
    if (unlikely(ksu_vfs_read_hook))
        ksu_handle_vfs_read(&file, &buf, &count, &pos);
#endif
```

## 4. stat —— `fs/stat.c`

6.6 优先用 `vfs_statx`，没有则退回 `vfs_fstatat`：

```c
#ifdef CONFIG_KSU
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif
```

## 5. 安全模式 —— `drivers/input/input.c`

定位：`input_handle_event`，用于音量键进入安全模式（救 bootloop）。

```c
#ifdef CONFIG_KSU
extern bool ksu_input_hook __read_mostly;
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
#endif
...
#ifdef CONFIG_KSU
    if (unlikely(ksu_input_hook))
        ksu_handle_input_handle_event(&type, &code, &value);
#endif
```

---

## 验证清单

改完编译前先自查：

- [ ] 五处都加了 `#ifdef CONFIG_KSU`，关掉 KSU 时能正常编过
- [ ] 声明里的参数类型与函数实际签名逐字一致（尤其 `const` 与 `unsigned`）
- [ ] 没在 `unlikely()` 里放有副作用的表达式
- [ ] `HOOK_MODE=upstream` 时不打这些补丁，两套同时生效会重复处理
