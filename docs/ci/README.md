# 启用 GitHub Actions 自动构建

`build.yml` 是一份开箱即用的 CI 配置：推送即构建 macOS DMG + iOS 未签名 IPA，
打 `v*` tag 时自动发布到 Release。它放在 `docs/ci/` 而不是 `.github/workflows/`，
只是因为当前维护者用的令牌没有 `workflow` 权限。启用只需一步：

## 方式 A：网页端（10 秒）

1. 打开仓库 → **Add file → Create new file**；
2. 文件名填 `.github/workflows/build.yml`；
3. 把本目录 `build.yml` 的内容整段粘进去，提交。

## 方式 B：本地有 `workflow` 权限的令牌

```bash
mkdir -p .github/workflows
cp docs/ci/build.yml .github/workflows/build.yml
git add .github/workflows/build.yml && git commit -m "ci: enable build workflow" && git push
```

启用后，README 里可加回构建徽章：

```md
![build](https://img.shields.io/github/actions/workflow/status/jpruby0127/ClearPaper/build.yml?label=build)
```

## 它做什么

- `push` 到 `main` / `workflow_dispatch`：构建两端产物，上传为 Actions artifact；
- 推送 `v*` tag：额外用 `softprops/action-gh-release` 自动发 Release 并附上两个文件。

所有构建命令与 `scripts/build-all.sh` 一致，因此本地可通过：

```bash
./scripts/build-all.sh
```
