#!/usr/bin/env python3
"""通过 GitHub API 提交（github.com:443 被阻断时的替代路径）。

注意：必须用相对 endpoint（不带前导斜杠）并设 MSYS_NO_PATHCONV=1，
否则 Git Bash 会把 /repos/... 重写成 Windows 路径，API 返回 404。
"""
import base64, json, os, subprocess, sys, tempfile

REPO = "xc254726/ksu-remix"
BRANCH = "main"

ENV = dict(os.environ, MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")

def gh(args, payload=None):
    if payload is not None:
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
        json.dump(payload, f)
        f.close()
        args = args + ["--input", f.name]
    r = subprocess.run(["gh", "api"] + args, capture_output=True, text=True, env=ENV)
    if r.returncode != 0:
        print("API ERROR:", r.stderr.strip(), file=sys.stderr)
        sys.exit(1)
    return json.loads(r.stdout or "{}")

files = subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.split()
if not files:
    sys.exit("没有可提交的文件")

def b64(path):
    return base64.b64encode(open(path, "rb").read()).decode()

# --- 确定基底 commit（空仓库需先初始化）---
refs = gh(["repos/%s/git/refs" % REPO])
if isinstance(refs, dict):
    refs = [refs]
match = [r for r in refs if r.get("ref") == "refs/heads/%s" % BRANCH]
if match:
    base_commit = match[0]["object"]["sha"]
    base_tree = gh(["repos/%s/git/commits/%s" % (REPO, base_commit)])["tree"]["sha"]
    print(f"已有分支，基于 {base_commit[:10]}")
else:
    print("初始化仓库…")
    init = gh(["--method", "PUT", "repos/%s/contents/README.md" % REPO],
              {"message": "chore: init", "content": b64("README.md")})
    base_commit = init["commit"]["sha"]
    base_tree = init["commit"]["tree"]["sha"]
    print(f"  初始 commit {base_commit[:10]}  tree {base_tree[:10]}")

# --- 全量 blob + 单次 commit ---
tree = []
for p in files:
    r = gh(["--method", "POST", "repos/%s/git/blobs" % REPO],
           {"content": b64(p), "encoding": "base64"})
    mode = "100755" if (p.startswith("scripts/") and p.endswith(".sh")) else "100644"
    tree.append({"path": p, "mode": mode, "type": "blob", "sha": r["sha"]})
    print(f"  blob {r['sha'][:10]}  {mode}  {p}")

tr = gh(["--method", "POST", "repos/%s/git/trees" % REPO],
        {"base_tree": base_tree, "tree": tree})
print(f"tree: {tr['sha']}")

msg = """feat: KernelSU 二改构建工程

面向原版显示未安装/拿不到 root 的 GKI 设备，提供：
- fetch/config/build/pack 全链路脚本，复用上游 setup.sh 集成内核
- CONFIG_LOCALVERSION 逐字符锁定目标内核版本串，自动推导 4k/16k 页大小
- 编译后校验 kernel.release 与目标一致，不符即 fail
- magiskboot 重打包原厂 boot.img
- manual hook 接管点定位报告（不提供跨版本冲突的成品 diff）
- GitHub Actions 参数化构建"""

cm = gh(["--method", "POST", "repos/%s/git/commits" % REPO],
        {"message": msg, "tree": tr["sha"], "parents": [base_commit]})
print(f"commit: {cm['sha']}")

gh(["--method", "PATCH", "repos/%s/git/refs/heads/%s" % (REPO, BRANCH)],
   {"sha": cm["sha"], "force": True})
print(f"ref refs/heads/{BRANCH} -> {cm['sha'][:10]}")
