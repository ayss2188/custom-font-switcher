#!/bin/sh
# 把仓库里所有的 __REPO__ 占位符替换成你的 GitHub 仓库（只需要运行一次）
# 用法：sh scripts/set-repo.sh 你的用户名/custom-font-switcher
set -e
REPO="$1"
case "$REPO" in
  */*) ;;
  *) echo "用法: sh scripts/set-repo.sh 用户名/仓库名" >&2; exit 1 ;;
esac
case "$REPO" in *[!A-Za-z0-9/._-]*) echo "仓库名含非法字符" >&2; exit 1 ;; esac
ROOT=$(cd "$(dirname "$0")/.." && pwd)
for f in module/module.prop update.json README.md "docs/酷安帖子.md"; do
  [ -f "$ROOT/$f" ] || continue
  if grep -q '__REPO__' "$ROOT/$f"; then
    sed -i.bak "s#__REPO__#$REPO#g" "$ROOT/$f" && rm -f "$ROOT/$f.bak"
    echo "已更新 $f"
  fi
done
