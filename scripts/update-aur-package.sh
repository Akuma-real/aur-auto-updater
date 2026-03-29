#!/usr/bin/env bash
set -euo pipefail

: "${STARTED_AT:=}"
: "${REPORT_JSON:=}"
: "${AUR_PKGNAME:=}"
: "${AUR_BRANCH:=master}"
: "${UPSTREAM_REPO:=}"
: "${CURRENT_PKGVER:=}"
: "${LATEST_PKGVER:=}"
: "${COMMIT_SHA:=}"
: "${COMMITTED:=0}"
: "${PUSHED:=0}"
: "${DRY_RUN:=0}"
: "${PACKAGING_FIX_APPLIED:=0}"
: "${FINAL_STATUS:=}"
: "${FINAL_NOTE:=}"
: "${LAST_ERROR:=}"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
  LAST_ERROR="$*"
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
  need_cmd sudo
  need_cmd namcap
  need_cmd bsdtar
  need_cmd sha256sum
  need_cmd updpkgsums
  need_cmd makepkg

  STARTED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  AUR_PKGNAME="${AUR_PKGNAME:-}"
  AUR_BRANCH="${AUR_BRANCH:-master}"
  local aur_git_ssh_url="${AUR_GIT_SSH_URL:-aur@aur.archlinux.org:${AUR_PKGNAME}.git}"
  local workdir="${WORKDIR:-${PWD}/_work}"
  DRY_RUN="$(bool_to_01 "${DRY_RUN:-0}")"

  REPORT_JSON="${REPORT_JSON:-}"
  UPSTREAM_REPO=""
  CURRENT_PKGVER=""
  LATEST_PKGVER=""
  COMMIT_SHA=""
  COMMITTED=0
  PUSHED=0
  FINAL_STATUS=""
  FINAL_NOTE=""
  LAST_ERROR="${LAST_ERROR:-}"

  append_report() {
    local exit_code="${1:-0}"
    local finished_at
    finished_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

    [[ -n "$REPORT_JSON" ]] || return 0
    mkdir -p "$(dirname "$REPORT_JSON")"

    jq -cn \
      --arg started_at "$STARTED_AT" \
      --arg finished_at "$finished_at" \
      --arg pkgname "$AUR_PKGNAME" \
      --arg branch "$AUR_BRANCH" \
      --arg upstream_repo "$UPSTREAM_REPO" \
      --arg current_pkgver "$CURRENT_PKGVER" \
      --arg latest_pkgver "$LATEST_PKGVER" \
      --arg status "$FINAL_STATUS" \
      --arg note "$FINAL_NOTE" \
      --arg commit_sha "$COMMIT_SHA" \
      --argjson committed "$COMMITTED" \
      --argjson pushed "$PUSHED" \
      --argjson dry_run "$DRY_RUN" \
      --argjson exit_code "$exit_code" \
      '{
        started_at: $started_at,
        finished_at: $finished_at,
        pkgname: $pkgname,
        branch: $branch,
        upstream_repo: $upstream_repo,
        current_pkgver: (if ($current_pkgver | length) > 0 then $current_pkgver else null end),
        latest_pkgver: (if ($latest_pkgver | length) > 0 then $latest_pkgver else null end),
        status: $status,
        note: (if ($note | length) > 0 then $note else null end),
        commit_sha: (if ($commit_sha | length) > 0 then $commit_sha else null end),
        committed: $committed,
        pushed: $pushed,
        dry_run: $dry_run,
        exit_code: $exit_code
      }' >> "$REPORT_JSON"
  }

  trap 'LAST_ERROR=${LAST_ERROR:-"命令失败（exit=$?）: ${BASH_COMMAND}"}' ERR
  trap 'ec=$?; trap - EXIT; if [[ $ec -ne 0 && -z "${FINAL_STATUS:-}" ]]; then FINAL_STATUS="failed"; FINAL_NOTE="${LAST_ERROR:-"unknown error"}"; fi; append_report "$ec" || true; exit $ec' EXIT

  if [[ "${1:-}" == "--pkgname" ]]; then
    AUR_PKGNAME="${2:-}"
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

  if [[ -z "$AUR_PKGNAME" ]]; then
    die "缺少 AUR 包名：请设置 AUR_PKGNAME 或传入 --pkgname"
  fi

  aur_git_ssh_url="${AUR_GIT_SSH_URL:-aur@aur.archlinux.org:${AUR_PKGNAME}.git}"

  export GIT_TERMINAL_PROMPT=0

  mkdir -p "$workdir"
  local repo_dir="${workdir}/${AUR_PKGNAME}"

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

  local srcdest_dir="${repo_dir}/.srcdest"
  mkdir -p "$srcdest_dir"
  export SRCDEST="$srcdest_dir"

  [[ -f PKGBUILD ]] || die "未找到 PKGBUILD：${repo_dir}/PKGBUILD"

  normalize_dep_pkgname() {
    local dep="$1"
    dep="${dep%%:*}"
    dep="${dep## }"
    dep="${dep%% }"
    dep="${dep%%[<>=]*}"
    dep="$(printf '%s' "$dep" | xargs)"
    printf '%s' "$dep"
  }

  normalize_stelliberty_pkgbuild() {
    [[ "$AUR_PKGNAME" == "stelliberty-bin" ]] || return 0

    local normalized=0
    local install_file="${AUR_PKGNAME}.install"

    apply_pkgbuild_perl() {
      local mode="$1"
      local expr="$2"
      local before_file
      before_file="$(mktemp)"
      cp PKGBUILD "$before_file"

      if [[ "$mode" == "slurp" ]]; then
        perl -0pi -e "$expr" PKGBUILD
      else
        perl -pi -e "$expr" PKGBUILD
      fi

      if ! cmp -s "$before_file" PKGBUILD; then
        normalized=1
      fi
      rm -f "$before_file"
    }

    if grep -Fq '"LICENSE::https://raw.githubusercontent.com/Kindness-Kismet/Stelliberty/v${pkgver}/LICENSE"' PKGBUILD; then
      apply_pkgbuild_perl line 's|"LICENSE::https://raw\.githubusercontent\.com/Kindness-Kismet/Stelliberty/v\$\{pkgver\}/LICENSE"|"LICENSE-v\${pkgver}::https://raw.githubusercontent.com/Kindness-Kismet/Stelliberty/v\${pkgver}/LICENSE"|g'
    fi

    if grep -Fq 'install -Dm644 "${srcdir}/LICENSE" "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"' PKGBUILD; then
      apply_pkgbuild_perl line 's|install -Dm644 "\$\{srcdir\}/LICENSE" "\$\{pkgdir\}/usr/share/licenses/\$\{pkgname\}/LICENSE"|install -Dm644 "\${srcdir}/LICENSE-v\${pkgver}" "\${pkgdir}/usr/share/licenses/\${pkgname}/LICENSE"|g'
    fi

    if grep -Fq 'ensure_exec() {
  local file="$1"
  if [[ -f "${file}" && ! -x "${file}" ]]; then
    chmod 755 "${file}"
  fi
}' PKGBUILD; then
      apply_pkgbuild_perl slurp 's|ensure_exec\(\) \{\n  local file="\$1"\n  if \[\[ -f "\$\{file\}" && ! -x "\$\{file\}" \]\]; then\n    chmod 755 "\$\{file\}"\n  fi\n\}|ensure_exec() {\n  local file="\$1"\n  if [[ ! -f "\${file}" ]]; then\n    printf '\''stelliberty: required file not found: %s\\n'\'' "\${file}" >\&2\n    exit 1\n  fi\n  if [[ ! -x "\${file}" ]]; then\n    chmod 755 "\${file}"\n  fi\n}|g'
    fi

    if grep -Eq 'assets/clash-core/clash-core|assets/clash/clash-core' PKGBUILD; then
      apply_pkgbuild_perl slurp 's|  chmod \+x "\$\{_install_dir\}/stelliberty"\n  chmod \+x "\$\{_install_dir\}/data/flutter_assets/assets/service/stelliberty-service"\n  if \[\[ -f "\$\{_install_dir\}/data/flutter_assets/assets/clash(?:-core)?/clash-core" \]\]; then\n    chmod 755 "\$\{_install_dir\}/data/flutter_assets/assets/clash(?:-core)?/clash-core"\n  fi|  chmod +x "\${_install_dir}/stelliberty"\n  chmod +x "\${_install_dir}/data/flutter_assets/assets/service/stelliberty-service"\n\n  local _clash_core="\${_install_dir}/data/flutter_assets/assets/clash/clash-core"\n  if [[ -f "\${_clash_core}" ]]; then\n    chmod 755 "\${_clash_core}"\n  else\n    echo "Missing clash core: \${_clash_core}" >\&2\n    return 1\n  fi|g'
      apply_pkgbuild_perl line 's|assets/clash-core/clash-core|assets/clash/clash-core|g'
    fi

    if grep -Fq "optdepends=('xdg-utils: for xdg-open support')" PKGBUILD; then
      apply_pkgbuild_perl slurp 's|optdepends=\('\''xdg-utils: for xdg-open support'\''\)|optdepends=(\n  '\''xdg-utils: for xdg-open support'\''\n  '\''polkit: for pkexec-based service installation from the UI'\''\n)|g'
    fi

    if ! grep -Fq "install=${install_file}" PKGBUILD; then
      apply_pkgbuild_perl slurp "s|^license=\\('LicenseRef-Stelliberty'\\)\$|license=('LicenseRef-Stelliberty')\\ninstall=${install_file}|m"
    fi

    if grep -Fq '  bsdtar -xf "${srcdir}/${_archive}" -C "${_install_dir}"' PKGBUILD; then
      apply_pkgbuild_perl slurp 's|  bsdtar -xf "\$\{srcdir\}/\$\{_archive\}" -C "\$\{_install_dir\}"|  bsdtar -xf "\${srcdir}/\${_archive}" -C "\${_install_dir}"\n  rm -f "\${_install_dir}/data/.portable"\n  printf '\''%s\\n'\'' "\${pkgver}-\${pkgrel}" > "\${_install_dir}/data/.package-sync-revision"|g'
    fi

    if grep -Fq 'sync_app() {
  install -d "${user_dir}"
  rsync -a --delete \
    --exclude '\''data/subscriptions'\'' \
    --exclude '\''data/subscriptions/***'\'' \
    --exclude '\''data/overrides'\'' \
    --exclude '\''data/overrides/***'\'' \
    --exclude '\''data/running.logs*'\'' \
    "${system_dir}/" "${user_dir}/"
}' PKGBUILD; then
      apply_pkgbuild_perl slurp 's|sync_app\(\) \{\n  install -d "\$\{user_dir\}"\n  rsync -a --delete \\\n    --exclude '\''data/subscriptions'\'' \\\n    --exclude '\''data/subscriptions/\*\*\*'\'' \\\n    --exclude '\''data/overrides'\'' \\\n    --exclude '\''data/overrides/\*\*\*'\'' \\\n    --exclude '\''data/running\.logs\*'\'' \\\n    "\$\{system_dir\}/" "\$\{user_dir\}/"\n\}|sync_app() {\n  install -d "\${user_dir}"\n\n  local -a preserve_patterns=(\n    '\''data/subscriptions'\''\n    '\''data/subscriptions/***'\''\n    '\''data/subscriptions_list.json'\''\n    '\''data/overrides'\''\n    '\''data/overrides/***'\''\n    '\''data/overrides_list.json'\''\n    '\''data/image_cache'\''\n    '\''data/image_cache/***'\''\n    '\''data/dns_config.yaml'\''\n    '\''data/stelliberty_proxy.pac'\''\n    '\''data/settings_preferences.json'\''\n    '\''data/settings_preferences_dev.json'\''\n    '\''data/running.logs*'\''\n    '\''data/runtime'\''\n    '\''data/runtime/***'\''\n  )\n\n  local -a rsync_args=(-a --delete)\n  local pattern\n  for pattern in "\${preserve_patterns[@]}"; do\n    rsync_args+=(--exclude "\${pattern}")\n  done\n\n  rsync "\${rsync_args[@]}" "\${system_dir}/" "\${user_dir}/"\n}|g'
    fi

    if grep -Fq 'data_root="${XDG_DATA_HOME:-${HOME}/.local/share}/stelliberty"' PKGBUILD; then
      apply_pkgbuild_perl slurp 's|data_root="\$\{XDG_DATA_HOME:-\$\{HOME\}/\.local/share\}/stelliberty"|# Allow overriding the app data root when HOME\/XDG_DATA_HOME contains unsupported characters.\ndata_root="\${STELLIBERTY_DATA_ROOT:-\${XDG_DATA_HOME:-\${HOME}/.local/share}/stelliberty}"|g'
    fi

    if ! grep -Fq 'token_of() {' PKGBUILD && grep -Fq 'sync_app() {' PKGBUILD; then
      apply_pkgbuild_perl slurp 's|\n\nsync_app\(\) \{|\n\ntoken_of() {\n  local file="\$1"\n  if [[ -r "\$file" ]]; then\n    head -n1 "\$file"\n  fi\n}\n\nsync_app() {|g'
    fi

    if grep -Fq 'sys_ver="$(version_of "${system_dir}/data/flutter_assets/version.json")"
usr_ver="$(version_of "${user_dir}/data/flutter_assets/version.json")"

if [[ "${usr_ver:-}" != "${sys_ver:-}" ]]; then
  sync_app
fi' PKGBUILD; then
      apply_pkgbuild_perl slurp 's~sys_ver="\$\(version_of "\$\{system_dir\}/data/flutter_assets/version\.json"\)"\nusr_ver="\$\(version_of "\$\{user_dir\}/data/flutter_assets/version\.json"\)"\n\nif \[\[ "\$\{usr_ver:-\}" != "\$\{sys_ver:-\}" \]\]; then\n  sync_app\nfi~sys_ver="\$(version_of "\${system_dir}/data/flutter_assets/version.json")"\nusr_ver="\$(version_of "\${user_dir}/data/flutter_assets/version.json")"\nsys_sync_revision="\$(token_of "\${system_dir}/data/.package-sync-revision")"\nusr_sync_revision="\$(token_of "\${user_dir}/data/.package-sync-revision")"\n\nif [[ "\${usr_ver:-}" != "\${sys_ver:-}" || "\${usr_sync_revision:-}" != "\${sys_sync_revision:-}" ]]; then\n  sync_app\nfi~g'
    fi

    write_stelliberty_install_script() {
      local target_file="$1"
      local tmp_file
      tmp_file="$(mktemp)"

      cat > "$tmp_file" <<'EOF'
post_install() {
  cat <<'EOM'
stelliberty-bin 已安装。

- 如需在应用 UI 中安装 Stelliberty service，请先安装 polkit。
- 如果 HOME 或 XDG_DATA_HOME 路径包含中文或其他非 ASCII 字符，可设置 STELLIBERTY_DATA_ROOT 到纯 ASCII 目录后再启动。
EOM
}

post_upgrade() {
  cat <<'EOM'
stelliberty-bin 已升级。

- 本版本起不再保留 upstream ZIP 的 .portable 标记，避免被应用误判为便携版。
- 如需让新的包同步策略生效，请重启 Stelliberty。
- 如需在应用 UI 中安装 Stelliberty service，请先安装 polkit。
- 如果 HOME 或 XDG_DATA_HOME 路径包含中文或其他非 ASCII 字符，可设置 STELLIBERTY_DATA_ROOT 到纯 ASCII 目录后再启动。
EOM
}
EOF

      if [[ ! -f "$target_file" ]] || ! cmp -s "$tmp_file" "$target_file"; then
        mv "$tmp_file" "$target_file"
        normalized=1
      else
        rm -f "$tmp_file"
      fi
    }

    write_stelliberty_install_script "$install_file"

    if [[ "$normalized" == "1" ]]; then
      PACKAGING_FIX_APPLIED=1
      log "已规范 stelliberty-bin PKGBUILD：修正 LICENSE、clash core、.portable、optdepends、install 脚本与用户数据同步策略"
    fi
  }

  clear_url_source_cache() {
    log "清理 URL source 缓存（避免同名文件跨版本复用）"

    local tmp_srcinfo
    tmp_srcinfo="$(mktemp)"
    makepkg --printsrcinfo > "$tmp_srcinfo"

    local -a source_entries
    mapfile -t source_entries < <(
      grep -E '^[[:space:]]*source(_[[:alnum:]_]+)? = ' "$tmp_srcinfo" \
        | awk -F' = ' '{print $2}'
    )
    rm -f "$tmp_srcinfo"

    local removed_count=0
    local src_entry src_name src_url
    for src_entry in "${source_entries[@]}"; do
      src_name=""
      src_url=""

      if [[ "$src_entry" == *"::"* ]]; then
        src_name="${src_entry%%::*}"
        src_url="${src_entry#*::}"
      else
        src_url="$src_entry"
        if [[ "$src_entry" =~ ^https?:// ]]; then
          src_name="${src_entry##*/}"
          src_name="${src_name%%\?*}"
        fi
      fi

      [[ "$src_url" =~ ^https?:// ]] || continue
      [[ -n "$src_name" ]] || continue

      if [[ -f "$src_name" ]]; then
        rm -f -- "$src_name"
        removed_count=$((removed_count + 1))
      fi
      if [[ -f "${SRCDEST}/${src_name}" ]]; then
        rm -f -- "${SRCDEST}/${src_name}"
        removed_count=$((removed_count + 1))
      fi
    done

    log "URL source 缓存清理完成：${removed_count} 个文件"
  }

  verify_strict_before_push() {
    log "开始强验证（推送前必须通过）"

    log "校验 .SRCINFO 与 PKGBUILD 一致性"
    local tmp_srcinfo
    tmp_srcinfo="$(mktemp)"
    makepkg --printsrcinfo > "$tmp_srcinfo"
    if ! cmp -s .SRCINFO "$tmp_srcinfo"; then
      log ".SRCINFO 与 PKGBUILD 不一致，差异如下："
      diff -u .SRCINFO "$tmp_srcinfo" >&2 || true
      rm -f "$tmp_srcinfo"
      die "强验证失败：.SRCINFO 与 PKGBUILD 不一致"
    fi
    rm -f "$tmp_srcinfo"

    log "校验 source 校验和（makepkg --verifysource）"
    makepkg --verifysource

    log "额外校验 aarch64 资产的 sha256（避免仅在 x86_64 更新导致 aarch64 校验和漂移）"
    local aarch64_source_line aarch64_sum
    aarch64_source_line="$(grep -E '^[[:space:]]*source_aarch64 = ' .SRCINFO | head -n1 || true)"
    aarch64_sum="$(grep -E '^[[:space:]]*sha256sums_aarch64 = ' .SRCINFO | head -n1 | awk -F' = ' '{print $2}' || true)"
    if [[ -z "$aarch64_source_line" || -z "$aarch64_sum" ]]; then
      die "强验证失败：未在 .SRCINFO 中找到 source_aarch64/sha256sums_aarch64"
    fi

    local aarch64_src aarch64_url
    aarch64_src="$(printf '%s' "$aarch64_source_line" | awk -F' = ' '{print $2}')"
    if [[ "$aarch64_src" == *"::"* ]]; then
      aarch64_url="${aarch64_src#*::}"
    else
      die "强验证失败：source_aarch64 未包含 URL（期望格式 name::url），实际：${aarch64_src}"
    fi

    local aarch64_tmp
    aarch64_tmp="$(mktemp)"
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o "$aarch64_tmp" "$aarch64_url"
    local aarch64_actual
    aarch64_actual="$(sha256sum "$aarch64_tmp" | awk '{print $1}')"
    rm -f "$aarch64_tmp"
    if [[ "$aarch64_actual" != "$aarch64_sum" ]]; then
      die "强验证失败：aarch64 资产 sha256 不匹配（期望 ${aarch64_sum}，实际 ${aarch64_actual}）"
    fi

    log "安装 depends/makedepends/checkdepends（强验证要求完整构建）"
    local -a deps_raw deps_norm
    mapfile -t deps_raw < <(
      grep -E '^[[:space:]]*(depends|makedepends|checkdepends) = ' .SRCINFO \
        | awk -F' = ' '{print $2}' \
        | sort -u
    )
    deps_norm=()
    local dep pkg
    for dep in "${deps_raw[@]}"; do
      pkg="$(normalize_dep_pkgname "$dep")"
      [[ -n "$pkg" ]] || continue
      deps_norm+=("$pkg")
    done
    if [[ "${#deps_norm[@]}" -gt 0 ]]; then
      sudo pacman -S --noconfirm --needed "${deps_norm[@]}"
    fi

    log "完整构建并运行 check()（makepkg --cleanbuild）"
    makepkg --noconfirm --clean --cleanbuild

    log "校验构建产物存在"
    local -a pkgfiles
    mapfile -t pkgfiles < <(ls -1 *.pkg.tar.* 2>/dev/null || true)
    if [[ "${#pkgfiles[@]}" -eq 0 ]]; then
      die "强验证失败：构建未产出 *.pkg.tar.*"
    fi

    log "验证产物包可读取（bsdtar -tf）"
    local pkgfile
    for pkgfile in "${pkgfiles[@]}"; do
      bsdtar -tf "$pkgfile" >/dev/null
    done

    log "运行 namcap lint（对 PKGBUILD 和产物包；E 失败，W 记录）"
    local namcap_out
    namcap_out="$(namcap PKGBUILD 2>&1 || true)"
    local -a allow_patterns
    allow_patterns=('^PKGBUILD .* W: Reference to x86_64 should be changed to [$]CARCH$')
    local filtered
    filtered="$namcap_out"
    local pat
    for pat in "${allow_patterns[@]}"; do
      filtered="$(printf '%s\n' "$filtered" | grep -Ev -- "$pat" || true)"
    done
    if grep -Eq ' E: ' <<<"$filtered"; then
      printf '%s\n' "$namcap_out" >&2
      die "强验证失败：namcap 在 PKGBUILD 上报告 E"
    fi
    if grep -Eq ' W: ' <<<"$filtered"; then
      printf '%s\n' "$namcap_out" >&2
      die "强验证失败：namcap 在 PKGBUILD 上报告未允许的 W"
    fi
    if grep -Eq ' (W|E): ' <<<"$namcap_out"; then
      log "namcap 在 PKGBUILD 上报告了允许的警告（已放行）："
      printf '%s\n' "$namcap_out" >&2
    fi

    local pkg_w_count=0
    local pkg_e_count=0
    for pkgfile in "${pkgfiles[@]}"; do
      namcap_out="$(namcap "$pkgfile" 2>&1 || true)"
      if grep -Eq ' E: ' <<<"$namcap_out"; then
        pkg_e_count=$((pkg_e_count + 1))
        printf '%s\n' "$namcap_out" >&2
        die "强验证失败：namcap 在产物包 ${pkgfile} 上报告 E"
      fi
      if grep -Eq ' W: ' <<<"$namcap_out"; then
        pkg_w_count=$((pkg_w_count + 1))
        log "namcap 在产物包 ${pkgfile} 上报告了 W（不阻塞，但会写入日志与报告）"
        printf '%s\n' "$namcap_out" >&2
      fi
    done

    if [[ "$pkg_w_count" -gt 0 ]]; then
      FINAL_NOTE="${FINAL_NOTE:+${FINAL_NOTE}; }namcap(W) in package artifacts=${pkg_w_count}"
    fi
    if [[ "$pkg_e_count" -gt 0 ]]; then
      FINAL_NOTE="${FINAL_NOTE:+${FINAL_NOTE}; }namcap(E) in package artifacts=${pkg_e_count}"
    fi

    log "强验证通过"
  }

  local current_pkgver current_pkgrel pkgbuild_url

  PACKAGING_FIX_APPLIED=0
  normalize_stelliberty_pkgbuild

  current_pkgver="$(parse_kv_from_pkgbuild "pkgver" PKGBUILD | tr -d '[:space:]' || true)"
  [[ -n "$current_pkgver" ]] || die "无法从 PKGBUILD 解析 pkgver"
  CURRENT_PKGVER="$current_pkgver"

  current_pkgrel="$(parse_kv_from_pkgbuild "pkgrel" PKGBUILD | tr -d '[:space:]' || true)"
  [[ "$current_pkgrel" =~ ^[0-9]+$ ]] || die "无法从 PKGBUILD 解析数字型 pkgrel"

  pkgbuild_url="$(parse_kv_from_pkgbuild "url" PKGBUILD | tr -d '[:space:]' || true)"
  [[ -n "$pkgbuild_url" ]] || die "无法从 PKGBUILD 解析 url=（用于推断 GitHub 仓库）"

  UPSTREAM_REPO="${UPSTREAM_GITHUB_REPO:-}"
  if [[ -z "$UPSTREAM_REPO" ]]; then
    UPSTREAM_REPO="$(github_repo_from_url "$pkgbuild_url" || true)"
  fi
  [[ -n "$UPSTREAM_REPO" ]] || die "无法确定上游 GitHub 仓库，请设置 UPSTREAM_GITHUB_REPO（例如 Kindness-Kismet/Stelliberty）"

  log "当前 AUR pkgver=${current_pkgver}，上游=${UPSTREAM_REPO}"

  local release_json latest_tag latest_pkgver
  release_json="$(fetch_latest_github_release_tag "$UPSTREAM_REPO")"
  latest_tag="$(printf '%s' "$release_json" | jq -r '.tag_name // empty')"
  [[ -n "$latest_tag" ]] || die "GitHub API 返回缺少 tag_name（可能没有 release 或被限流）"

  latest_pkgver="$(normalize_github_tag_to_pkgver "$latest_tag")"
  [[ -n "$latest_pkgver" ]] || die "无法从 tag 解析版本号：${latest_tag}"
  LATEST_PKGVER="$latest_pkgver"

  local version_changed="0"
  if [[ "$latest_pkgver" != "$current_pkgver" ]]; then
    version_changed="1"
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

    clear_url_source_cache

    log "运行 updpkgsums（会下载 release 资产以计算校验和）"
    updpkgsums
  else
    log "无需更新版本：上游最新版本仍为 ${latest_pkgver}"

    if [[ "$PACKAGING_FIX_APPLIED" == "1" ]]; then
      local next_pkgrel
      next_pkgrel=$((current_pkgrel + 1))
      log "检测到打包修复且上游版本未变：pkgrel ${current_pkgrel} -> ${next_pkgrel}"
      perl -pi -e "s/^pkgrel=.*/pkgrel=${next_pkgrel}/" PKGBUILD
      current_pkgrel="$next_pkgrel"
    fi
  fi

  log "刷新 .SRCINFO"
  makepkg --printsrcinfo > .SRCINFO

  if git diff --quiet; then
    log "无可提交变更"
    FINAL_STATUS="no_change"
    FINAL_NOTE="无可提交变更"
    exit 0
  fi

  verify_strict_before_push

  log "变更摘要："
  git diff --stat >&2 || true

  git config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
  git config user.email "${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}"

  git add PKGBUILD .SRCINFO
  if [[ -f "${AUR_PKGNAME}.install" ]]; then
    git add "${AUR_PKGNAME}.install"
  fi
  git add -u

  local commit_msg
  if [[ "$version_changed" == "1" ]]; then
    commit_msg="Update pkgver to ${latest_pkgver}"
    FINAL_STATUS="updated"
  elif [[ "$PACKAGING_FIX_APPLIED" == "1" ]]; then
    commit_msg="Bump pkgrel to ${current_pkgrel}"
    FINAL_STATUS="refreshed"
  else
    commit_msg="Refresh metadata"
    FINAL_STATUS="refreshed"
  fi

  git commit -m "$commit_msg"
  COMMITTED=1
  COMMIT_SHA="$(git rev-parse HEAD)"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1：跳过 push，仅完成本地更新与 commit"
    FINAL_NOTE="dry-run：${commit_msg}"
    exit 0
  fi

  log "推送到 AUR：${aur_git_ssh_url} (${AUR_BRANCH})"
  git push origin "HEAD:${AUR_BRANCH}"
  PUSHED=1
  FINAL_NOTE="已推送到 AUR：${commit_msg}"
  log "完成"
}

main "$@"
