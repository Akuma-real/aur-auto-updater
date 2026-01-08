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

main() {
  need_cmd jq
  need_cmd bash

  local config_file="${PACKAGES_CONFIG:-config/packages.json}"
  local only_pkgname="${ONLY_PKGNAME:-}"
  local workdir="${WORKDIR:-${PWD}/_work}"
  local report_json="${REPORT_JSON:-${workdir}/report.jsonl}"

  [[ -f "$config_file" ]] || die "未找到配置文件：${config_file}"
  mkdir -p "$workdir"
  : > "$report_json"

  local count
  count="$(jq -r '.packages | length' "$config_file")"
  [[ "$count" =~ ^[0-9]+$ ]] || die "配置文件格式错误：.packages 不是数组"

  if [[ "$count" -eq 0 ]]; then
    log "配置文件中 packages 为空，跳过"
    exit 0
  fi

  local i
  for ((i=0; i<count; i++)); do
    local name branch upstream
    name="$(jq -r ".packages[$i].name // empty" "$config_file")"
    branch="$(jq -r ".packages[$i].branch // \"master\"" "$config_file")"
    upstream="$(jq -r ".packages[$i].upstream_github_repo // empty" "$config_file")"

    [[ -n "$name" ]] || die "配置文件第 $i 项缺少 name"

    if [[ -n "$only_pkgname" && "$only_pkgname" != "$name" ]]; then
      log "跳过 ${name}（ONLY_PKGNAME=${only_pkgname}）"
      continue
    fi

    log "开始更新：${name}"
    (
      export AUR_PKGNAME="$name"
      export AUR_BRANCH="$branch"
      export REPORT_JSON="$report_json"
      if [[ -n "$upstream" ]]; then
        export UPSTREAM_GITHUB_REPO="$upstream"
      else
        unset UPSTREAM_GITHUB_REPO || true
      fi
      bash scripts/update-aur-package.sh
    )
    log "完成更新：${name}"
  done
}

main "$@"
