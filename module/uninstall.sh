#!/system/bin/sh
# 卸载时先把"商店缓存桥接"还原掉（否则那些缓存文件会一直显示我们的字体）
[ -f "$MODDIR/gms_cache.sh" ] && sh "$MODDIR/gms_cache.sh" off >/dev/null 2>&1
rm -f "$LIB/.gms_cache_on" 2>/dev/null
rm -f "$LIB/.seen_version" 2>/dev/null   # ★ 版本标记（下次重装当首次）   # ★ 清缓存桥接启用标志

# 卸载模块时：恢复本模块停用过的谷歌字体组件，然后删除字体库和设置（/data/adb/custom_font_lib）。
# 注意：更新 / 覆盖安装模块不会执行本脚本，字体库会保留；只有在管理器里点「卸载」才会清理。
#
# 为什么不直接调用模块里的 google_font.sh：卸载脚本在开机早期执行、模块目录随后就会被删掉，
# 所以这份逻辑必须**自包含**（不引用模块内其他文件）。
#
# 恢复规则（跟 google_font.sh 保持一致）：
#   · 按记录里的**用户**和**原状态**还原：原来是"默认"就 default-state、原来是"启用"就 enable
#     （一律 enable 会把"默认"改成"显式启用"，属于状态污染）
#   · 试 3 次，成功才删记录
#   · 3 次都没成功：**保留那份记录**（重装模块后会自动重试），并在 Download 写一份"怎么手动处理"的说明
#     —— 硬卡住卸载在这里做不到（管理器的卸载钩子无法阻止删除模块目录），所以做成"留痕 + 可自愈"。


# ---------------------------------------------------------------------------
# ★ 2026-10-19：**卸载前先把"被物理替换的主题字体"还原回去**
#
#   模块对「设置里选的字体」那几个目录（MIUI: /data/system/theme/fonts、
#   三星: /data/overlays/font）做的是**物理替换**（不是挂载），
#   原件备份在 $LIB/.orig/ 里，manifest.txt 记着每个原件路径。
#
#   而下面会 rm -rf "$LIB" —— 备份跟着一起被删，那份字体就永久变成用户的字体，
#   而且再也自动恢复不了（真机反馈：卸载后字体改不回去、系统卡顿、只能手动救）。
#
#   自包含实现：卸载脚本不能引用模块内其它文件（模块目录马上就没了）。
# ---------------------------------------------------------------------------
_restore_theme_fonts() {
  _man="$LIB/.orig/manifest.txt"
  [ -s "$_man" ] || return 0
  _n=0
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    [ -f "$_p" ] || continue
    _k=$(printf '%s' "$_p" | tr '/' '_' | tr -d ' ')
    _bak="$LIB/.orig/$_k"
    [ -s "$_bak" ] || continue
    # 大小一样 = 当前就是原件，别动；不一样 = 被我们换过 → 拷回去
    if [ "$(wc -c < "$_p" 2>/dev/null)" = "$(wc -c < "$_bak" 2>/dev/null)" ]; then
      continue
    fi
    cp -f "$_bak" "$_p" 2>/dev/null && _n=$((_n + 1))
  done < "$_man"
  return 0
}

LIB=/data/adb/custom_font_lib

# ★ 卸载就是"模块要没了"，主题字体的原件该还回去（详见上面函数说明）
_restore_theme_fonts
JOURNAL="$LIB/.gms_journal.conf"
LEGACY="$LIB/.gms_owned"
C="com.google.android.gms/com.google.android.gms.fonts.provider.FontsProvider"
NOTE="/data/media/0/Download/谷歌兼容未恢复-请看这里.txt"

U=""; ORIG="1"
if [ -f "$JOURNAL" ]; then
  U=$(sed -n 's/^user=//p' "$JOURNAL" 2>/dev/null | head -n1)
  ORIG=$(sed -n 's/^original=//p' "$JOURNAL" 2>/dev/null | head -n1)
fi
case "$U" in ''|*[!0-9]*) U="" ;; esac
case "$ORIG" in 0|1) ;; *) ORIG=1 ;; esac

restore_one() {   # $1 = 用户号
  if [ "$ORIG" = 0 ]; then
    /system/bin/pm default-state --user "$1" "$C" >/dev/null 2>&1 || /system/bin/pm enable --user "$1" "$C" >/dev/null 2>&1
  else
    /system/bin/pm enable --user "$1" "$C" >/dev/null 2>&1 || /system/bin/pm default-state --user "$1" "$C" >/dev/null 2>&1
  fi
}

