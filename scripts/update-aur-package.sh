#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令：$1"
}

trim_quotes() {
  local s="$1"
  s="${s#\"}"
  s="${s%\"}"
  printf '%s' "$s"
}

parse_kv_from_pkgbuild() {
  local key="$1"
  local file="$2"
  local line
  line="$(grep -E "^${key}=" "$file" | head -n1 || true)"
  [[ -n "$line" ]] || return 1
  printf '%s' "${line#*=}"
}

github_repo_from_url() {
  local url="$1"
  url="$(trim_quotes "$url")"
  url="${url%.git}"
  url="${url#https://github.com/}"
  url="${url#http://github.com/}"
  if [[ "$url" == */* ]]; then
    printf '%s' "$url"
    return 0
  fi
  return 1
}

normalize_github_tag_to_pkgver() {
  local tag="$1"
  tag="$(trim_quotes "$tag")"
  tag="${tag#v}"
  printf '%s' "$tag"
}

bool_to_01() {
  case "${1:-0}" in
    1|true|TRUE|True|yes|YES|y|Y) printf '1' ;;
    0|false|FALSE|False|no|NO|n|N|"") printf '0' ;;
    *) die "无法解析布尔值：${1}" ;;
  esac
}

fetch_latest_github_release_tag() {
  local repo="$1"
  local api="https://api.github.com/repos/${repo}/releases/latest"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "$api"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" "$api"
  fi
}

main() {
  need_cmd git
  need_cmd curl
  need_cmd jq
  need_cmd perl
  need_cmd updpkgsums
  need_cmd makepkg

  local aur_pkgname="${AUR_PKGNAME:-}"
  local aur_branch="${AUR_BRANCH:-master}"
  local aur_git_ssh_url="${AUR_GIT_SSH_URL:-aur@aur.archlinux.org:${aur_pkgname}.git}"
  local workdir="${WORKDIR:-${PWD}/_work}"
  local dry_run
  dry_run="$(bool_to_01 "${DRY_RUN:-0}")"

  if [[ "${1:-}" == "--pkgname" ]]; then
    aur_pkgname="${2:-}"
    shift 2 || true
  elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
用法：
  update-aur-package.sh --pkgname <aur-pkgname>

环境变量：
  AUR_PKGNAME           AUR 包名（与 --pkgname 二选一；--pkgname 优先）
  AUR_BRANCH            AUR 分支（默认 master）
  AUR_GIT_SSH_URL       AUR git SSH 地址（默认 aur@aur.archlinux.org:<pkgname>.git）
  UPSTREAM_GITHUB_REPO  上游 GitHub 仓库（可选；不填则从 PKGBUILD 的 url= 推断）
  DRY_RUN               1=只 commit 不 push
  WORKDIR               工作目录（默认 ./_work）
EOF
    exit 0
  fi

  if [[ -z "$aur_pkgname" ]]; then
    die "缺少 AUR 包名：请设置 AUR_PKGNAME 或传入 --pkgname"
  fi

  aur_git_ssh_url="${AUR_GIT_SSH_URL:-aur@aur.archlinux.org:${aur_pkgname}.git}"

  export GIT_TERMINAL_PROMPT=0

  mkdir -p "$workdir"
  local repo_dir="${workdir}/${aur_pkgname}"

  if [[ -d "${repo_dir}/.git" ]]; then
    log "更新本地缓存仓库：${repo_dir}"
    git -C "$repo_dir" fetch --prune origin
    git -C "$repo_dir" reset --hard "origin/${aur_branch}"
    git -C "$repo_dir" clean -fdx
  else
    log "克隆 AUR 仓库：${aur_git_ssh_url}"
    if ! git clone --depth=1 "$aur_git_ssh_url" "$repo_dir"; then
      log "浅克隆失败，改为完整克隆重试"
      rm -rf "$repo_dir"
      git clone "$aur_git_ssh_url" "$repo_dir"
    fi
  fi

  cd "$repo_dir"

  [[ -f PKGBUILD ]] || die "未找到 PKGBUILD：${repo_dir}/PKGBUILD"

  local current_pkgver pkgbuild_url
  current_pkgver="$(parse_kv_from_pkgbuild "pkgver" PKGBUILD | tr -d '[:space:]' || true)"
  [[ -n "$current_pkgver" ]] || die "无法从 PKGBUILD 解析 pkgver"

  pkgbuild_url="$(parse_kv_from_pkgbuild "url" PKGBUILD | tr -d '[:space:]' || true)"
  [[ -n "$pkgbuild_url" ]] || die "无法从 PKGBUILD 解析 url=（用于推断 GitHub 仓库）"

  local upstream_repo
  upstream_repo="${UPSTREAM_GITHUB_REPO:-}"
  if [[ -z "$upstream_repo" ]]; then
    upstream_repo="$(github_repo_from_url "$pkgbuild_url" || true)"
  fi
  [[ -n "$upstream_repo" ]] || die "无法确定上游 GitHub 仓库，请设置 UPSTREAM_GITHUB_REPO（例如 Kindness-Kismet/Stelliberty）"

  log "当前 AUR pkgver=${current_pkgver}，上游=${upstream_repo}"

  local release_json latest_tag latest_pkgver
  release_json="$(fetch_latest_github_release_tag "$upstream_repo")"
  latest_tag="$(printf '%s' "$release_json" | jq -r '.tag_name // empty')"
  [[ -n "$latest_tag" ]] || die "GitHub API 返回缺少 tag_name（可能没有 release 或被限流）"

  latest_pkgver="$(normalize_github_tag_to_pkgver "$latest_tag")"
  [[ -n "$latest_pkgver" ]] || die "无法从 tag 解析版本号：${latest_tag}"

  if [[ "$latest_pkgver" == "$current_pkgver" ]]; then
    log "无需更新版本：上游最新版本仍为 ${latest_pkgver}；检查是否需要刷新 .SRCINFO"

    local tmp_srcinfo
    tmp_srcinfo="$(mktemp)"
    makepkg --printsrcinfo > "$tmp_srcinfo"

    if cmp -s .SRCINFO "$tmp_srcinfo"; then
      rm -f "$tmp_srcinfo"
      log ".SRCINFO 无变化"
      exit 0
    fi

    mv "$tmp_srcinfo" .SRCINFO
    git config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
    git config user.email "${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}"
    git add .SRCINFO
    git commit -m "Refresh .SRCINFO"

    if [[ "$dry_run" == "1" ]]; then
      log "DRY_RUN=1：跳过 push，仅刷新 .SRCINFO 并 commit"
      exit 0
    fi

    log "推送 .SRCINFO 刷新到 AUR：${aur_git_ssh_url} (${aur_branch})"
    git push origin "HEAD:${aur_branch}"
    log "完成"
    exit 0
  fi

  log "检测到新版本：${current_pkgver} -> ${latest_pkgver}"

  local expected_x64="Stelliberty-v${latest_pkgver}-linux-x64.zip"
  local expected_arm64="Stelliberty-v${latest_pkgver}-linux-arm64.zip"

  local assets
  assets="$(printf '%s' "$release_json" | jq -r '.assets[]?.name' || true)"
  if ! grep -Fxq "$expected_x64" <<<"$assets"; then
    die "上游 release 缺少资产：${expected_x64}（为避免推送坏包，已终止）"
  fi
  if ! grep -Fxq "$expected_arm64" <<<"$assets"; then
    die "上游 release 缺少资产：${expected_arm64}（为避免推送坏包，已终止）"
  fi

  perl -pi -e "s/^pkgver=.*/pkgver=${latest_pkgver}/" PKGBUILD
  perl -pi -e "s/^pkgrel=.*/pkgrel=1/" PKGBUILD

  log "运行 updpkgsums（会下载 release 资产以计算校验和）"
  updpkgsums

  log "刷新 .SRCINFO"
  makepkg --printsrcinfo > .SRCINFO

  if git diff --quiet; then
    log "文件无变化（可能 PKGBUILD 已是最新但 pkgrel/sha 未变化）"
    exit 0
  fi

  log "变更摘要："
  git diff --stat >&2 || true

  git config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
  git config user.email "${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}"

  git add PKGBUILD .SRCINFO
  git commit -m "Update pkgver to ${latest_pkgver}"

  if [[ "$dry_run" == "1" ]]; then
    log "DRY_RUN=1：跳过 push，仅完成本地更新与 commit"
    exit 0
  fi

  log "推送到 AUR：${aur_git_ssh_url} (${aur_branch})"
  git push origin "HEAD:${aur_branch}"
  log "完成"
}

main "$@"
