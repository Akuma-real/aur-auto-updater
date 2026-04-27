#!/usr/bin/env python3
from __future__ import annotations

import argparse
import difflib
import glob
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class UpdaterError(RuntimeError):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(message: str) -> None:
    print(f"[{utc_now()}] {message}", file=sys.stderr, flush=True)


def bool_to_int(value: str | None) -> int:
    if value is None or value == "":
        return 0
    if value in {"1", "true", "TRUE", "True", "yes", "YES", "y", "Y"}:
        return 1
    if value in {"0", "false", "FALSE", "False", "no", "NO", "n", "N"}:
        return 0
    raise UpdaterError(f"无法解析布尔值：{value}")


def need_cmd(name: str) -> None:
    if shutil.which(name) is None:
        raise UpdaterError(f"缺少依赖命令：{name}")


def trim_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1]
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1]
    return value


def normalize_github_tag_to_pkgver(tag: str) -> str:
    return trim_quotes(tag).removeprefix("v")


def github_repo_from_url(url: str) -> str | None:
    value = trim_quotes(url).removesuffix(".git")
    for prefix in ("https://github.com/", "http://github.com/"):
        if value.startswith(prefix):
            value = value[len(prefix) :]
            break
    return value if "/" in value else None


def normalize_dep_pkgname(dep: str) -> str:
    dep = dep.split(":", 1)[0].strip()
    dep = re.split(r"[<>=]", dep, maxsplit=1)[0].strip()
    return dep


def run(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    check: bool = True,
    capture_output: bool = False,
) -> subprocess.CompletedProcess[str]:
    printable = shlex.join(cmd)
    if cwd is not None:
        log(f"$ (cd {cwd} && {printable})")
    else:
        log(f"$ {printable}")
    completed = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        capture_output=capture_output,
    )
    if check and completed.returncode != 0:
        detail = f"命令失败（exit={completed.returncode}）：{printable}"
        if completed.stderr:
            detail = f"{detail}\n{completed.stderr.strip()}"
        raise UpdaterError(detail)
    return completed


def replace_text(path: Path, old: str, new: str) -> bool:
    content = path.read_text()
    if old not in content:
        return False
    updated = content.replace(old, new)
    if updated == content:
        return False
    path.write_text(updated)
    return True


def regex_replace(path: Path, pattern: str, repl: str, *, flags: int = 0) -> bool:
    content = path.read_text()
    compiled = re.compile(pattern, flags)
    updated, count = compiled.subn(lambda _: repl, content)
    if count == 0 or updated == content:
        return False
    path.write_text(updated)
    return True


def parse_pkgbuild_key(path: Path, key: str) -> str | None:
    pattern = re.compile(rf"^{re.escape(key)}=(.*)$", re.MULTILINE)
    match = pattern.search(path.read_text())
    return match.group(1) if match else None


def set_pkgbuild_key(path: Path, key: str, value: str) -> bool:
    return regex_replace(path, rf"^{re.escape(key)}=.*$", f"{key}={value}", flags=re.MULTILINE)


def download_bytes(url: str, *, attempts: int = 3, delay_seconds: int = 2) -> bytes:
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "aur-auto-updater"})
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.read()
        except (urllib.error.URLError, TimeoutError) as exc:
            last_error = exc
            if attempt < attempts:
                time.sleep(delay_seconds)
    raise UpdaterError(f"下载失败：{url} ({last_error})")


