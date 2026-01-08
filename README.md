# aur-auto-updater

这个仓库用于通过 GitHub Actions 自动更新并 push 到 AUR（支持一个仓库维护多个 AUR 包）。

## 工作方式（简述）

- 每 6 小时触发一次：按 `config/packages.json` 列表逐个更新 → 查询 GitHub Releases 最新版本 → 更新 `PKGBUILD`/校验和/`.SRCINFO` → commit → push 到 AUR。
- 如果上游版本没变，也会尝试刷新一次 `.SRCINFO`（用于修正 `.SRCINFO` 与 `PKGBUILD` 不一致的情况）；无变化则不会 push。
- 支持手动触发：`Actions -> Auto update AUR packages -> Run workflow`
  - `dry_run=true`：只更新/计算校验和/生成 `.SRCINFO`/commit，不 push 到 AUR
  - `pkgname=xxx`：只更新指定包；留空则更新全部包

## 包列表配置

包列表在 `config/packages.json`，格式示例：

- `name`: AUR 包名（必填）
- `branch`: AUR 分支（可选，默认 `master`）
- `upstream_github_repo`: 上游 GitHub 仓库（可选，形如 `owner/repo`；不填则从 AUR 仓库的 `PKGBUILD` 里 `url=` 推断）

新增包的流程：

1) 先在 AUR 上创建并能正常 push 的包仓库（至少有 `PKGBUILD`）
2) 把新包加进 `config/packages.json`
3) 等下一次 schedule 或手动触发（建议先 `dry_run=true`）

## 你需要做的设置（一次性）

### 1) 在 AUR 上添加 GitHub Actions 的 SSH 公钥

- 本地生成 key（建议单独给这个仓库用）：
  - `ssh-keygen -t ed25519 -C "github-actions-aur" -f aur_ed25519`
- 去 AUR 网页（你的账号设置）添加 `aur_ed25519.pub` 的内容到 SSH Keys。

### 2) 在 GitHub 仓库 Secrets 里配置私钥

在 GitHub 仓库设置里添加 Secret：

- `AUR_SSH_PRIVATE_KEY`: 填入 `aur_ed25519`（私钥全文，包含 `-----BEGIN OPENSSH PRIVATE KEY-----`）
- （可选，更安全）`AUR_KNOWN_HOSTS`: `ssh-keyscan -H aur.archlinux.org` 的输出，用于固定 host key；不填则 Action 会在运行时 keyscan

## 手动测试建议

- 先用 `dry_run=true` 跑一次，确认能成功：
  - 克隆 AUR 仓库
  - 正常生成新 `.SRCINFO`
  - 能 commit（但不会 push）
- 确认无误后，把 `dry_run` 取消勾选再跑一次即可 push 到 AUR。
