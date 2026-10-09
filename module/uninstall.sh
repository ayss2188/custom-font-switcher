#!/system/bin/sh
# 卸载模块时：恢复本模块停用过的谷歌字体组件。
# 字体库 /data/adb/custom_font_lib 默认保留（重新安装后可直接使用），
# 如需彻底清理，卸载后手动删除该目录即可。
#
# 卸载脚本在开机早期执行，此时包管理器还没启动，所以放到后台等开机完成再恢复；
# 模块目录随后会被删除，因此这里不引用模块内的其他文件。

LIB=/data/adb/custom_font_lib
OWNED="$LIB/.gms_owned"
[ -f "$OWNED" ] || exit 0

(
  i=0
  while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 600 ]; do
    sleep 2; i=$((i+1))
  done
  sleep 5
  C="com.google.android.gms/com.google.android.gms.fonts.provider.FontsProvider"
  /system/bin/pm enable --user 0 "$C" >/dev/null 2>&1 || /system/bin/pm default-state --user 0 "$C" >/dev/null 2>&1
  rm -f "$OWNED"
) >/dev/null 2>&1 &

exit 0
