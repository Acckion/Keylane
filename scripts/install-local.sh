#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

target=/Applications/Keylane.app
if [[ $# -ne 0 ]]; then
  echo '用法：bash scripts/install-local.sh' >&2
  exit 2
fi

unset KEYLANE_ALLOW_ADHOC KEYLANE_DISTRIBUTION
KEYLANE_SIGNING_IDENTITY="$(PYTHONPATH=scripts python3 - <<'PY'
from contextlib import redirect_stdout
import sys
from signing import signing_identity

with redirect_stdout(sys.stderr):
    identity = signing_identity(require_apple_development=True)
print(identity)
PY
)"
export KEYLANE_SIGNING_IDENTITY

version="$(PYTHONPATH=scripts python3 -c 'from versioning import load_version; print(load_version()["version"])')"
image="$PWD/dist/Keylane-$version-macos-$(uname -m).dmg"
stage=/Applications/.keylane-local-install
if ! mkdir "$stage"; then
  echo '无法创建安装目录。请检查应用程序目录权限，以及是否已有安装正在进行。' >&2
  exit 1
fi

mount_dir=''
mounted=0
replacing=0
committed=0
had_running_app=0

running_pids() {
  ps -axo pid=,comm= | awk -v executable="$target/Contents/MacOS/Keylane" '$2 == executable {print $1}'
}

stop_app() {
  local pids
  pids="$(running_pids)"
  if [[ -z "$pids" ]]; then return; fi
  while read -r pid; do
    kill -TERM "$pid" 2>/dev/null || true
  done <<< "$pids"
  for _ in {1..30}; do
    [[ -n "$(running_pids)" ]] || return 0
    sleep 0.2
  done
  return 1
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$replacing" == 1 && "$committed" == 0 ]]; then
    if [[ ! -e "$stage/Keylane.app" && -d "$target" ]]; then
      if ! stop_app || ! mv "$target" "$stage/Keylane.app"; then
        echo "无法移走新版本。旧版保存在 $stage/previous.app 或本地备份目录。" >&2
        exit 1
      fi
    fi
    if [[ -d "$stage/previous.app" ]]; then
      if ! mv "$stage/previous.app" "$target"; then
        echo "自动恢复失败。旧版保存在 $stage/previous.app。" >&2
        exit 1
      fi
    fi
    if [[ "$had_running_app" == 1 && -d "$target" ]]; then open -a "$target" || true; fi
  fi
  if [[ "$mounted" == 1 ]]; then hdiutil detach "$mount_dir" >/dev/null || true; fi
  if [[ -n "$mount_dir" ]]; then rmdir "$mount_dir" 2>/dev/null || true; fi
  rm -rf "$stage"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bash scripts/package.sh
python3 scripts/verify-package.py "$image"
mount_dir="$(mktemp -d /private/tmp/keylane-local.XXXXXX)"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$image" >/dev/null
mounted=1
ditto "$mount_dir/Keylane.app" "$stage/Keylane.app"
hdiutil detach "$mount_dir" >/dev/null
mounted=0

codesign --verify --deep --strict "$stage/Keylane.app"
signature="$(codesign -dv --verbose=2 "$stage/Keylane.app" 2>&1)"
if ! grep -q '^Authority=Apple Development:' <<< "$signature"; then
  echo '安装包未使用 Apple Development 签名。' >&2
  exit 1
fi

backup=''
if [[ -L "$target" || ( -e "$target" && ! -d "$target" ) ]]; then
  echo "$target 不是普通应用目录，无法覆盖安装。" >&2
  exit 1
fi
if [[ -d "$target" ]]; then
  mkdir -p dist/local-backups
  backup="$(mktemp -d "$PWD/dist/local-backups/$(date +%Y%m%d-%H%M%S).XXXXXX")/Keylane.app"
  ditto "$target" "$backup"
fi

if [[ -n "$(running_pids)" ]]; then had_running_app=1; fi
replacing=1
if ! stop_app; then
  echo 'Keylane 未退出，请先退出应用后重试。' >&2
  exit 1
fi
if [[ -d "$target" ]]; then mv "$target" "$stage/previous.app"; fi
mv "$stage/Keylane.app" "$target"
codesign --verify --deep --strict "$target"
open -a "$target"
sleep 3
if [[ -z "$(running_pids)" ]]; then
  echo '新版本未能启动，正在恢复上一版。' >&2
  exit 1
fi
committed=1

echo "Keylane $version 已安装并启动，Apple Development 签名已验证。"
if [[ -n "$backup" ]]; then echo "上一版备份位于 $backup"; fi
