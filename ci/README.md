此为 GitHub Actions 工作流源文件。

因当前 gh token 缺少 `workflow` scope，无法经 API 提交到 `.github/workflows/`。
启用方式二选一：

1. 本地执行 `gh auth refresh -s workflow`，然后把本文件复制到 `.github/workflows/build.yml` 再推
2. 在网页端新建文件 `.github/workflows/build.yml`，内容直接粘贴本文件

两者的内容应逐字一致。
