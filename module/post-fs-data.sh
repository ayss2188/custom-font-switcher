#!/system/bin/sh
# post-fs-data：开机保护 + Magisk 下的自带挂载
#
# 开机保护：如果上次选了字体后没能开机成功（没走到 boot_completed），
# 这次自动撤掉所有字体文件并恢复为「无字体」，避免一直卡开机。
# 注意：这是尽力而为的保护，最坏情况下需要再重启一次才会恢复。

MODDIR=${0%/*}
. "$MODDIR/common.sh"
. "$MODDIR/mount.sh"

rm -f "$MODDIR/mount_missed"

if [ -f "$MODDIR/.booting" ]; then
  if [ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" = manager ] && [ -f "$MODDIR/slots.applied" ]; then
    # 管理器挂载在 post-fs-data 之后才进行，删掉文件即可让它这次不挂载
    while IFS= read -r rel || [ -n "$rel" ]; do
      rel=$(printf '%s' "$rel" | tr -d '\r')
      case "$rel" in ""|/*|*..*) continue ;; esac
      rm -f "$MODDIR/$(mgr_path "$rel")" 2>/dev/null
    done < "$MODDIR/slots.applied"
  fi
  rm -rf "$MODDIR/payload"
  mkdir -p "$MODDIR/payload"
  : > "$MODDIR/slots.applied"
  : > "$MODDIR/slots.map"
  echo none > "$MODDIR/pending_font"
  echo none > "$MODDIR/active_font"
  echo none > "$LIB/last_selection" 2>/dev/null
  touch "$MODDIR/rescued"
  rm -f "$MODDIR/.booting"
  exit 0
fi

# 只有真的应用了字体才需要看守
P=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font")
case "$P" in ""|none) exit 0 ;; esac
touch "$MODDIR/.booting"

# 自带挂载：Magisk 在这里挂；KernelSU / APatch 交给 post-mount.sh
[ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" = manager ] && exit 0
case "$(root_manager)" in
  ksu|apatch) exit 0 ;;
esac
payload_mount "$MODDIR" post-fs-data
