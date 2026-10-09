#!/system/bin/sh
# 自定义字体切换模块 - 谷歌字体兼容（停用 GMS FontsProvider，立即生效）
# 解决 Chrome / Gmail 等应用英数被 GMS 下载字体覆盖、又恢复默认的问题。
# 仅停用 com.google.android.gms 的 FontsProvider 组件，不卸载、不清缓存、不动账户。
# 只有本模块停用的才会由本模块恢复（记录在字体库目录 .gms_owned），卸载模块时自动恢复。
# 用法：sh google_font.sh status|enable|restore|uninstall

MODDIR=${0%/*}
LIB=/data/adb/custom_font_lib
OWNED="$LIB/.gms_owned"
GMS="com.google.android.gms"
PROVIDER="com.google.android.gms.fonts.provider.FontsProvider"
COMPONENT="$GMS/$PROVIDER"

# 尽量用完整路径，避免 ksu.exec 环境下 PATH 不全
PM="/system/bin/pm";   [ -x "$PM" ] || PM="$(command -v pm 2>/dev/null)"
DUMP="/system/bin/dumpsys"; [ -x "$DUMP" ] || DUMP="$(command -v dumpsys 2>/dev/null)"
AM="/system/bin/am";   [ -x "$AM" ] || AM="$(command -v am 2>/dev/null)"

[ "$(id -u)" = "0" ] || { echo '需要 Root 权限'; exit 1; }

has_gms() { [ -n "$PM" ] && "$PM" path "$GMS" >/dev/null 2>&1; }

# 判断组件当前是否被停用
is_disabled() {
  [ -n "$DUMP" ] && "$DUMP" package "$GMS" 2>/dev/null | grep -i -A60 "disabledComponents" | grep -q "$PROVIDER" && return 0
  return 1
}

# 刷新 GMS / 谷歌商店进程，让已缓存的下载字体失效
flush_google() {
  [ -n "$AM" ] && "$AM" force-stop "$GMS" >/dev/null 2>&1
  [ -n "$AM" ] && "$AM" force-stop com.android.vending >/dev/null 2>&1
}

do_restore() {
  local pm_out rc
  pm_out=$("$PM" enable --user 0 "$COMPONENT" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && ! printf '%s' "$pm_out" | grep -q "new state"; then
    pm_out=$("$PM" default-state --user 0 "$COMPONENT" 2>&1); rc=$?
  fi
  if [ "$rc" -eq 0 ] || printf '%s' "$pm_out" | grep -q "new state"; then
    rm -f "$OWNED"
    flush_google
    echo "OK：已关闭谷歌字体兼容"
    return 0
  fi
  echo "警告：恢复失败（$pm_out）"
  return 1
}

case "${1:-status}" in
  status)
    if ! has_gms; then echo "nogms"
    elif is_disabled; then echo "on"
    else echo "off"; fi
    ;;
  enable)
    has_gms || { echo "未检测到 Google Play 服务，无需开启"; exit 0; }
    if is_disabled; then
      # 已经是停用状态（用户自己或其他工具停用的），不记为本模块所有
      echo "OK：谷歌字体兼容本来就是开启状态"
      exit 0
    fi
    pm_out=$("$PM" disable --user 0 "$COMPONENT" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && ! printf '%s' "$pm_out" | grep -q "new state"; then
      pm_out=$("$PM" disable-user --user 0 "$COMPONENT" 2>&1); rc=$?
    fi
    if [ "$rc" -eq 0 ] || printf '%s' "$pm_out" | grep -q "new state"; then
      mkdir -p "$LIB" 2>/dev/null
      date +%s > "$OWNED"
      flush_google
      echo "OK：已开启谷歌字体兼容"
    else
      echo "警告：停用失败（$pm_out）"
    fi
    ;;
  restore)
    has_gms || { echo "未检测到 Google Play 服务"; exit 0; }
    do_restore
    ;;
  uninstall)
    # 卸载模块时：只恢复本模块自己停用的组件
    [ -f "$OWNED" ] || exit 0
    has_gms || { rm -f "$OWNED"; exit 0; }
    do_restore >/dev/null 2>&1
    ;;
  *)
    echo "用法: sh google_font.sh status|enable|restore|uninstall"
    exit 2
    ;;
esac
