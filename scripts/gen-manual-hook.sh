#!/usr/bin/env bash
# 扫描内核源码，定位 manual hook 的五个接管点，输出签名比对报告。
# 不自动改代码——不同内核树函数签名差异大，自动替换容易编出一堆错误。
source "$(dirname "$0")/lib.sh"
load_env 2>/dev/null || true

KD="${KERNEL_DIR:-$(cd "$(dirname "$0")/.." && pwd)/build/kernel}"
REP="$(cd "$(dirname "$0")/.." && pwd)/patches/manual-hook/REPORT.md"
mkdir -p "$(dirname "$REP")"

need() {
  local file="$1" pat="$2" label="$3"
  echo "## $label"
  echo
  echo "文件：\`$file\`"
  if [[ ! -f "$KD/$file" ]]; then
    echo; echo "**缺失**：该路径不存在，内核树结构与预期不同。"; echo; return
  fi
  local hits
  hits=$(grep -nE "$pat" "$KD/$file" | head -5 || true)
  if [[ -z "$hits" ]]; then
    echo; echo "**未找到匹配**：\`$pat\` 无命中，该内核可能已重构此函数。"; echo; return
  fi
  echo; echo '```'
  echo "$hits"
  echo '```'
  echo
}

{
  echo "# manual hook 接管点检查报告"
  echo
  echo "生成时间：$(date -Iseconds)"
  echo "内核树：\`$KD\`"
  echo
  echo "> 本报告只做定位与签名比对。补丁需按实际签名手工编写，模板见同目录 README。"
  echo
  need "fs/exec.c"        '^static int do_execveat_common|^int do_execveat_common|do_execveat_common\(' "execve 接管点"
  need "fs/open.c"        'do_faccessat\(' "access 接管点"
  need "fs/read_write.c"  '^ssize_t vfs_read\(|^ssize_t vfs_read ' "vfs_read 接管点"
  need "fs/stat.c"        'vfs_statx\(|vfs_fstatat\(' "stat 接管点"
  need "drivers/input/input.c" 'static void input_handle_event\(' "安全模式接管点"
  echo "---"
  echo
  echo "## 下一步"
  echo
  echo "1. 对照每个接管点的实际参数列表，确定插入代码里的变量名"
  echo "2. 在函数体开头插入 \`#ifdef CONFIG_KSU\` 保护块"
  echo "3. 若某个接管点可以闭环（例如已有 kprobe 可用），把 \`HOOK_MODE\` 切回 kprobe，不必全上"
} >"$REP"

log "报告已写入 $REP"
cat "$REP"
