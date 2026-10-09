#!/bin/sh
# 打包刷机包：把 module/ 目录里的内容打成 dist/custom-font-switcher.zip
# 用法（Linux / macOS / GitHub Actions）：sh scripts/build.sh
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/dist/custom-font-switcher.zip"
mkdir -p "$ROOT/dist"
rm -f "$OUT"

# 刷机脚本必须是 LF 换行，CRLF 会导致手机上 sh 报错
CR=$(printf '\r')
if grep -rlI "$CR" "$ROOT/module" >/dev/null 2>&1; then
  echo "错误：以下文件含 Windows 换行（CRLF），请转换为 LF：" >&2
  grep -rlI "$CR" "$ROOT/module" >&2
  exit 1
fi

cd "$ROOT/module"
zip -r -9 -X "$OUT" . -x '*.DS_Store' >/dev/null
echo "已生成：$OUT"