def fetch_latest_github_release(repo: str, github_token: str | None) -> dict[str, Any]:
    api = f"https://api.github.com/repos/{repo}/releases/latest"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "aur-auto-updater",
    }
    if github_token:
        headers["Authorization"] = f"Bearer {github_token}"
    request = urllib.request.Request(api, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise UpdaterError(f"GitHub API 请求失败：{api} HTTP {exc.code}\n{body}") from exc
    except urllib.error.URLError as exc:
        raise UpdaterError(f"GitHub API 请求失败：{api} ({exc})") from exc


@dataclass
class PackageConfig:
    name: str
    branch: str = "master"
    upstream_github_repo: str = ""


@dataclass
class PackageReport:
    started_at: str
    pkgname: str
    branch: str
    upstream_repo: str = ""
    current_pkgver: str | None = None
    latest_pkgver: str | None = None
    status: str = ""
    note: str | None = None
    commit_sha: str | None = None
    committed: int = 0
    pushed: int = 0
    dry_run: int = 0
    exit_code: int = 0
    finished_at: str = ""

    def to_json(self) -> str:
        payload = {
            "started_at": self.started_at,
            "finished_at": self.finished_at or utc_now(),
            "pkgname": self.pkgname,
            "branch": self.branch,
            "upstream_repo": self.upstream_repo,
            "current_pkgver": self.current_pkgver,
            "latest_pkgver": self.latest_pkgver,
            "status": self.status,
            "note": self.note,
            "commit_sha": self.commit_sha,
            "committed": self.committed,
            "pushed": self.pushed,
            "dry_run": self.dry_run,
            "exit_code": self.exit_code,
        }
        return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


@dataclass
class RunContext:
    repo_root: Path
    workdir: Path
    report_json: Path
    dry_run: int
    github_token: str | None
    base_env: dict[str, str] = field(default_factory=lambda: os.environ.copy())


class PackageUpdater:
    def __init__(self, config: PackageConfig, context: RunContext) -> None:
        self.config = config
        self.context = context
        self.repo_dir = context.workdir / config.name
        self.report = PackageReport(
            started_at=utc_now(),
            pkgname=config.name,
            branch=config.branch,
            upstream_repo=config.upstream_github_repo,
            dry_run=context.dry_run,
        )
        self.env = context.base_env.copy()
        self.env["GIT_TERMINAL_PROMPT"] = "0"
        self.packaging_fix_applied = False

    @property
    def pkgbuild(self) -> Path:
        return self.repo_dir / "PKGBUILD"

    @property
    def srcinfo(self) -> Path:
        return self.repo_dir / ".SRCINFO"

    def append_note(self, note: str) -> None:
        self.report.note = f"{self.report.note}; {note}" if self.report.note else note

    def append_report(self, exit_code: int) -> None:
        self.report.exit_code = exit_code
        self.report.finished_at = utc_now()
        self.context.report_json.parent.mkdir(parents=True, exist_ok=True)
        with self.context.report_json.open("a", encoding="utf-8") as handle:
            handle.write(self.report.to_json())
            handle.write("\n")

    def run_package(self) -> None:
        try:
            self._run_package()
        except Exception as exc:
            if not self.report.status:
                self.report.status = "failed"
            if self.report.note:
                self.append_note(str(exc))
            else:
                self.report.note = str(exc)
            self.append_report(1)
            raise
        else:
            self.append_report(0)

    def _run_package(self) -> None:
        self.clone_or_update_repo()
        srcdest = self.repo_dir / ".srcdest"
        srcdest.mkdir(parents=True, exist_ok=True)
        self.env["SRCDEST"] = str(srcdest)

        if not self.pkgbuild.is_file():
            raise UpdaterError(f"未找到 PKGBUILD：{self.pkgbuild}")

        self.apply_package_profile()
        current_pkgver = parse_pkgbuild_key(self.pkgbuild, "pkgver")
        if not current_pkgver:
            raise UpdaterError("无法从 PKGBUILD 解析 pkgver")
        current_pkgver = re.sub(r"\s+", "", current_pkgver)
        self.report.current_pkgver = current_pkgver

        current_pkgrel_raw = parse_pkgbuild_key(self.pkgbuild, "pkgrel")
        if not current_pkgrel_raw:
            raise UpdaterError("无法从 PKGBUILD 解析 pkgrel")
        current_pkgrel = re.sub(r"\s+", "", current_pkgrel_raw)
        if not re.fullmatch(r"[0-9]+", current_pkgrel):
            raise UpdaterError("无法从 PKGBUILD 解析数字型 pkgrel")

        pkgbuild_url = parse_pkgbuild_key(self.pkgbuild, "url")
        if not pkgbuild_url:
            raise UpdaterError("无法从 PKGBUILD 解析 url=（用于推断 GitHub 仓库）")

        upstream_repo = self.config.upstream_github_repo or github_repo_from_url(re.sub(r"\s+", "", pkgbuild_url)) or ""
        if not upstream_repo:
            raise UpdaterError("无法确定上游 GitHub 仓库，请设置 upstream_github_repo")
        self.report.upstream_repo = upstream_repo
        log(f"当前 AUR pkgver={current_pkgver}，上游={upstream_repo}")

        release = fetch_latest_github_release(upstream_repo, self.context.github_token)
        latest_tag = release.get("tag_name") or ""
        if not latest_tag:
            raise UpdaterError("GitHub API 返回缺少 tag_name（可能没有 release 或被限流）")
        latest_pkgver = normalize_github_tag_to_pkgver(str(latest_tag))
        if not latest_pkgver:
            raise UpdaterError(f"无法从 tag 解析版本号：{latest_tag}")
        self.report.latest_pkgver = latest_pkgver

        version_changed = latest_pkgver != current_pkgver
        if version_changed:
            log(f"检测到新版本：{current_pkgver} -> {latest_pkgver}")
            self.validate_release_assets(release, latest_pkgver)
            set_pkgbuild_key(self.pkgbuild, "pkgver", latest_pkgver)
            set_pkgbuild_key(self.pkgbuild, "pkgrel", "1")
            self.clear_url_source_cache()
            log("运行 updpkgsums（会下载 release 资产以计算校验和）")
            run(["updpkgsums"], cwd=self.repo_dir, env=self.env)
        else:
            log(f"无需更新版本：上游最新版本仍为 {latest_pkgver}")
            if self.packaging_fix_applied:
                next_pkgrel = str(int(current_pkgrel) + 1)
                log(f"检测到打包修复且上游版本未变：pkgrel {current_pkgrel} -> {next_pkgrel}")
                set_pkgbuild_key(self.pkgbuild, "pkgrel", next_pkgrel)
                current_pkgrel = next_pkgrel

        log("刷新 .SRCINFO")
        srcinfo = run(["makepkg", "--printsrcinfo"], cwd=self.repo_dir, env=self.env, capture_output=True)
        self.srcinfo.write_text(srcinfo.stdout)

        if run(["git", "diff", "--quiet"], cwd=self.repo_dir, check=False).returncode == 0:
            log("无可提交变更")
            self.report.status = "no_change"
            self.report.note = "无可提交变更"
            return

        self.verify_strict_before_push()

        log("变更摘要：")
        stat = run(["git", "diff", "--stat"], cwd=self.repo_dir, check=False, capture_output=True)
        if stat.stdout:
            print(stat.stdout, file=sys.stderr, end="")

        run(["git", "config", "user.name", os.environ.get("GIT_AUTHOR_NAME", "github-actions[bot]")], cwd=self.repo_dir)
        run(
            ["git", "config", "user.email", os.environ.get("GIT_AUTHOR_EMAIL", "github-actions[bot]@users.noreply.github.com")],
            cwd=self.repo_dir,
        )

        run(["git", "add", "PKGBUILD", ".SRCINFO"], cwd=self.repo_dir)
        install_file = self.repo_dir / f"{self.config.name}.install"
        if install_file.is_file():
            run(["git", "add", install_file.name], cwd=self.repo_dir)
        run(["git", "add", "-u"], cwd=self.repo_dir)

        if version_changed:
            commit_msg = f"Update pkgver to {latest_pkgver}"
            self.report.status = "updated"
        elif self.packaging_fix_applied:
            commit_msg = f"Bump pkgrel to {current_pkgrel}"
            self.report.status = "refreshed"
        else:
            commit_msg = "Refresh metadata"
            self.report.status = "refreshed"

        run(["git", "commit", "-m", commit_msg], cwd=self.repo_dir)
        self.report.committed = 1
        rev = run(["git", "rev-parse", "HEAD"], cwd=self.repo_dir, capture_output=True)
        self.report.commit_sha = rev.stdout.strip()

        if self.context.dry_run == 1:
            log("DRY_RUN=1：跳过 push，仅完成本地更新与 commit")
            self.report.note = f"dry-run：{commit_msg}"
            return

        aur_git_ssh_url = os.environ.get("AUR_GIT_SSH_URL", f"aur@aur.archlinux.org:{self.config.name}.git")
        log(f"推送到 AUR：{aur_git_ssh_url} ({self.config.branch})")
        run(["git", "push", "origin", f"HEAD:{self.config.branch}"], cwd=self.repo_dir)
        self.report.pushed = 1
        self.report.note = f"已推送到 AUR：{commit_msg}"
        log("完成")

    def clone_or_update_repo(self) -> None:
        aur_git_ssh_url = os.environ.get("AUR_GIT_SSH_URL", f"aur@aur.archlinux.org:{self.config.name}.git")
        self.context.workdir.mkdir(parents=True, exist_ok=True)
        if (self.repo_dir / ".git").is_dir():
            log(f"更新本地缓存仓库：{self.repo_dir}")
            run(["git", "-C", str(self.repo_dir), "fetch", "--prune", "origin"], env=self.env)
            run(["git", "-C", str(self.repo_dir), "reset", "--hard", f"origin/{self.config.branch}"], env=self.env)
            run(["git", "-C", str(self.repo_dir), "clean", "-fdx"], env=self.env)
            return

        log(f"克隆 AUR 仓库：{aur_git_ssh_url}")
        shallow = run(
            ["git", "clone", "--depth=1", "--branch", self.config.branch, aur_git_ssh_url, str(self.repo_dir)],
            env=self.env,
            check=False,
        )
        if shallow.returncode == 0:
            return
        log("浅克隆失败，改为完整克隆重试")
        if self.repo_dir.exists():
            shutil.rmtree(self.repo_dir)
        run(["git", "clone", aur_git_ssh_url, str(self.repo_dir)], env=self.env)
        run(["git", "checkout", self.config.branch], cwd=self.repo_dir, env=self.env)

    def validate_release_assets(self, release: dict[str, Any], latest_pkgver: str) -> None:
        if self.config.name != "stelliberty-bin":
            return
        asset_names = {str(asset.get("name", "")) for asset in release.get("assets", []) if isinstance(asset, dict)}
        expected = {
            f"Stelliberty-v{latest_pkgver}-linux-x64.zip",
            f"Stelliberty-v{latest_pkgver}-linux-arm64.zip",
        }
        missing = sorted(expected - asset_names)
        if missing:
            raise UpdaterError(f"上游 release 缺少资产：{', '.join(missing)}（为避免推送坏包，已终止）")

    def apply_package_profile(self) -> None:
        if self.config.name == "stelliberty-bin":
            self.apply_stelliberty_profile()

    def mark_profile_change(self, changed: bool) -> None:
        if changed:
            self.packaging_fix_applied = True

    def apply_stelliberty_profile(self) -> None:
        install_file = self.repo_dir / f"{self.config.name}.install"

        self.mark_profile_change(
            replace_text(
                self.pkgbuild,
                '"LICENSE::https://raw.githubusercontent.com/Kindness-Kismet/Stelliberty/v${pkgver}/LICENSE"',
                '"LICENSE-v${pkgver}::https://raw.githubusercontent.com/Kindness-Kismet/Stelliberty/v${pkgver}/LICENSE"',
            )
        )
        self.mark_profile_change(
            replace_text(
                self.pkgbuild,
                'install -Dm644 "${srcdir}/LICENSE" "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"',
                'install -Dm644 "${srcdir}/LICENSE-v${pkgver}" "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"',
            )
        )

        content = self.pkgbuild.read_text()
        if re.search(
            r"^depends=\(|libappindicator-gtk3|util-linux-libs|^[ \t]*'xz'|^[ \t]*'nss'|^[ \t]*'openssl'|^[ \t]*'libdbusmenu-gtk3'",
            content,
            flags=re.MULTILINE,
        ):
            self.mark_profile_change(
                regex_replace(
                    self.pkgbuild,
                    r"^depends=\((?:[^()]|\n)*?\)",
                    "depends=(\n  'gtk3'\n  'libkeybinder3'\n  'libappindicator'\n  'rsync'\n)",
                    flags=re.MULTILINE,
                )
            )

        self.mark_profile_change(
            regex_replace(
                self.pkgbuild,
                r"""ensure_exec\(\) \{
  local file="\$1"
  if \[\[ -f "\$\{file\}" && ! -x "\$\{file\}" \]\]; then
    chmod 755 "\$\{file\}"
  fi
\}""",
                """ensure_exec() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    printf 'stelliberty: required file not found: %s\\n' "${file}" >&2
    exit 1
  fi
  if [[ ! -x "${file}" ]]; then
    chmod 755 "${file}"
  fi
}""",
                flags=re.MULTILINE,
            )
        )

        if re.search(r"assets/clash-core/clash-core|assets/clash/clash-core", self.pkgbuild.read_text()):
            self.mark_profile_change(
                regex_replace(
                    self.pkgbuild,
                    r"""  chmod \+x "\$\{_install_dir\}/stelliberty"
  chmod \+x "\$\{_install_dir\}/data/flutter_assets/assets/service/stelliberty-service"
  if \[\[ -f "\$\{_install_dir\}/data/flutter_assets/assets/clash(?:-core)?/clash-core" \]\]; then
    chmod 755 "\$\{_install_dir\}/data/flutter_assets/assets/clash(?:-core)?/clash-core"
  fi""",
                    """  chmod +x "${_install_dir}/stelliberty"
  chmod +x "${_install_dir}/data/flutter_assets/assets/service/stelliberty-service"

  local _clash_core="${_install_dir}/data/flutter_assets/assets/clash/clash-core"
  if [[ -f "${_clash_core}" ]]; then
    chmod 755 "${_clash_core}"
  else
    echo "Missing clash core: ${_clash_core}" >&2
    return 1
  fi""",
                    flags=re.MULTILINE,
                )
            )
            self.mark_profile_change(
                replace_text(
                    self.pkgbuild,
                    "assets/clash-core/clash-core",
                    "assets/clash/clash-core",
                )
            )

        self.mark_profile_change(
            regex_replace(
                self.pkgbuild,
                r"optdepends=\('xdg-utils: for xdg-open support'\)",
                "optdepends=(\n  'xdg-utils: for xdg-open support'\n  'polkit: for pkexec-based service installation from the UI'\n)",
            )
        )

        if f"install={install_file.name}" not in self.pkgbuild.read_text():
            self.mark_profile_change(
                regex_replace(
                    self.pkgbuild,
                    r"^license=\('LicenseRef-Stelliberty'\)$",
                    f"license=('LicenseRef-Stelliberty')\ninstall={install_file.name}",
                    flags=re.MULTILINE,
                )
            )

        if '  printf \'%s\\n\' "${pkgver}-${pkgrel}" > "${_install_dir}/data/.package-sync-revision"' in self.pkgbuild.read_text():
            self.mark_profile_change(
                regex_replace(
                    self.pkgbuild,
                    r"""(  rm -f "\$\{_install_dir\}/data/\.portable"
  printf '%s\\n' "\$\{pkgver\}-\$\{pkgrel\}" > "\$\{_install_dir\}/data/\.package-sync-revision"
){2,}""",
                    """  rm -f "${_install_dir}/data/.portable"
  printf '%s\\n' "${pkgver}-${pkgrel}" > "${_install_dir}/data/.package-sync-revision"
""",
                    flags=re.MULTILINE,
                )
            )
        else:
            self.mark_profile_change(
                regex_replace(
                    self.pkgbuild,
                    r'''  bsdtar -xf "\$\{srcdir\}/\$\{_archive\}" -C "\$\{_install_dir\}"''',
                    '''  bsdtar -xf "${srcdir}/${_archive}" -C "${_install_dir}"
  rm -f "${_install_dir}/data/.portable"
  printf '%s\\n' "${pkgver}-${pkgrel}" > "${_install_dir}/data/.package-sync-revision"''',
                    flags=re.MULTILINE,
                )
            )

        self.mark_profile_change(
            regex_replace(
                self.pkgbuild,
                r"""sync_app\(\) \{
  install -d "\$\{user_dir\}"
  rsync -a --delete \\
    --exclude 'data/subscriptions' \\
    --exclude 'data/subscriptions/\*\*\*' \\
    --exclude 'data/overrides' \\
    --exclude 'data/overrides/\*\*\*' \\
    --exclude 'data/running\.logs\*' \\
    "\$\{system_dir\}/" "\$\{user_dir\}/"
\}""",
                """sync_app() {
  install -d "${user_dir}"

  local -a preserve_patterns=(
    'data/subscriptions'
    'data/subscriptions/***'
    'data/subscriptions_list.json'
    'data/overrides'
    'data/overrides/***'
    'data/overrides_list.json'
    'data/image_cache'
    'data/image_cache/***'
    'data/dns_config.yaml'
    'data/stelliberty_proxy.pac'
    'data/settings_preferences.json'
    'data/settings_preferences_dev.json'
    'data/running.logs*'
    'data/runtime'
    'data/runtime/***'
  )

  local -a rsync_args=(-a --delete)
  local pattern
  for pattern in "${preserve_patterns[@]}"; do
    rsync_args+=(--exclude "${pattern}")
  done

  rsync "${rsync_args[@]}" "${system_dir}/" "${user_dir}/"
}""",
                flags=re.MULTILINE,
            )
        )

        self.mark_profile_change(
            replace_text(
                self.pkgbuild,
                'data_root="${XDG_DATA_HOME:-${HOME}/.local/share}/stelliberty"',
                '# Allow overriding the app data root when HOME/XDG_DATA_HOME contains unsupported characters.\n'
                'data_root="${STELLIBERTY_DATA_ROOT:-${XDG_DATA_HOME:-${HOME}/.local/share}/stelliberty}"',
            )
        )

        content = self.pkgbuild.read_text()
        if "token_of() {" not in content and "sync_app() {" in content:
            self.mark_profile_change(
                replace_text(
                    self.pkgbuild,
                    "\n\nsync_app() {",
                    '\n\ntoken_of() {\n  local file="$1"\n  if [[ -r "$file" ]]; then\n    head -n1 "$file"\n  fi\n}\n\nsync_app() {',
                )
            )

        self.mark_profile_change(
            regex_replace(
                self.pkgbuild,
                r"""sys_ver="\$\(version_of "\$\{system_dir\}/data/flutter_assets/version\.json"\)"
usr_ver="\$\(version_of "\$\{user_dir\}/data/flutter_assets/version\.json"\)"

if \[\[ "\$\{usr_ver:-\}" != "\$\{sys_ver:-\}" \]\]; then
  sync_app
fi""",
                """sys_ver="$(version_of "${system_dir}/data/flutter_assets/version.json")"
usr_ver="$(version_of "${user_dir}/data/flutter_assets/version.json")"
sys_sync_revision="$(token_of "${system_dir}/data/.package-sync-revision")"
usr_sync_revision="$(token_of "${user_dir}/data/.package-sync-revision")"

if [[ "${usr_ver:-}" != "${sys_ver:-}" || "${usr_sync_revision:-}" != "${sys_sync_revision:-}" ]]; then
  sync_app
fi""",
                flags=re.MULTILINE,
            )
        )

        install_script = """post_install() {
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
"""
        if not install_file.exists() or install_file.read_text() != install_script:
            install_file.write_text(install_script)
            self.packaging_fix_applied = True

        if self.packaging_fix_applied:
            log("已规范 stelliberty-bin PKGBUILD：修正 LICENSE、clash core、.portable、optdepends、install 脚本与用户数据同步策略")

    def clear_url_source_cache(self) -> None:
        log("清理 URL source 缓存（避免同名文件跨版本复用）")
        result = run(["makepkg", "--printsrcinfo"], cwd=self.repo_dir, env=self.env, capture_output=True)
        removed_count = 0
        for line in result.stdout.splitlines():
            match = re.match(r"^\s*source(?:_[A-Za-z0-9_]+)? = (.*)$", line)
            if not match:
                continue
            src_entry = match.group(1)
            src_name = ""
            src_url = src_entry
            if "::" in src_entry:
                src_name, src_url = src_entry.split("::", 1)
            elif src_entry.startswith(("http://", "https://")):
                src_name = src_entry.rsplit("/", 1)[-1].split("?", 1)[0]
            if not src_url.startswith(("http://", "https://")) or not src_name:
                continue
            for candidate in (self.repo_dir / src_name, Path(self.env["SRCDEST"]) / src_name):
                if candidate.is_file():
                    candidate.unlink()
                    removed_count += 1
        log(f"URL source 缓存清理完成：{removed_count} 个文件")

    def verify_strict_before_push(self) -> None:
        log("开始强验证（推送前必须通过）")
        log("校验 .SRCINFO 与 PKGBUILD 一致性")
        generated = run(["makepkg", "--printsrcinfo"], cwd=self.repo_dir, env=self.env, capture_output=True).stdout
        existing = self.srcinfo.read_text() if self.srcinfo.exists() else ""
        if generated != existing:
            log(".SRCINFO 与 PKGBUILD 不一致，差异如下：")
            diff = difflib.unified_diff(
                existing.splitlines(keepends=True),
                generated.splitlines(keepends=True),
                fromfile=".SRCINFO",
                tofile="generated .SRCINFO",
            )
            print("".join(diff), file=sys.stderr)
            raise UpdaterError("强验证失败：.SRCINFO 与 PKGBUILD 不一致")

        log("校验 source 校验和（makepkg --verifysource）")
        run(["makepkg", "--verifysource"], cwd=self.repo_dir, env=self.env)

        log("额外校验 aarch64 资产的 sha256（避免仅在 x86_64 更新导致 aarch64 校验和漂移）")
        srcinfo_lines = existing.splitlines()
        aarch64_source_line = next((line for line in srcinfo_lines if re.match(r"^\s*source_aarch64 = ", line)), "")
        aarch64_sum_line = next((line for line in srcinfo_lines if re.match(r"^\s*sha256sums_aarch64 = ", line)), "")
        if not aarch64_source_line or not aarch64_sum_line:
            raise UpdaterError("强验证失败：未在 .SRCINFO 中找到 source_aarch64/sha256sums_aarch64")
        aarch64_src = aarch64_source_line.split(" = ", 1)[1]
        aarch64_sum = aarch64_sum_line.split(" = ", 1)[1]
        if "::" not in aarch64_src:
            raise UpdaterError(f"强验证失败：source_aarch64 未包含 URL（期望格式 name::url），实际：{aarch64_src}")
        aarch64_url = aarch64_src.split("::", 1)[1]
        aarch64_actual = hashlib.sha256(download_bytes(aarch64_url)).hexdigest()
        if aarch64_actual != aarch64_sum:
            raise UpdaterError(f"强验证失败：aarch64 资产 sha256 不匹配（期望 {aarch64_sum}，实际 {aarch64_actual}）")

        log("安装 depends/makedepends/checkdepends（强验证要求完整构建）")
        deps = set()
        for line in srcinfo_lines:
            match = re.match(r"^\s*(?:depends|makedepends|checkdepends) = (.*)$", line)
            if not match:
                continue
            dep = normalize_dep_pkgname(match.group(1))
            if dep:
                deps.add(dep)
        if deps:
            run(["sudo", "pacman", "-S", "--noconfirm", "--needed", *sorted(deps)], cwd=self.repo_dir, env=self.env)

        log("完整构建并运行 check()（makepkg --cleanbuild）")
        run(["makepkg", "--noconfirm", "--clean", "--cleanbuild"], cwd=self.repo_dir, env=self.env)

        log("校验构建产物存在")
        pkgfiles = sorted(Path(path) for path in glob.glob(str(self.repo_dir / "*.pkg.tar.*")))
        if not pkgfiles:
            raise UpdaterError("强验证失败：构建未产出 *.pkg.tar.*")

        log("验证产物包可读取（bsdtar -tf）")
        for pkgfile in pkgfiles:
            run(["bsdtar", "-tf", pkgfile.name], cwd=self.repo_dir, env=self.env)

        self.verify_namcap(pkgfiles)
        log("强验证通过")

    def verify_namcap(self, pkgfiles: list[Path]) -> None:
        log("运行 namcap lint（对 PKGBUILD 和产物包；E 失败，W 记录）")
        namcap_pkgbuild = run(["namcap", "PKGBUILD"], cwd=self.repo_dir, env=self.env, check=False, capture_output=True)
        namcap_out = (namcap_pkgbuild.stdout or "") + (namcap_pkgbuild.stderr or "")
        allowed = re.compile(r"^PKGBUILD .* W: Reference to x86_64 should be changed to [$]CARCH$", re.MULTILINE)
        filtered = "\n".join(line for line in namcap_out.splitlines() if not allowed.match(line))
        if re.search(r" E: ", filtered):
            print(namcap_out, file=sys.stderr, end="")
            raise UpdaterError("强验证失败：namcap 在 PKGBUILD 上报告 E")
        if re.search(r" W: ", filtered):
            print(namcap_out, file=sys.stderr, end="")
            raise UpdaterError("强验证失败：namcap 在 PKGBUILD 上报告未允许的 W")
        if re.search(r" (W|E): ", namcap_out):
            log("namcap 在 PKGBUILD 上报告了允许的警告（已放行）：")
            print(namcap_out, file=sys.stderr, end="")

        pkg_w_count = 0
        for pkgfile in pkgfiles:
            result = run(["namcap", pkgfile.name], cwd=self.repo_dir, env=self.env, check=False, capture_output=True)
            output = (result.stdout or "") + (result.stderr or "")
            if re.search(r" E: ", output):
                print(output, file=sys.stderr, end="")
                raise UpdaterError(f"强验证失败：namcap 在产物包 {pkgfile.name} 上报告 E")
            if re.search(r" W: ", output):
                pkg_w_count += 1
                log(f"namcap 在产物包 {pkgfile.name} 上报告了 W（不阻塞，但会写入日志与报告）")
                print(output, file=sys.stderr, end="")
        if pkg_w_count > 0:
            self.append_note(f"namcap(W) in package artifacts={pkg_w_count}")


def load_config(path: Path) -> list[PackageConfig]:
    if not path.is_file():
        raise UpdaterError(f"未找到配置文件：{path}")
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise UpdaterError(f"配置文件不是合法 JSON：{path} ({exc})") from exc
    packages = data.get("packages")
    if not isinstance(packages, list):
        raise UpdaterError("配置文件格式错误：.packages 不是数组")
    result: list[PackageConfig] = []
    for index, item in enumerate(packages):
        if not isinstance(item, dict):
            raise UpdaterError(f"配置文件第 {index} 项不是对象")
        name = str(item.get("name") or "")
        if not name:
            raise UpdaterError(f"配置文件第 {index} 项缺少 name")
        result.append(
            PackageConfig(
                name=name,
                branch=str(item.get("branch") or "master"),
                upstream_github_repo=str(item.get("upstream_github_repo") or ""),
            )
        )
    return result


def write_no_match_report(context: RunContext, pkgname: str) -> None:
    context.report_json.parent.mkdir(parents=True, exist_ok=True)
    report = PackageReport(
        started_at=utc_now(),
        finished_at=utc_now(),
        pkgname=pkgname,
        branch="-",
        status="no_match",
        note=f"ONLY_PKGNAME={pkgname} 未匹配 config/packages.json 中的包，未执行更新",
        dry_run=context.dry_run,
        exit_code=0,
    )
    with context.report_json.open("a", encoding="utf-8") as handle:
        handle.write(report.to_json())
        handle.write("\n")


def run_all(args: argparse.Namespace) -> int:
    repo_root = Path.cwd()
    config_path = Path(os.environ.get("PACKAGES_CONFIG", args.config)).resolve()
    workdir = Path(os.environ.get("WORKDIR", str(repo_root / "_work"))).resolve()
    report_json = Path(os.environ.get("REPORT_JSON", str(workdir / "report.jsonl"))).resolve()
    dry_run = bool_to_int(os.environ.get("DRY_RUN", "0"))
    only_pkgname = os.environ.get("ONLY_PKGNAME", "")

    workdir.mkdir(parents=True, exist_ok=True)
    report_json.parent.mkdir(parents=True, exist_ok=True)
    report_json.write_text("")

    packages = load_config(config_path)
    if not packages:
        log("配置文件中 packages 为空，跳过")
        return 0

    matched_packages = [package for package in packages if not only_pkgname or only_pkgname == package.name]
    if only_pkgname and not matched_packages:
        context = RunContext(
            repo_root=repo_root,
            workdir=workdir,
            report_json=report_json,
            dry_run=dry_run,
            github_token=os.environ.get("GITHUB_TOKEN") or None,
        )
        log(f"未找到指定包：{only_pkgname}")
        write_no_match_report(context, only_pkgname)
        return 0

    for command in ("git", "sudo", "namcap", "bsdtar", "updpkgsums", "makepkg"):
        need_cmd(command)

    context = RunContext(
        repo_root=repo_root,
        workdir=workdir,
        report_json=report_json,
        dry_run=dry_run,
        github_token=os.environ.get("GITHUB_TOKEN") or None,
    )

    for package in packages:
        if only_pkgname and only_pkgname != package.name:
            log(f"跳过 {package.name}（ONLY_PKGNAME={only_pkgname}）")
            continue
        log(f"开始更新：{package.name}")
        updater = PackageUpdater(package, context)
        updater.run_package()
        log(f"完成更新：{package.name}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Update configured AUR packages from GitHub releases.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    run_all_parser = subparsers.add_parser("run-all", help="update all configured packages")
    run_all_parser.add_argument("--config", default="config/packages.json", help="packages config path")
    run_all_parser.set_defaults(func=run_all)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except UpdaterError as exc:
        log(f"ERROR: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