if [ -f "$JOURNAL" ] || [ -f "$LEGACY" ]; then
  (
    i=0
    # 等开机完成；关机中就退出（不然这个后台任务会一直活到关机窗口里，还会去调 pm 和 rm -rf）
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 600 ]; do
      [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
      sleep 2; i=$((i+1))
    done
    [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
    # 模块又装回来了（用户取消了卸载 / 重新安装）：绝对不能删字体库，交给模块自己恢复
    [ -d /data/adb/modules/custom_font_switcher ] && exit 0
    sleep 5
    [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
    [ -d /data/adb/modules/custom_font_switcher ] && exit 0

    u="$U"
    if [ -z "$u" ]; then
      u=$(/system/bin/am get-current-user 2>/dev/null | tr -d '[:space:]')
      case "$u" in ''|*[!0-9]*) u=0 ;; esac
    fi
    ok=0; n=0
    while [ "$n" -lt 3 ]; do
      n=$((n+1))
      restore_one "$u" && { ok=1; break; }
      sleep 2
    done

    if [ "$ok" = 1 ]; then
      rm -f "$JOURNAL" "$LEGACY" 2>/dev/null
      rm -rf "$LIB"
    else
      # 失败：把恢复记录单独留下（重装模块后会自动重试），其余字体库照常清掉
      mkdir -p "$LIB" 2>/dev/null
      find "$LIB" -mindepth 1 ! -name '.gms_journal.conf' -exec rm -rf {} + 2>/dev/null
      {
        echo "谷歌字体兼容：自动恢复没有成功（用户 $u，原状态 $ORIG）。"
        echo
        echo "影响：Google 系应用（Play 商店 / Chrome 等）的英文数字会继续用系统字体。"
        echo "不会影响推送、账号或任何系统功能 —— 只是「下载字体」这条路还关着。"
        echo
        echo "怎么处理（任选一个）："
        echo "  1) 重新安装本模块 → 开机会自动重试恢复（记录还在：$JOURNAL）"
        echo "  2) 或者自己执行一次（需要 root）："
        echo "       pm enable --user $u $C"
        echo "     如果上面那条报错，再试："
        echo "       pm default-state --user $u $C"
      } > "$NOTE" 2>/dev/null
      chmod 666 "$NOTE" 2>/dev/null
    fi
  ) >/dev/null 2>&1 &
else
  # ★ 2026-10-19：这条路径也要判断"模块是不是又装回来了"。
  #   卸载请求排队后、开机真正执行 uninstall.sh 之前，用户可能又把它装了回去；
  #   那时模块目录在、且没有 remove 标记 —— 这种情况绝对不能删字体库，
  #   否则刚装好的模块开机就成了"字体全没了"。
  #   （有谷歌记录的那条路径本来就有这个保护，这里补齐，行为一致。）
  _reinstalled=0
  if [ -d /data/adb/modules/custom_font_switcher ]      && [ ! -f /data/adb/modules/custom_font_switcher/remove ]; then
    _reinstalled=1
  fi
  if [ -d /data/adb/modules_update/custom_font_switcher ]      && [ ! -f /data/adb/modules_update/custom_font_switcher/remove ]; then
    _reinstalled=1
  fi
  [ "$_reinstalled" = "1" ] || rm -rf "$LIB"
fi

# ---------------------------------------------------------------------------
# 自检：确认字体库真的删干净了
#
# ★ 2026-10-18（作者问「多了几个目录，卸载删干净了吗」）：
#   这一版在 $LIB 下新增了这些（都随 `rm -rf "$LIB"` 一起删）：
#       scanned/       刷入时扫一次的清单（device.list / slots.*.list / ttc.list /
#                      lockscreen.list / env.list / slots.meta / device.all）
#       .verify.cache  逐个核对的缓存
#       各种 .log / .state / .cache
#   万一 $LIB 因为权限或占用没删掉，这里明确报出来 —— 免得用户卸载后还留一堆垃圾。
#
#   注意：$MODDIR 下的文件不用管，管理器卸载模块时会删掉整个目录。
# ---------------------------------------------------------------------------
# ★ 2026-10-19：这个自检只在"同步删除"的路径下做。
#   有谷歌恢复记录时删除在后台子 shell 里跑，这里立刻检查会误报
#   （写一份"卸载未清干净.txt"吓用户，其实后台正在删/已删）。
_need_check=1
[ -f "$JOURNAL" ] && _need_check=0
[ -f "$LEGACY" ] && _need_check=0
# ★ 2026-10-19：模块又装回来了（目录在、且没有 remove 标记）→ 库是新的，绝不能清
[ -d /data/adb/modules/custom_font_switcher ] \
  && [ ! -f /data/adb/modules/custom_font_switcher/remove ] && _need_check=0
[ -d /data/adb/modules_update/custom_font_switcher ] \
  && [ ! -f /data/adb/modules_update/custom_font_switcher/remove ] && _need_check=0
if [ "$_need_check" = "1" ] && [ -e "$LIB" ]; then
  _left=$(find "$LIB" -mindepth 1 2>/dev/null | head -n 20)
  if [ -n "$_left" ]; then
    rm -rf "$LIB" 2>/dev/null
  fi
fi
if [ "$_need_check" = "1" ] && [ -e "$LIB" ]; then
  # 真的删不掉（极少数情况：文件被占用 / 只读挂载）
  {
    echo "字体库目录没能完全删除：$LIB"
    echo "里面剩下的："
    find "$LIB" -mindepth 1 2>/dev/null | head -n 40
    echo
    echo "可以手动删：rm -rf $LIB"
  } > /data/media/0/Download/卸载未清干净.txt 2>/dev/null
  chmod 666 /data/media/0/Download/卸载未清干净.txt 2>/dev/null
fi

exit 0
