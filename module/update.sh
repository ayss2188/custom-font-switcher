#!/system/bin/sh
# 自定义字体切换模块 - GitHub 在线更新（在手机本地下载并安装，不用电脑）
# 更新信息来自 module.prop 里的 updateJson（GitHub 仓库里的 update.json），
# Magisk / KernelSU / APatch 管理器也会用同一个地址显示"有更新"。
#
# 用法：
#   sh update.sh check       输出 CUR_VER= CUR_CODE= NEW_VER= NEW_CODE= HAS= ERR=
#   sh update.sh changelog   输出更新日志正文
#   sh update.sh install     下载新版刷机包、校验后用当前 Root 管理器安装（重启生效）

MODDIR=$(cd "$(dirname "$0")" && pwd)
. "$MODDIR/common.sh"
TMP="$LIB/.update"
mkdir -p "$TMP" 2>/dev/null

prop() { sed -n "s/^$1=//p" "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r'; }

# fetch <地址> <输出文件>：curl 优先，其次管理器自带 busybox 的 wget
fetch() {
  local url bb
  url="$1"
  rm -f "$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 -m 300 -o "$2" "$url" 2>/dev/null && [ -s "$2" ] && return 0
  fi
  bb=$(find_busybox)
  if [ -n "$bb" ]; then
    "$bb" wget -q -T 30 -O "$2" "$url" 2>/dev/null && [ -s "$2" ] && return 0
  fi
  command -v wget >/dev/null 2>&1 && wget -q -T 30 -O "$2" "$url" 2>/dev/null && [ -s "$2" ] && return 0
  rm -f "$2"
  return 1
}

# 简易 JSON 取值（update.json 结构固定，不需要完整解析器）
jstr() { tr -d '\r\n' < "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"; }
jnum() { tr -d '\r\n' < "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p"; }

load_json() {
  local url
  url=$(prop updateJson)
  case "$url" in
    https://*) ;;
    *) ERR="module.prop 里没有配置 updateJson"; return 1 ;;
  esac
  case "$url" in *__REPO__*) ERR="作者还没有配置 GitHub 仓库地址"; return 1 ;; esac
  fetch "$url" "$TMP/update.json" || { ERR="无法连接 GitHub，请检查网络后重试"; return 1; }
  NEW_VER=$(jstr version "$TMP/update.json")
  NEW_CODE=$(jnum versionCode "$TMP/update.json")
  ZIP_URL=$(jstr zipUrl "$TMP/update.json")
  LOG_URL=$(jstr changelog "$TMP/update.json")
  SHA=$(jstr sha256 "$TMP/update.json")
  [ -n "$NEW_CODE" ] && [ -n "$ZIP_URL" ] || { ERR="update.json 格式不正确"; NEW_CODE=""; return 1; }
  return 0
}

CUR_VER=$(prop version)
CUR_CODE=$(prop versionCode)
ERR=""

case "${1:-check}" in
  check)
    HAS=0
    if load_json && [ "$NEW_CODE" -gt "${CUR_CODE:-0}" ] 2>/dev/null; then HAS=1; fi
    echo "CUR_VER='$CUR_VER'"
    echo "CUR_CODE='$CUR_CODE'"
    echo "NEW_VER='$NEW_VER'"
    echo "NEW_CODE='$NEW_CODE'"
    echo "HAS='$HAS'"
    echo "ERR='$ERR'"
    ;;
  changelog)
    load_json || { echo "ERROR:$ERR"; exit 1; }
    [ -n "$LOG_URL" ] || { echo "ERROR:update.json 里没有 changelog 地址"; exit 1; }
    fetch "$LOG_URL" "$TMP/changelog.md" || { echo "ERROR:下载更新日志失败"; exit 1; }
    head -c 30000 "$TMP/changelog.md"
    ;;
  install)
    load_json || { echo "ERROR:$ERR"; exit 1; }
    [ "$NEW_CODE" -gt "${CUR_CODE:-0}" ] 2>/dev/null || [ "$2" = force ] || { echo "ERROR:已是最新版本"; exit 1; }
    ZIP="$TMP/module.zip"
    fetch "$ZIP_URL" "$ZIP" || { echo "ERROR:下载刷机包失败，请检查网络后重试"; exit 1; }

    # 校验：是 zip、体积合理、sha256 一致、模块 id 一致
    [ "$(head -c 2 "$ZIP")" = PK ] || { rm -f "$ZIP"; echo "ERROR:下载的文件不是 zip（网络可能返回了错误页面）"; exit 1; }
    [ "$(wc -c < "$ZIP")" -gt 10240 ] || { rm -f "$ZIP"; echo "ERROR:下载的文件不完整"; exit 1; }
    if [ -n "$SHA" ] && command -v sha256sum >/dev/null 2>&1; then
      [ "$(sha256sum "$ZIP" | cut -d' ' -f1)" = "$SHA" ] || { rm -f "$ZIP"; echo "ERROR:校验失败（sha256 不一致），已取消安装"; exit 1; }
    fi
    if command -v unzip >/dev/null 2>&1; then
      NID=$(unzip -p "$ZIP" module.prop 2>/dev/null | sed -n 's/^id=//p' | head -n1 | tr -d '\r')
      [ -z "$NID" ] || [ "$NID" = "$(prop id)" ] || { rm -f "$ZIP"; echo "ERROR:刷机包的模块 ID 不一致（$NID），已取消安装"; exit 1; }
    fi

    case "$(root_manager)" in
      magisk) magisk --install-module "$ZIP" > "$TMP/install.log" 2>&1 ;;
      ksu)    /data/adb/ksud module install "$ZIP" > "$TMP/install.log" 2>&1 ;;
      apatch) /data/adb/apd module install "$ZIP" > "$TMP/install.log" 2>&1 ;;
      *) echo "ERROR:无法识别 Root 管理器，请手动安装：$ZIP"; exit 1 ;;
    esac
    rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$ZIP"
      echo "OK:$NEW_VER"
    else
      echo "ERROR:安装失败（$(tail -n 3 "$TMP/install.log" | tr '\n' ' ')）"
      exit 1
    fi
    ;;
  *)
    echo "用法: sh update.sh check|changelog|install"
    exit 2
    ;;
esac
