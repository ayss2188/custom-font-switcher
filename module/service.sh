#!/system/bin/sh
# 开机完成后：撤掉开机保护标记，把 pending_font 确认为 active_font，并检查挂载是否执行

MODDIR=${0%/*}
. "$MODDIR/common.sh"

while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done

rm -f "$MODDIR/.booting"

# 自带挂载模式下选了字体，但本次开机没有挂载记录 -> 提示用户（多为管理器不支持 post-mount）
P=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font")
case "$P" in
  ""|none) ;;
  *)
    if [ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" != manager ] && \
       [ "$(sed -n 's/^boot=//p' "$MODDIR/mount.state" 2>/dev/null)" != "$(boot_id)" ]; then
      touch "$MODDIR/mount_missed"
    fi
    ;;
esac

sh "$MODDIR/fontctl.sh" sync
sh "$MODDIR/fontctl.sh" relink >/dev/null 2>&1
