#!/system/bin/sh
# diag.sh - 一键体检
#
# 目的：把「重启了也不生效 / 字体没变化」的可能原因一次跑完，并给出大白话结论。
# 特点：
#   1. 结论在最上面，用户截图或保存后发出来即可；
#   2. 不依赖开机脚本是否执行（安装那一刻就能跑）；
#   3. 覆盖厂商字体来源（字体包 / flipfont、/data/fonts 可更新字体、主题 overlay、
#      floating_feature.xml）、fonts*.xml 全量 family 映射、字体目录完整清单、.ttc 合集；
#   4. 会做一次真实的「槽位 bind 挂载 → 校验 → 立刻卸载」，当场证明能不能挂。
#
# 用法：
#   sh diag.sh brief     只打印结论（WebUI 顶部 / 模块「操作」按钮用）
#   sh diag.sh install   完整报告（含原始配置与哈希清单）写入 Download，并打印结论
#   sh diag.sh full      打印完整报告（WebUI「查看诊断报告」用）
#
# 本脚本永远返回 0，避免影响安装流程。

MODDIR=${0%/*}
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/custom_font_switcher
. "$MODDIR/common.sh" 2>/dev/null
. "$MODDIR/slots.sh" 2>/dev/null
. "$MODDIR/mount.sh" 2>/dev/null

LIB=${LIB:-/data/adb/custom_font_lib}
SETTINGS=${SETTINGS:-$LIB/settings.conf}

ID=$(sed -n 's/^id=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
[ -n "$ID" ] || ID=custom_font_switcher
M="/data/adb/modules/$ID"
[ -d "$M" ] || M="$MODDIR"
UPD="/data/adb/modules_update/$ID"
IN_INSTALL=0
case "$MODDIR" in
  /data/adb/modules_update/*) IN_INSTALL=1 ;;
esac

GP=/system/bin/getprop;     [ -x "$GP" ] || GP=getprop
CMD=/system/bin/cmd;        [ -x "$CMD" ] || CMD=cmd
MO=/system/bin/mount;       [ -x "$MO" ] || MO=mount
UMO=/system/bin/umount;     [ -x "$UMO" ] || UMO=umount
PM=/system/bin/pm;          [ -x "$PM" ] || PM=pm
SETBIN=/system/bin/settings; [ -x "$SETBIN" ] || SETBIN=settings

MODE=${1:-full}
DL=/data/media/0/Download
OUTFILE="$DL/字体体检报告.txt"
OUTFILE2="$DL/font_diag.txt"
XMLS="/system/etc/fonts.xml /system/etc/font_fallback.xml /system/etc/fonts_additional.xml /system/etc/fonts_customization.xml"

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
NOW=$(date +%s 2>/dev/null); NOW=${NOW:-0}
UP=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1); UP=${UP:-0}
BOOTEPOCH=$((NOW - UP))

mtime() { stat -c %Y "$1" 2>/dev/null; }
mstamp() { date -r "$1" '+%m-%d %H:%M' 2>/dev/null || mtime "$1"; }
newer_boot() { local t; t=$(mtime "$1"); [ -n "$t" ] && [ "$t" -ge "$BOOTEPOCH" ]; }
older_boot() { local t; t=$(mtime "$1"); [ -n "$t" ] && [ "$t" -lt "$BOOTEPOCH" ]; }
since_txt() {
  if newer_boot "$1"; then printf '本次开机之后'
  elif older_boot "$1"; then printf '本次开机之前'
  else printf '?'; fi
}
hr() { printf '  ------------------------------------------------------------\n'; }
tag() { sed -n 's/^version=//p' "$1/module.prop" 2>/dev/null | head -n1 | tr -d '\r'; }
# XML 规范化：把标签拆成一行一个，方便 grep 上下文
xmlnorm() { tr '\n\r\t' ' ' < "$1" 2>/dev/null | sed 's/></>\n</g'; }
# XML 拆成 <family / <font / </font 各一行，便于提取 family -> 文件 的对应关系
xmlfam() {
  tr '\n\r\t' '   ' < "$1" 2>/dev/null \
    | sed -e 's/<family/\n<family/g' -e 's#</family>#\n#g' \
          -e 's/<font/\n<font/g' -e 's#</font>#\n#g'
}
# 一次性列出 8 进制大小
size_kb() { local s; s=$(stat -c %s "$1" 2>/dev/null); [ -n "$s" ] && echo "$((s / 1024)) KB" || echo "?"; }
# 字体文件里的 sfnt 表标签（判断是否可变字体、有没有 glyf/CFF）
sfnt_tags() {
  head -c 3072 "$1" 2>/dev/null | tr -c 'A-Za-z0-9/ ' '\n' \
    | grep -E '^(cmap|glyf|loca|head|hhea|hmtx|maxp|name|OS/2|post|fvar|gvar|avar|STAT|HVAR|MVAR|CFF|CFF2|GPOS|GSUB|kern|DSIG)$' \
    | sort -u | tr '\n' ' '
}
# TTC 合集头：'ttcf' + version + numFonts(偏移 8，4 字节小端)
ttc_faces() {
  local n
  n=$(od -An -tu4 -j8 -N4 "$1" 2>/dev/null | tr -d ' \n')
  [ -n "$n" ] || n=$(od -An -tx1 -j8 -N4 "$1" 2>/dev/null | tr -d ' \n')
  echo "${n:-?}"
}
ttc_tag() { head -c 4 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n'; }

# ---------------------------------------------------------------------------
# 判据（一次采集）
# ---------------------------------------------------------------------------
G_DISABLE=0; [ -f "$M/disable" ] && G_DISABLE=1
G_REMOVE=0;  [ -f "$M/remove" ] && G_REMOVE=1
G_UPDATE=0
if [ "$IN_INSTALL" = 1 ]; then
  [ -f "$M/update" ] && G_UPDATE=1
else
  { [ -f "$M/update" ] || [ -d "$UPD" ]; } && G_UPDATE=1
fi
G_SAFE=0
case "$($GP persist.sys.safemode 2>/dev/null)$($GP ro.sys.safemode 2>/dev/null)" in
  *1*) G_SAFE=1 ;;
esac
G_MAGISK=0
if command -v magisk >/dev/null 2>&1 || [ -e /data/adb/magisk ] || [ -e /data/adb/magisk.db ]; then
  G_MAGISK=1
fi
G_NMOD=0; G_NDIS=0
for d in /data/adb/modules/*/; do
  [ -d "$d" ] || continue
  G_NMOD=$((G_NMOD + 1))
  [ -f "$d/disable" ] && G_NDIS=$((G_NDIS + 1))
done

RM=$(root_manager 2>/dev/null)
KSU_BIN=""
[ -x /data/adb/ksud ] && KSU_BIN=/data/adb/ksud
[ -n "$KSU_BIN" ] || { [ -x /data/adb/ksu/bin/ksud ] && KSU_BIN=/data/adb/ksu/bin/ksud; }
KSVER="未找到 ksud"
[ -n "$KSU_BIN" ] && KSVER=$("$KSU_BIN" -V 2>/dev/null | head -n1)
BOOTID=$(boot_id 2>/dev/null)
BOOTCOMP=$($GP sys.boot_completed 2>/dev/null)
ROMID=$(tr -d '[:space:]' < "$M/current_rom" 2>/dev/null)
VER_MOD=$(tag "$M")
DIAG_VER=$(tag "$MODDIR")
PEND=$(tr -d '[:space:]' < "$M/pending_font" 2>/dev/null)
ACT=$(tr -d '[:space:]' < "$M/active_font" 2>/dev/null)
MS_BOOT=$(sed -n 's/^boot=//p' "$M/mount.state" 2>/dev/null)
MS_OK=$(sed -n 's/^ok=//p' "$M/mount.state" 2>/dev/null)
MS_FAIL=$(sed -n 's/^fail=//p' "$M/mount.state" 2>/dev/null)
MS_SKIP=$(sed -n 's/^skip=//p' "$M/mount.state" 2>/dev/null)
MS_STAGE=$(sed -n 's/^stage=//p' "$M/mount.state" 2>/dev/null)
BEAT="$LIB/boot_events.log"
MODE_FILE=$(tr -d '[:space:]' < "$M/payload.mode" 2>/dev/null)

PFD_THIS=0
SVC_THIS=0
if [ -f "$BEAT" ]; then
  grep -q "boot=$BOOTID stage=post-fs-data" "$BEAT" 2>/dev/null && PFD_THIS=1
  grep -q "boot=$BOOTID stage=service" "$BEAT" 2>/dev/null && SVC_THIS=1
fi
if [ "$PFD_THIS" = 0 ]; then
  [ -n "$BOOTID" ] && [ "$MS_BOOT" = "$BOOTID" ] && PFD_THIS=2
  newer_boot "$M/.booting" && PFD_THIS=2
fi
if [ "$SVC_THIS" = 0 ]; then
  if [ "$ACT" = "$PEND" ] && [ -n "$PEND" ] && [ "$PEND" != none ] && older_boot "$M/pending_font"; then
    SVC_THIS=2
  fi
fi

VER=$(payload_verify "$M" 2>/dev/null)
[ -n "$VER" ] || VER="0 0"
VHIT=${VER%% *}
VTOT=${VER##* }

# 字体目录 / 配置文件（硬编码清单 + 全盘发现 + apex，全部合并，避免漏掉 product/vendor/odm 的配置）
FONTDIRS=$(slot_dirs 2>/dev/null)
SYSDIR_REAL=$(readlink -f /system/fonts 2>/dev/null)
XMLFOUND=""
_addxml() {
  [ -f "$1" ] || return 0
  case " $XMLFOUND " in *" $1 "*) return 0 ;; esac
  XMLFOUND="$XMLFOUND $1"
}
for x in $XMLS; do _addxml "$x"; done
for x in $(slot_xml_files 2>/dev/null); do _addxml "$x"; done
for x in /apex/*/etc/*font*.xml /apex/*/*/etc/*font*.xml /system/etc/fonts*.xml; do _addxml "$x"; done
[ -n "$XMLFOUND" ] || XMLFOUND=" /system/etc/fonts.xml"
SYSFONTS=$(ls -1 /system/fonts 2>/dev/null)
SYSFONT_N=$(printf '%s\n' "$SYSFONTS" | grep -c . )
TTC_LIST=$(printf '%s\n' "$SYSFONTS" | grep -i '\.ttc$')
TTCNUM=$(printf '%s\n' "$TTC_LIST" | grep -c . )
TTCFIRST=$(printf '%s\n' "$TTC_LIST" | head -n1)
ZH_TTC=0
for x in $XMLFOUND; do
  xmlnorm "$x" | grep -i 'zh-Hans' | grep -qi '\.ttc' && ZH_TTC=1
done

# 三星：字体包 / flipfont / 字体设置 / /data/fonts
PKG_FONT=$("$PM" list packages -f 2>/dev/null | grep -iE 'monotype|flipfont|font' | head -n 20)
G_FLIP=0
[ -n "$PKG_FONT" ] && printf '%s\n' "$PKG_FONT" | grep -q '/data/app' && G_FLIP=1
S_FONT=$( { "$SETBIN" list secure 2>/dev/null; "$SETBIN" list system 2>/dev/null; "$SETBIN" list global 2>/dev/null; } \
  | grep -iE 'font|typeface' | grep -viE 'scale|size' | head -n 10 )
[ -n "$S_FONT" ] && G_FLIP=1
DFONT_LIST=""
[ -d /data/fonts ] && DFONT_LIST=$(ls -1R /data/fonts 2>/dev/null | head -n 40)
G_DFONT=0
[ -n "$DFONT_LIST" ] && G_DFONT=1
DFONT_CFG=""
[ -f /data/fonts/config/config.xml ] && DFONT_CFG=$(cat /data/fonts/config/config.xml 2>/dev/null | head -n 60)
[ -n "$DFONT_CFG" ] && G_DFONT=1

# MIUI / HyperOS 个性字体（主题字体）：由主题机制接管，优先级高于 /system/fonts，
# 同名文件会顶替系统字体 —— 这就是"旧版必须手动切一次字体才生效"的根源。
MIUI_DIRS=""
for td in /data/system/theme/fonts /data/system/theme_font /data/miui/theme/fonts /data/miui/theme; do
  [ -d "$td" ] && MIUI_DIRS="$MIUI_DIRS $td"
done
MIUI_FONTLIST=""
MIUI_FONT_N=0
for td in $MIUI_DIRS; do
  for f in "$td"/*.ttf "$td"/*.otf "$td"/*.ttc; do
    [ -f "$f" ] || continue
    MIUI_FONT_N=$((MIUI_FONT_N + 1))
    MIUI_FONTLIST="$MIUI_FONTLIST$f
"
  done
done
MIUI_SHADOW=""
if [ "$MIUI_FONT_N" -gt 0 ]; then
  MIUI_SHADOW=$(printf '%s\n' "$MIUI_FONTLIST" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    b=${f##*/}
    for d in $FONTDIRS; do
      [ -f "$d/$b" ] && { echo "$b"; break; }
    done
  done | sort -u | tr '\n' ' ')
fi
G_MIUI=0
[ "$MIUI_FONT_N" -gt 0 ] && G_MIUI=1

# 槽位候选（一次算完，后面复用）
CANDS=$(slot_candidates "$M" 2>/dev/null)
CAND_N=$(printf '%s\n' "$CANDS" | grep -c . )
# 当前字体实际范围
eff_scope() {
  local sel="$1" sc latin cjk
  case "$sel" in *+*) echo combo; return ;; ""|none) echo all; return ;; esac
  sc=$(sed -n 's/^scope=//p' "$LIB/$sel.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')
  case "$sc" in all|latin|cjk) echo "$sc"; return ;; esac
  latin=$(sed -n 's/^latin=//p' "$LIB/$sel.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')
  cjk=$(sed -n 's/^cjk=//p' "$LIB/$sel.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')
  if [ -z "$latin$cjk" ]; then echo all; return; fi
  if [ "$cjk" = 1 ] && [ "$latin" = 1 ]; then echo all
  elif [ "$latin" = 1 ]; then echo latin
  elif [ "$cjk" = 1 ]; then echo cjk
  else echo latin; fi
}
SCOPE=$(eff_scope "$PEND")
KL=$(cfg_get keep_lang 1); KS=$(cfg_get keep_special 1)
plan_of() { # $1=scope $2=keep_lang $3=keep_special
  local scope="$1" kl="$2" ks="$3" role d name
  printf '%s\n' "$CANDS" | while read -r role d name; do
    [ -n "$role" ] || continue
    _role_wanted "$role" "$scope" "$kl" "$ks" || continue
    printf '%s %s/%s\n' "$role" "${d#/}" "$name"
  done | sort -u -k2,2
}
PLAN_NOW=$(plan_of "$SCOPE" "$KL" "$KS")
PLAN_MAX=$(plan_of all 0 0)
APPLIED_LIST=$(cat "$M/slots.applied" 2>/dev/null)
APPLIED_TTC=0
if [ -n "$APPLIED_LIST" ] && [ "$TTCNUM" -gt 0 ]; then
  printf '%s\n' "$TTC_LIST" | while IFS= read -r b; do
    [ -n "$b" ] || continue
    printf '%s\n' "$APPLIED_LIST" | grep -q "/$b\$" && echo x
  done > /data/local/tmp/.diag_ttc.$$ 2>/dev/null
  APPLIED_TTC=$(grep -c . /data/local/tmp/.diag_ttc.$$ 2>/dev/null)
  rm -f /data/local/tmp/.diag_ttc.$$ 2>/dev/null
fi
[ -n "$APPLIED_TTC" ] || APPLIED_TTC=0

# 字体库清单
LIB_FONTS=$(ls -1 "$LIB"/f*.ttf 2>/dev/null)
LIB_N=$(printf '%s\n' "$LIB_FONTS" | grep -c . )

# ---------------------------------------------------------------------------
# 实际字体目录映射（第 5 节的核心数据，pack_extra 也会带走）
# ---------------------------------------------------------------------------
FONTDIR_MAP=""
for d in $FONTDIRS; do
  real=$(readlink -f "$d" 2>/dev/null); [ -n "$real" ] || real="$d"
  idn=$(stat -L -c '%d:%i' "$d" 2>/dev/null)
  cnt=$(ls -1 "$d" 2>/dev/null | grep -c .)
  szk=$(du -sk "$d" 2>/dev/null | cut -f1)
  same=""
  if [ -n "$idn" ]; then
    for e in $FONTDIRS; do
      [ "$e" = "$d" ] && continue
      [ "$(stat -L -c '%d:%i' "$e" 2>/dev/null)" = "$idn" ] && same="$same $e"
    done
  fi
  FONTDIR_MAP="$FONTDIR_MAP$d|$real|$idn|$cnt|$szk|$same
"
done

# 配置里引用到的所有字体文件名（一处提取，多处复用）
XMLNAMES=""
for x in $XMLFOUND; do
  XMLNAMES="$XMLNAMES$(xmlnorm "$x" 2>/dev/null | grep -o '>[^<>]*\.[tT][tT][cCfF]<' | sed 's/^>//; s/<$//; s/ *$//')
"
done
XMLNAMES=$(printf '%s\n' "$XMLNAMES" | grep -v '^[[:space:]]*$' | sort -u)

# 名字 -> 框架实际读取的路径 | 存在 | 独立副本
NAMEMAP=$(printf '%s\n' "$XMLNAMES" | while IFS= read -r n; do
  [ -n "$n" ] || continue
  case "$n" in /*) p="$n" ;; *) p="/system/fonts/$n" ;; esac
  real=$(readlink -f "$p" 2>/dev/null); [ -n "$real" ] || real="$p"
  if [ -f "$p" ]; then st="有"; else st="无"; fi
  par=$(dirname "$real" 2>/dev/null)
  base=${n##*/}
  pdid=$(stat -L -c '%d:%i' "$par" 2>/dev/null)
  dup=""
  for d in $FONTDIRS; do
    dr=$(readlink -f "$d" 2>/dev/null); [ -n "$dr" ] || dr="$d"
    [ "$dr" = "$par" ] && continue
    [ -f "$d/$base" ] || continue
    did=$(stat -L -c '%d:%i' "$d" 2>/dev/null)
    if [ -n "$did" ] && [ "$did" = "$pdid" ]; then dup="$dup $d(同一份)"; else dup="$dup $d(独立★)"; fi
  done
  echo "$n|$p|$real|$st|$dup"
done)

# 一句话小结：符号链接关系
dir_conclusion() {
  local d real out=""
  for d in $FONTDIRS; do
    real=$(readlink -f "$d" 2>/dev/null)
    [ -n "$real" ] && [ "$real" != "$d" ] && out="$out $d→$real"
  done
  printf '%s' "${out:-（各字体目录相互独立，没有符号链接）}"
}

# ---------------------------------------------------------------------------
# 实机挂载能力测试：挂一个真实槽位 -> 校验 -> 立刻卸载
# ---------------------------------------------------------------------------
MT_RESULT="未测试"
MT_DETAIL=""
MT_TARGET=""
MT_SRC=""
MT_LEFT=0
do_mount_test() {
  local line id rel before after err srcid now umount_err
  MT_TARGET=""; MT_SRC=""
  [ -s "$M/slots.map" ] || { MT_RESULT="跳过（没有槽位计划）"; return 0; }
  line=$(head -n1 "$M/slots.map" 2>/dev/null)
  id=${line%% *}; rel=${line#* }
  rel=$(printf '%s' "$rel" | tr -d '\r')
  case "$id" in ""|*[!A-Za-z0-9_]*) MT_RESULT="跳过（slots.map 格式异常）"; return 0 ;; esac
  [ -n "$rel" ] || { MT_RESULT="跳过（slots.map 为空）"; return 0; }
  MT_SRC="$LIB/$id.ttf"; MT_TARGET="/$rel"
  [ -f "$MT_SRC" ] || { MT_RESULT="跳过（字体库文件不存在: $MT_SRC）"; return 0; }
  [ -f "$MT_TARGET" ] || { MT_RESULT="跳过（目标槽位不存在: $MT_TARGET）"; return 0; }
  before=$(stat -L -c '%d:%i' "$MT_TARGET" 2>/dev/null)
  err=$("$MO" -o bind "$MT_SRC" "$MT_TARGET" 2>&1)
  after=$(stat -L -c '%d:%i' "$MT_TARGET" 2>/dev/null)
  srcid=$(stat -L -c '%d:%i' "$MT_SRC" 2>/dev/null)
  if [ "$after" = "$srcid" ] && [ -n "$srcid" ]; then
    MT_RESULT="成功（bind 挂载可用）"
    MT_DETAIL="挂载后 dev:inode=$after，与字体库文件一致"
    umount_err=$("$UMO" "$MT_TARGET" 2>&1)
    now=$(stat -L -c '%d:%i' "$MT_TARGET" 2>/dev/null)
    if [ "$now" = "$before" ]; then
      MT_DETAIL="$MT_DETAIL；已成功卸载还原"
    else
      MT_RESULT="成功但卸载失败 ★（该槽位会保持被替换，重启后恢复）"
      MT_DETAIL="$MT_DETAIL；umount 报错: ${umount_err:-无输出}"
      MT_LEFT=1
    fi
  else
    MT_RESULT="失败 ★（$MT_TARGET 挂不上去）"
    MT_DETAIL="mount 报错: ${err:-无输出}；挂载后 dev:inode=$after（期望 $srcid）"
  fi
  return 0
}
do_mount_test

# ---------------------------------------------------------------------------
# 结论
# ---------------------------------------------------------------------------
conclusion() {
  echo "===== 一键体检（结论）====="
  echo "体检脚本: ${DIAG_VER:-?}   正在生效的模块: ${VER_MOD:-?}"
  echo "运行位置: $MODDIR"
  echo "设备: $($GP ro.product.brand 2>/dev/null) $($GP ro.product.model 2>/dev/null)   Android $($GP ro.build.version.release 2>/dev/null)   构建号: $($GP ro.build.display.id 2>/dev/null)"
  echo "系统识别: $(rom_name "$ROMID" 2>/dev/null)   已开机 $((UP / 60)) 分钟   boot_completed=$BOOTCOMP"
  hr
  if [ "$G_DISABLE" = 1 ]; then
    echo "❌ 结论：模块处于「已禁用」状态。"
    echo "   KernelSU 不会执行被禁用模块的任何开机脚本，重启多少次都不会生效。"
    echo "   → 到管理器里把模块启用，然后重启。"
  elif [ "$G_REMOVE" = 1 ]; then
    echo "❌ 结论：模块被标记为「待卸载」，同样不会执行任何脚本。"
    echo "   → 到管理器里取消卸载标记，或重新安装一次模块。"
  elif [ "$G_UPDATE" = 1 ]; then
    echo "❌ 结论：模块内容从未被「激活」（活动目录上有 update 标记 / 内容还在 modules_update）。"
    echo "   只有开机的 post-fs-data 阶段会做这件激活的事；没激活 = 那个阶段从来没执行过。"
    echo "   这就是「重启好几次也没用」的直接原因。"
  elif [ "$G_SAFE" = 1 ]; then
    echo "❌ 结论：系统当前处于安全模式（safemode=1）。"
    echo "   KernelSU 在安全模式下会跳过所有模块脚本，还会把全部模块禁用。"
    echo "   → 重启一次（开机时别按音量键），然后到管理器里重新启用模块。"
  elif [ "$G_MAGISK" = 1 ]; then
    echo "❌ 结论：机器上还检测到 Magisk。"
    echo "   KernelSU 一旦发现 Magisk，就会跳过全部模块脚本（post-fs-data / post-mount / service 都不跑）。"
  elif [ "$MT_LEFT" = 1 ]; then
    echo "⚠ 结论：挂载测试成功，但测试用的挂载点卸载失败（已记录，重启后可恢复）。"
  elif [ "$PFD_THIS" = 0 ] && [ "$SVC_THIS" = 0 ]; then
    echo "❌ 结论：没有任何一次开机留下「脚本执行过」的痕迹。"
    if [ -f "$M/mount_missed" ]; then
      echo "   但存在 mount_missed（$(mstamp "$M/mount_missed")，$(since_txt "$M/mount_missed")）："
      echo "   说明某次开机脚本跑过，只是「挂载阶段」被跳过了（管理器没有 post-mount 阶段）。"
    else
      echo "   连 mount_missed 都没有 → 模块脚本从来没被执行过（不是挂载失败）。"
    fi
    echo "   第 1 节的门禁都没命中时，看第 10 节的 ksud 日志、版本和 dmesg。"
  elif [ "$PFD_THIS" != 0 ] && [ -z "$MS_BOOT" ]; then
    echo "❌ 结论：开机脚本跑了，但「挂载阶段」没有留下任何记录。"
    echo "   结合第 3 节的实测结果一起看（实测${MT_RESULT}）。"
    echo "   → 需要模块改用其它挂载时机，请把报告发给作者。"
  elif [ -n "$MS_BOOT" ] && [ "$MS_BOOT" != "$BOOTID" ]; then
    echo "⚠ 结论：有挂载记录，但不是本次开机的（也就是本次开机没挂上）。"
    echo "   → 重启一次，重启后什么都别点，再看这份报告。"
  elif [ -n "$MS_FAIL" ] && [ "$MS_FAIL" != 0 ]; then
    echo "❌ 结论：挂载失败 $MS_FAIL 个（成功 $MS_OK 个）。第 3 节有真实报错。"
  elif [ -n "$MS_BOOT" ] && [ "$MS_BOOT" = "$BOOTID" ] && [ "$VTOT" != 0 ] && [ "$VHIT" = "$VTOT" ]; then
    echo "✅ 结论：字体已成功挂载并生效（$VHIT/$VTOT）。"
    if [ "$ZH_TTC" = 1 ] && [ "$APPLIED_TTC" = 0 ]; then
      echo "⚠ 但中文多半没变：三星中文用的是 .ttc 合集（${TTCFIRST:-?}），"
      echo "  本模块只支持单文件 .ttf/.otf，替换列表里不含它。见第 6 节。"
    fi
  elif [ -n "$MS_BOOT" ] && [ "$MS_BOOT" = "$BOOTID" ]; then
    echo "⚠ 结论：有本次开机的挂载记录，但实际校验只有 $VHIT/$VTOT 生效。见第 3 节。"
  else
    echo "⚠ 结论：没找到明确的失败点。请看第 2 节执行痕迹、第 4 节候选槽位和第 10 节日志。"
  fi
  hr
  echo "本次开机: post-fs-data $([ "$PFD_THIS" = 0 ] && echo '未执行' || echo '已执行')   service $([ "$SVC_THIS" = 0 ] && echo '未执行' || echo '已执行')   实际生效 $VHIT/$VTOT"
  echo "挂载实测: $MT_RESULT"
  echo "待生效: ${PEND:-none}    当前生效: ${ACT:-none}"
  echo "（两个不一致 = 这次的选择还没被任何一次开机处理过）"
  echo "字体库: ${LIB_N:-0} 个，占用 $(du -sk "$LIB" 2>/dev/null | cut -f1) KB   挂载方式: ${MODE_FILE:-?}"
  echo "设置: keep_lang=$KL keep_special=$KS   替换范围: ${SCOPE:-?}   槽位计划: $(printf '%s\n' "$PLAN_NOW" | grep -c . ) 个"
  echo "实际字体目录: /system/fonts → ${SYSDIR_REAL:-?}（设备上共 $(printf '%s\n' "$FONTDIRS" | grep -c . ) 个字体目录，详见第 5 节）"
  echo "谷歌字体兼容: $(sh "$MODDIR/google_font.sh" status 2>/dev/null)   冲突模块: $(sh "$MODDIR/fontctl.sh" conflicts 2>/dev/null | cut -d'|' -f2 | tr '\n' ' ')"
  if [ "$G_FLIP" = 1 ]; then
    echo "⚠ 另外：检测到「字体包 / 字体设置」相关项（见第 7 节）。"
    echo "   如果他在 设置→显示→字体大小和样式 里选了非默认字体，系统会走字体包，"
    echo "   这种情况下替换 /system/fonts 是无效的，需要先选回「默认」。"
  fi
  if [ "$G_DFONT" = 1 ]; then
    echo "⚠ 另外：存在 /data/fonts（Android 可更新字体），它会盖过 /system/fonts（见第 7 节）。"
  fi
  if [ "$G_MIUI" = 1 ]; then
    echo "⚠ 另外：检测到 MIUI / HyperOS 个性字体（主题字体）：$MIUI_DIRS"
    echo "   共 $MIUI_FONT_N 个字体文件$([ -n "$MIUI_SHADOW" ] && echo "，其中与系统同名的：$MIUI_SHADOW")"
    echo "   个性字体由主题机制接管，优先级高于 /system/fonts —— 只替换系统目录不会全面生效。"
    echo "   → 设置 → 显示 → 字体大小和样式 切回「默认」（或小米兰亭Pro）后重启一次。"
  fi
  echo "===== 结论结束，下面是原始数据（给作者看）====="
}

# ---------------------------------------------------------------------------
sec1() {
  echo
  echo "【1】门禁：可能导致「脚本完全不执行」的开关"
  hr
  echo "  模块目录        : $M"
  echo "  活动模块版本    : ${VER_MOD:-?}   体检脚本版本: ${DIAG_VER:-?}"
  echo "  disable（禁用）  : $([ "$G_DISABLE" = 1 ] && echo '有 ★' || echo 无)"
  echo "  remove（待卸载） : $([ "$G_REMOVE" = 1 ] && echo '有 ★' || echo 无)"
  echo "  update（未激活） : $([ "$G_UPDATE" = 1 ] && echo '有 ★' || echo 无)"
  echo "  modules_update  : $([ -d "$UPD" ] && echo "存在  $UPD" || echo 不存在)$([ "$IN_INSTALL" = 1 ] && echo ' （本次正在安装，必然存在，不作为依据）' || echo '')"
  echo "  Android 安全模式 : persist.sys.safemode=$($GP persist.sys.safemode 2>/dev/null)  ro.sys.safemode=$($GP ro.sys.safemode 2>/dev/null)"
  echo "  Magisk 共存     : command -v magisk = $(command -v magisk 2>/dev/null || echo 无)   /data/adb/magisk = $([ -e /data/adb/magisk ] && echo 有 || echo 无)   magisk.db = $([ -e /data/adb/magisk.db ] && echo 有 || echo 无)"
  echo "  Root 管理器     : $RM   (KSU=$KSU APATCH=$APATCH MAGISK_VER=$MAGISK_VER)"
  echo "  ksud            : $KSU_BIN  版本: $KSVER"
  echo "  late-load 模式  : KSU_LATE_LOAD=$KSU_LATE_LOAD   KSU_RUNTIME_MODE=$KSU_RUNTIME_MODE"
  echo "  模块总数        : $G_NMOD 个，其中被禁用 $G_NDIS 个"
  if [ "$G_NMOD" -gt 0 ] && [ "$G_NDIS" = "$G_NMOD" ]; then
    echo "  ★ 所有模块都被禁用了 —— KernelSU 进过安全模式的典型特征（它会禁用全部模块）"
  fi
  echo "  元模块          : $([ -e /data/adb/metamodule ] && readlink /data/adb/metamodule 2>/dev/null || echo 无)"
  echo "  其它模块状态    :"
  for d in /data/adb/modules/*/; do
    [ -d "$d" ] || continue
    echo "      $(basename "$d")  disable=$([ -f "$d/disable" ] && echo 1 || echo 0) update=$([ -f "$d/update" ] && echo 1 || echo 0) webroot=$([ -d "$d/webroot" ] && echo 1 || echo 0)"
  done
  echo "  本模块目录内容  :"
  ls -la "$M" 2>/dev/null | head -n 30 | while IFS= read -r L; do echo "      $L"; done
  echo "  本模块 module.prop:"
  sed -n 'p' "$M/module.prop" 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  echo "  本模块 system 残留: $([ -d "$M/system" ] && echo "有 ($(du -sk "$M/system" 2>/dev/null | cut -f1) KB)" || echo 无)"
  echo "  modules_update 目录:"
  ls -la /data/adb/modules_update/ 2>/dev/null | head -n 15 | while IFS= read -r L; do echo "      $L"; done
}

# ---------------------------------------------------------------------------
sec2() {
  echo
  echo "【2】开机脚本痕迹与时间线"
  hr
  echo "  本次 boot_id   : ${BOOTID:-?}"
  echo "  心跳日志       : $BEAT  $([ -f "$BEAT" ] && echo '(存在)' || echo '(没有)')"
  if [ -f "$BEAT" ]; then
    echo "  最近心跳记录   :"
    tail -n 10 "$BEAT" 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  fi
  echo "  mount.state    : $([ -f "$M/mount.state" ] && echo "有   写入于 $(mstamp "$M/mount.state")（$(since_txt "$M/mount.state")）" || echo 没有)"
  if [ -f "$M/mount.state" ]; then
    echo "                   内容: boot=$MS_BOOT ok=$MS_OK fail=$MS_FAIL skip=$MS_SKIP stage=$MS_STAGE"
    echo "                   是否本次开机: $([ "$MS_BOOT" = "$BOOTID" ] && echo 是 || echo 否)"
  fi
  echo "  mount_missed   : $([ -f "$M/mount_missed" ] && echo "有 ★ 写入于 $(mstamp "$M/mount_missed")（$(since_txt "$M/mount_missed")）" || echo 没有)"
  echo "                   （若它存在且是「本次开机之前」写的 → 本次开机的 post-fs-data 没跑："
  echo "                     因为 post-fs-data 一执行就会先删掉它）"
  echo "  .booting       : $([ -f "$M/.booting" ] && echo "有   写入于 $(mstamp "$M/.booting")（$(since_txt "$M/.booting")）" || echo 没有)"
  echo "  rescued        : $([ -f "$M/rescued" ] && echo '有（上次开机没完成，已自动恢复成无字体）' || echo 没有)"
  echo "  pending_font   : ${PEND:-none}   写入于 $(mstamp "$M/pending_font")（$(since_txt "$M/pending_font")）"
  echo "  active_font    : ${ACT:-none}   写入于 $(mstamp "$M/active_font")（$(since_txt "$M/active_font")）"
  echo "  payload.mode   : ${MODE_FILE:-?}"
  echo "  slots.applied  : $(printf '%s\n' "$APPLIED_LIST" | grep -c . ) 行   写入于 $(mstamp "$M/slots.applied")（$(since_txt "$M/slots.applied")）"
  echo "  设置 settings.conf:"
  sed -n 'p' "$SETTINGS" 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  echo "  关键文件时间线（旧→新）:"
  for f in "$M/disable" "$M/update" "$M/pending_font" "$M/slots.applied" "$M/payload.mode" "$M/.booting" "$M/mount.state" "$M/mount_missed" "$M/active_font" "$M/rescued" "$LIB/last_selection" "$BEAT" "$LIB/mount.log"; do
    [ -f "$f" ] || continue
    echo "      $(mstamp "$f")  $(since_txt "$f")  ${f#/data/adb/}"
  done
  hr
  echo "  判定: post-fs-data $([ "$PFD_THIS" = 0 ] && echo '未执行 ★' || echo '已执行')    service $([ "$SVC_THIS" = 0 ] && echo '未执行 ★' || echo '已执行')"
}

# ---------------------------------------------------------------------------
sec3() {
  echo
  echo "【3】挂载现状 + 实机挂载能力实测"
  hr
  echo "  /system/fonts 上层挂载点数量: $("$MO" 2>/dev/null | grep -c '/system/fonts/')"
  "$MO" 2>/dev/null | grep '/system/fonts/' | head -n 8 | while IFS= read -r L; do echo "      $L"; done
  echo "  实际生效校验   : $VHIT / $VTOT"
  echo "  实测：$MT_RESULT"
  [ -n "$MT_SRC" ] && echo "      源文件   : $MT_SRC  ($(size_kb "$MT_SRC"))"
  [ -n "$MT_TARGET" ] && echo "      目标槽位 : $MT_TARGET  ($(size_kb "$MT_TARGET"))"
  [ -n "$MT_DETAIL" ] && echo "      详情     : $MT_DETAIL"
  echo "  SELinux 当前模式: $(getenforce 2>/dev/null)"
  echo "  挂载日志 $LIB/mount.log:"
  if [ -f "$LIB/mount.log" ]; then
    tail -n 25 "$LIB/mount.log" 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  else
    echo "      (没有：挂载从没被尝试过)"
  fi
  echo "  slots.map（前 20 行）:"
  head -n 20 "$M/slots.map" 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  echo "  关键挂载/文件系统:"
  "$MO" 2>/dev/null | grep -E ' /system | /system_ext | /product | /vendor | /odm | /prism | /optics | /data ' | head -n 12 | while IFS= read -r L; do echo "      $L"; done
  echo "  overlay / KernelSU / Magisk 挂载（判断有没有元模块接管 /system）:"
  "$MO" 2>/dev/null | grep -E 'overlay|KSU|kernelsu|magisk|/data/adb' | head -n 12 | while IFS= read -r L; do echo "      $L"; done
  echo "  /system 目录属性: $(ls -ld /system 2>/dev/null)"
  echo "  /system/fonts 属性: $(ls -ld /system/fonts 2>/dev/null)"
}

# ---------------------------------------------------------------------------
sec4() {
  echo
  echo "【4】槽位发现详情"
  hr
  echo "  字体目录(真实存在): $(printf '%s' "$FONTDIRS" | tr '\n' ' ')"
  echo "  字体配置 XML: $XMLFOUND"
  echo "  XML 指纹:"
  for x in $XMLFOUND; do
    echo "      $x  $(size_kb "$x")  md5=$(md5sum "$x" 2>/dev/null | cut -d' ' -f1)  mtime=$(mstamp "$x")"
  done
  echo "  候选总数: $CAND_N   当前范围(scope)=$SCOPE  keep_lang=$KL keep_special=$KS"
  echo "  候选明细（角色 目录/文件名）:"
  printf '%s\n' "$CANDS" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  echo "  当前设置下的替换计划 PLAN_NOW: $(printf '%s\n' "$PLAN_NOW" | grep -c . ) 个"
  printf '%s\n' "$PLAN_NOW" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  echo "  全部关闭「保留」后的计划 PLAN_MAX: $(printf '%s\n' "$PLAN_MAX" | grep -c . ) 个"
  echo "  被保留(不会替换)的槽位 = PLAN_MAX - PLAN_NOW:"
  printf '%s\n' "$PLAN_MAX" | while IFS= read -r L; do
    [ -n "$L" ] || continue
    printf '%s\n' "$PLAN_NOW" | grep -qxF "$L" || echo "      $L"
  done
  echo "  实际写入 slots.applied 的槽位:"
  printf '%s\n' "$APPLIED_LIST" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  echo "  已应用槽位里是否包含 .ttc 合集: $APPLIED_TTC 个（设备上共 $TTCNUM 个 .ttc）"
}

# ---------------------------------------------------------------------------
# 【5】实际生效的字体目录与文件 —— 精准适配靠这一节
#   Android 解析规则：XML 里写绝对路径的按绝对路径读；只写文件名的按 /system/fonts/名字 读。
#   这里把符号链接展开、比较目录 dev:ino，区分"同一份目录"与"独立副本"。
# ---------------------------------------------------------------------------
sec5() {
  echo
  echo "【5】实际生效的字体目录与文件（最重要：精准适配靠这一节）"
  hr
  echo "  Android 规则：XML 里写绝对路径的按绝对路径读；只写文件名的按 /system/fonts/文件名 读。"
  echo
  echo "  1) 本机字体目录（符号链接已展开；dev:ino 相同 = 同一份目录，只需替换一次）"
  echo "     目录                     真实路径                    dev:ino        文件数  占用      与之相同的目录"
  printf '%s\n' "$FONTDIR_MAP" | while IFS='|' read -r d real idn cnt szk same; do
    [ -n "$d" ] || continue
    [ "$real" = "$d" ] && real="（自身）"
    printf '     %-24s %-26s %-14s %-7s %-9s %s\n' "$d" "$real" "$idn" "$cnt" "${szk}KB" "${same:-—}"
  done
  echo
  echo "  2) 配置里引用的字体 → 框架实际会读的路径"
  echo "     （★ 表示还存在一份独立副本；只替换一份的话，个别应用可能读到旧字体）"
  echo "     名字                                   框架实际读取的路径                           存在  副本"
  printf '%s\n' "$NAMEMAP" | while IFS='|' read -r n p real st dup; do
    [ -n "$n" ] || continue
    printf '     %-38s %-44s %-4s %s\n' "$n" "$real" "$st" "${dup:-—}"
  done
  echo
  echo "  3) 当前替换计划落在哪些目录（对照第 1 步，看有没有「白挂」在没人读的目录上）"
  printf '%s\n' "$PLAN_NOW" | while IFS=' ' read -r role rel; do
    [ -n "$rel" ] || continue
    echo "${rel%/*}"
  done | sort | uniq -c | while read -r c dd; do
    real=$(readlink -f "/$dd" 2>/dev/null); [ -n "$real" ] || real="/$dd"
    printf '     %-4s 个 → /%-22s %s\n' "$c" "$dd" "$([ "$real" != "/$dd" ] && echo "(→ $real)")"
  done
  echo
  echo "  4) 这些目录当前是否被挂载覆盖："
  "$MO" 2>/dev/null | grep -E '/system/fonts|/product/fonts|/system_ext/fonts|/vendor/fonts|/odm/fonts' | head -n 8 | while IFS= read -r L; do echo "      $L"; done
  hr
  echo "  小结：$(dir_conclusion)"
  echo "  （把这一节连同第 6 节一起看：第 6 节说明中文/主字体指向哪个文件，本节说明那个文件到底在哪个目录里被读）"
}

# ---------------------------------------------------------------------------
sec6() {
  echo
  echo "【6】字体配置：中文与主字体指向哪个文件、引用的文件是否存在"
  hr
  echo "  /system/fonts 文件总数: $SYSFONT_N"
  echo "  .ttc 合集清单（本模块不支持替换）:"
  printf '%s\n' "$TTC_LIST" | while IFS= read -r L; do
    [ -n "$L" ] || continue
    echo "      $L  $(size_kb "/system/fonts/$L")  faces=$(ttc_faces "/system/fonts/$L")  sha256=$(sha256sum "/system/fonts/$L" 2>/dev/null | cut -d' ' -f1)"
  done
  [ "$TTCNUM" = 0 ] && echo "      （无）"
  echo "  简中 zh-Hans 是否指向 .ttc: $([ "$ZH_TTC" = 1 ] && echo '是 ★ 中文不会被本模块替换' || echo 否)"
  for x in $XMLFOUND; do
    echo "  ---- ${x##*/} 里的 zh 相关 family ----"
    xmlnorm "$x" | grep -i -A 14 '<family[^>]*lang="zh' | head -n 60 | while IFS= read -r L; do echo "      $L"; done
    echo "  ---- ${x##*/} 里的 sans-serif family ----"
    xmlnorm "$x" | grep -i -A 20 '<family[^>]*name="sans-serif"' | head -n 45 | while IFS= read -r L; do echo "      $L"; done
  done
  echo "  配置里引用到的字体文件名 → 设备上是否存在（完整映射见第 5 节）:"
  printf '%s\n' "$XMLNAMES" | while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in */*) continue ;; esac
    if [ -f "/system/fonts/$n" ]; then
      echo "      ✅ $n"
    else
      hit=$(for d in $FONTDIRS; do [ -f "$d/$n" ] && echo "$d/$n"; done | head -n1)
      if [ -n "$hit" ]; then echo "      ✅ $n  ($hit)"
      else echo "      ❌ 配置引用了但设备上找不到: $n"; fi
    fi
  done
  echo "  运行时字体列表（部分机型支持 cmd font dump）:"
  "$CMD" font dump sans-serif 2>/dev/null | head -n 30 | while IFS= read -r L; do echo "      $L"; done
  "$CMD" font dump 2>/dev/null | head -n 15 | while IFS= read -r L; do echo "      [dump] $L"; done
  dumpsys font 2>/dev/null | head -n 15 | while IFS= read -r L; do echo "      [dumpsys] $L"; done
}

# ---------------------------------------------------------------------------
sec7() {
  echo
  echo "【7】字体来源排查：系统上「真正生效的字体」有没有被别的东西接管"
  hr
  echo "  字体相关设置项(settings):"
  printf '%s\n' "$S_FONT" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  [ -z "$S_FONT" ] && echo "      （无）"
  echo "  已安装的字体包（monotype / flipfont / font）:"
  printf '%s\n' "$PKG_FONT" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  [ -z "$PKG_FONT" ] && echo "      （无）"
  echo "  /data/app 下的字体包目录:"
  ls -d /data/app/*font* /data/app/*monotype* 2>/dev/null | head -n 10 | while IFS= read -r L; do echo "      $L"; done
  echo "  Android 可更新字体 /data/fonts:"
  printf '%s\n' "$DFONT_LIST" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  [ -z "$DFONT_LIST" ] && echo "      （不存在）"
  if [ -n "$DFONT_CFG" ]; then
    echo "  /data/fonts/config/config.xml:"
    printf '%s\n' "$DFONT_CFG" | while IFS= read -r L; do echo "      $L"; done
  fi
  echo "  三星主题/字体 overlay 目录:"
  ls -la /data/overlays 2>/dev/null | head -n 12 | while IFS= read -r L; do echo "      $L"; done
  ls -d /data/overlays/*font* /data/overlays/*/*font* 2>/dev/null | head -n 10 | while IFS= read -r L; do echo "      $L"; done
  [ -d /data/overlays ] || echo "      （不存在）"
  echo "  Samsung floating_feature.xml 里与字体相关:"
  grep -i 'font' /system/etc/floating_feature.xml 2>/dev/null | head -n 15 | while IFS= read -r L; do echo "      $L"; done
  echo "  属性里与字体/OneUI 相关:"
  "$GP" 2>/dev/null | grep -iE 'font|oneui|ro\.sem|knox' | head -n 20 | while IFS= read -r L; do echo "      $L"; done
  echo "  属性里与 KernelSU/校验 相关:"
  "$GP" 2>/dev/null | grep -iE 'ksu|kernelsu|verity|warranty|bootloader|selinux|secure' | head -n 20 | while IFS= read -r L; do echo "      $L"; done
  echo "  APEX 里与字体相关:"
  ls -1 /apex 2>/dev/null | grep -i font | while IFS= read -r L; do echo "      $L"; done
  echo "  MIUI / HyperOS 个性字体（主题字体）—— 会接管系统字体:"
  if [ "$MIUI_FONT_N" -gt 0 ]; then
    echo "      目录: $MIUI_DIRS"
    printf '%s\n' "$MIUI_FONTLIST" | while IFS= read -r L; do
      [ -n "$L" ] || continue
      echo "      $L  $(size_kb "$L")  mtime=$(mstamp "$L")"
    done
    echo "      与系统字体同名的（会顶替系统字体）: ${MIUI_SHADOW:-无}"
  else
    echo "      （未检测到个性字体，系统字体走 /system/fonts 等系统目录）"
  fi
  echo "  MIUI / 主题 相关目录:"
  for td in /data/system/theme /data/miui/theme /data/miui/themes /data/system/theme_font; do
    [ -e "$td" ] && echo "      $td  $(ls -1 "$td" 2>/dev/null | head -n 8 | tr '\n' ' ')"
  done
  echo "  属性/设置里与 MIUI 字体相关:"
  "$GP" 2>/dev/null | grep -iE 'miui|hyperos|mi\.os|theme' | head -n 15 | while IFS= read -r L; do echo "      [prop] $L"; done
  { "$SETBIN" list system 2>/dev/null; "$SETBIN" list secure 2>/dev/null; } | grep -iE 'theme|font' | grep -viE 'scale|size' | head -n 10 | while IFS= read -r L; do echo "      [setting] $L"; done
}

# ---------------------------------------------------------------------------
sec8() {
  echo
  echo "【8】/system/fonts 完整清单与权限标签"
  hr
  echo "  /system/fonts 内容（名称 大小 权限 标签）:"
  ls -lZ /system/fonts 2>/dev/null | head -n 250 | while IFS= read -r L; do echo "      $L"; done
  echo "  /system/fonts 总占用: $(du -sk /system/fonts 2>/dev/null | cut -f1) KB"
  echo "  字体库文件（$(printf '%s\n' "$LIB_FONTS" | grep -c . ) 个）:"
  ls -lZ "$LIB"/f*.ttf 2>/dev/null | head -n 30 | while IFS= read -r L; do echo "      $L"; done
  echo "  字体库名称/元数据:"
  for f in $LIB_FONTS; do
    i=${f##*/}; i=${i%.ttf}
    echo "      $i  name=$(cat "$LIB/$i.name" 2>/dev/null | tr -d '\r\n')  meta=$(tr '\n' ',' < "$LIB/$i.meta" 2>/dev/null | sed 's/,$//')"
  done
  echo "  字体库文件首 4 字节与表标签:"
  for f in $LIB_FONTS; do
    echo "      ${f##*/}  $(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')  标签: $(sfnt_tags "$f")"
  done
  if [ -n "$TTCFIRST" ]; then
    echo "  系统中文合集 $TTCFIRST: faces=$(ttc_faces "/system/fonts/$TTCFIRST")  头=$(ttc_tag "/system/fonts/$TTCFIRST")  标签: $(sfnt_tags "/system/fonts/$TTCFIRST")"
  fi
  echo "  磁盘: /data 剩余 $(df -k /data 2>/dev/null | tail -n1 | tr -s ' ' | cut -d' ' -f4) KB   模块目录占用 $(du -sk "$M" 2>/dev/null | cut -f1) KB"
}

# ---------------------------------------------------------------------------
sec9() {
  echo
  echo "【9】其它可能冲突的模块 / 字体相关文件"
  hr
  echo "  判定规则：只把「会挂到系统分区上的字体」算冲突（system/**/fonts 或根级厂商分区）；"
  echo "  webroot/webui 等界面目录里自带的字体不算（早期版本会误报，例子：ReZygisk）。"
  echo "  当前被判为字体冲突的模块（fontctl.sh conflicts）:"
  sh "$MODDIR/fontctl.sh" conflicts 2>/dev/null | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  echo "  各模块的系统字体目录:"
  for d in /data/adb/modules/*/; do
    [ -d "$d" ] || continue
    [ "$(basename "$d")" = "$ID" ] && continue
    for sub in system/fonts system/product/fonts system/system_ext/fonts system/vendor/fonts \
               system/odm/fonts vendor/fonts product/fonts system_ext/fonts odm/fonts \
               my_product/fonts mi_ext/fonts prism/fonts optics/fonts; do
      [ -d "$d$sub" ] || continue
      echo "      ${d#/data/adb/modules/}$sub :"
      ls -1 "$d$sub" 2>/dev/null | head -n 10 | while IFS= read -r L; do echo "          $L"; done
    done
  done
  echo "  其它模块里的 fonts*.xml:"
  ls -1 /data/adb/modules/*/system/etc/font*.xml 2>/dev/null | head -n 10 | while IFS= read -r L; do echo "      $L"; done
  echo "  界面目录里自带的字体（不算冲突，仅记录）:"
  ls -1 /data/adb/modules/*/webroot/fonts/* /data/adb/modules/*/webui/fonts/* 2>/dev/null | head -n 10 | while IFS= read -r L; do echo "      $L"; done
  echo "  本模块 skip_mount: $([ -f "$M/skip_mount" ] && echo 有 || echo 无)"
}

# ---------------------------------------------------------------------------
sec10() {
  echo
  echo "【10】管理器日志与系统信息"
  hr
  echo "  内核: $(uname -a 2>/dev/null)"
  echo "  内核版本: $(cat /proc/version 2>/dev/null)"
  echo "  cmdline: $(cat /proc/cmdline 2>/dev/null | head -c 300)"
  echo "  uapi: ksud=$KSVER"
  echo "  /data/adb 目录:"
  ls -la /data/adb/ 2>/dev/null | head -n 20 | while IFS= read -r L; do echo "      $L"; done
  echo "  /data/adb/ksu/ 目录:"
  ls -la /data/adb/ksu/ 2>/dev/null | head -n 12 | while IFS= read -r L; do echo "      $L"; done
  echo "  /data/adb/ksu/log/:"
  ls -la /data/adb/ksu/log/ 2>/dev/null | head -n 12 | while IFS= read -r L; do echo "      $L"; done
  echo "  关键行（skip / safe mode / Magisk / post-fs-data / post-mount / exec）:"
  grep -a -E 'skip|safe mode|Magisk detected|post-fs-data|post-mount|exec /data/adb/modules' /data/adb/ksu/log/*.log 2>/dev/null | tail -n 30 | while IFS= read -r L; do echo "      $L"; done
  echo "  dmesg 中的 KernelSU 信息:"
  dmesg 2>/dev/null | grep -i -E 'kernelsu|ksud|ksu_' | tail -n 10 | while IFS= read -r L; do echo "      $L"; done
  echo "  电池/内存/存储:"
  echo "      MemTotal=$(sed -n 's/^MemTotal: *//p' /proc/meminfo 2>/dev/null)  MemAvailable=$(sed -n 's/^MemAvailable: *//p' /proc/meminfo 2>/dev/null)"
  df -k /data /cache /metadata 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  echo "  校验相关属性:"
  for p in ro.boot.verifiedbootstate ro.boot.flash.locked ro.boot.veritymode ro.security.vaultkeeper.feature ro.crypto.state ro.boot.warranty_bit ro.boot.bootloader ro.build.version.oneui ro.build.version.sem ro.build.version.security_patch; do
    echo "      $p=$($GP "$p" 2>/dev/null)"
  done
}

# ---------------------------------------------------------------------------
# 字体扒包：把「能离线重建槽位清单」的原始数据全部吐出来
#   - 所有 font*.xml 的完整原文
#   - 每个字体文件的 sha256 + 大小（哈希清单，用于核对 ROM 版本）
#   - 每个字体文件的首 4 字节与 sfnt 表标签（判断可变字体 / TTC）
#   - family -> 文件 -> 属性 的对应关系
#   - 所有字体目录的完整清单
# 沙盒端用 tools/gen_targets.py 解析本段，生成 targets/<rom>.list
# ---------------------------------------------------------------------------
pack_extra() {
  echo
  echo "@@SECTION:META"
  echo "time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  echo "brand=$($GP ro.product.brand 2>/dev/null)"
  echo "model=$($GP ro.product.model 2>/dev/null)"
  echo "device=$($GP ro.product.device 2>/dev/null)"
  echo "android=$($GP ro.build.version.release 2>/dev/null)"
  echo "sdk=$($GP ro.build.version.sdk 2>/dev/null)"
  echo "build=$($GP ro.build.display.id 2>/dev/null)"
  echo "oneui=$($GP ro.build.version.oneui 2>/dev/null)"
  echo "sem=$($GP ro.build.version.sem 2>/dev/null)"
  echo "kernel=$(uname -r 2>/dev/null)"
  echo "ksud=$KSVER"
  echo "manager=$RM"
  echo "module=${VER_MOD:-?}"
  echo "diag=${DIAG_VER:-?}"
  echo "rom=$(rom_name "$ROMID" 2>/dev/null)"
  echo "boot_id=$BOOTID"
  echo "uptime=$UP"
  echo "@@SECTION:FONTDIRS"
  printf '%s\n' "$FONTDIRS"
  echo "@@SECTION:FONTDIRMAP"
  echo "# 目录|真实路径|dev:ino|文件数|占用KB|与之相同的目录"
  printf '%s\n' "$FONTDIR_MAP"
  echo "@@SECTION:NAMEMAP"
  echo "# 名字|框架解析路径|真实路径|是否存在|同名副本"
  printf '%s\n' "$NAMEMAP"
  echo "@@SECTION:FONTS_SHA256"
  for d in $FONTDIRS; do
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      s=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
      [ -n "$s" ] || s=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)
      printf '%s  %s  %s\n' "$s" "$(stat -c %s "$f" 2>/dev/null)" "$f"
    done
  done
  echo "@@SECTION:FONT_META"
  for d in $FONTDIRS; do
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      printf '%s\t%s\t%s\n' "$f" "$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" "$(sfnt_tags "$f")"
    done
  done
  echo "@@SECTION:TTCHEAD"
  for d in $FONTDIRS; do
    for f in "$d"/*.ttc; do
      [ -f "$f" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$f" "$(ttc_tag "$f")" "$(ttc_faces "$f")" "$(stat -c %s "$f" 2>/dev/null)"
    done
  done
  echo "@@SECTION:XMLCONTENT"
  for x in $XMLFOUND; do
    echo "@@FILE:BEGIN $x"
    cat "$x" 2>/dev/null
    echo
    echo "@@FILE:END"
  done
  echo "@@SECTION:XMLFAMILY"
  for x in $XMLFOUND; do
    xmlfam "$x" | while IFS= read -r L; do
      case "$L" in
        '<family'*)
          FAM=$(printf '%s' "$L" | sed 's/>.*//; s/^<family *//')
          ;;
        '<font'*)
          FATT=$(printf '%s' "$L" | sed 's/>.*//; s/^<font *//')
          FNAME=$(printf '%s' "$L" | sed 's/.*>//' | tr -d '\r' | sed 's/^ *//; s/ *$//')
          [ -n "$FNAME" ] && printf '%s\t%s\t%s\n' "$FNAME" "$FAM" "$FATT"
          ;;
      esac
    done
  done
  echo "@@SECTION:DIRLIST"
  for d in $FONTDIRS; do
    echo "--- $d"
    ls -l "$d" 2>/dev/null
  done
  echo "@@SECTION:MODULEDIR"
  ls -la "$M" 2>/dev/null
  echo "--- module.prop"
  cat "$M/module.prop" 2>/dev/null
  echo "--- settings.conf"
  cat "$SETTINGS" 2>/dev/null
  echo "--- pending/active"
  echo "pending=$PEND"
  echo "active=$ACT"
  echo "@@SECTION:MODULEUPDATE"
  ls -la /data/adb/modules_update/ 2>/dev/null
  echo "--- 本模块在 modules_update 里的内容"
  ls -la "$UPD" 2>/dev/null | head -n 30
  echo "@@SECTION:MOUNTS"
  "$MO" 2>/dev/null | head -n 80
  echo "@@SECTION:LIBFONTS"
  ls -l "$LIB" 2>/dev/null
  for f in $LIB_FONTS; do
    printf '%s  %s  %s\n' "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" "$(stat -c %s "$f" 2>/dev/null)" "$f"
  done
  for f in $LIB_FONTS; do
    i=${f##*/}; i=${i%.ttf}
    echo "--- $i  name=$(cat "$LIB/$i.name" 2>/dev/null | tr -d '\r\n')"
    cat "$LIB/$i.meta" 2>/dev/null
  done
  echo "@@SECTION:DATAFONTS"
  ls -lR /data/fonts 2>/dev/null | head -n 60
  [ -f /data/fonts/config/config.xml ] && cat /data/fonts/config/config.xml 2>/dev/null
  echo "@@SECTION:MIUIFONT"
  echo "# 目录: $MIUI_DIRS"
  echo "# 与系统同名(会被接管): $MIUI_SHADOW"
  printf '%s\n' "$MIUI_FONTLIST"
  for td in $MIUI_DIRS; do
    echo "--- $td"
    ls -lZ "$td" 2>/dev/null | head -n 30
  done
  echo "@@SECTION:SETTINGSFONT"
  printf '%s\n' "$S_FONT"
  echo "@@SECTION:PACKAGES"
  printf '%s\n' "$PKG_FONT"
  echo "@@SECTION:SLOTS"
  echo "## slots.applied"
  printf '%s\n' "$APPLIED_LIST"
  echo "## slots.map"
  cat "$M/slots.map" 2>/dev/null
  echo "## PLAN_NOW（当前设置）"
  printf '%s\n' "$PLAN_NOW"
  echo "## PLAN_MAX（关闭所有保留）"
  printf '%s\n' "$PLAN_MAX"
  echo "@@SECTION:END"
}

# ---------------------------------------------------------------------------
report_full() {
  echo "== 自定义字体切换模块 · 一键体检报告 =="
  conclusion
  sec1
  sec2
  sec3
  sec4
  sec5
  sec6
  sec7
  sec8
  sec9
  sec10
  echo
  echo "== 报告结束 =="
}

# 把完整报告（含原始配置与哈希清单）写到 Download，成功时 SAVED=路径
write_kit() {
  local tmpf="$1"
  SAVED=""
  [ -s "$tmpf" ] || return 0
  mkdir -p "$DL" 2>/dev/null
  if cp -f "$tmpf" "$OUTFILE" 2>/dev/null; then
    chmod 666 "$OUTFILE" 2>/dev/null
    chown media_rw:media_rw "$OUTFILE" 2>/dev/null
    cp -f "$tmpf" "$OUTFILE2" 2>/dev/null
    chmod 666 "$OUTFILE2" 2>/dev/null
    chown media_rw:media_rw "$OUTFILE2" 2>/dev/null
    SAVED="$OUTFILE"
  fi
  mkdir -p "$LIB" 2>/dev/null
  cp -f "$tmpf" "$LIB/font_diag.txt" 2>/dev/null
  cp -f "$tmpf" /data/local/tmp/font_diag.txt 2>/dev/null
  # 附件：原始字体配置与完整清单（作者离线分析用）
  ATTD="$DL/字体体检附件"
  mkdir -p "$ATTD" 2>/dev/null
  for x in $XMLFOUND; do
    cp -f "$x" "$ATTD/${x##*/}" 2>/dev/null
    chmod 666 "$ATTD/${x##*/}" 2>/dev/null
  done
  [ -f /data/fonts/config/config.xml ] && cp -f /data/fonts/config/config.xml "$ATTD/data_fonts_config.xml" 2>/dev/null
  {
    echo "# /system/fonts 完整清单  $(date '+%Y-%m-%d %H:%M' 2>/dev/null)"
    echo "# 设备: $($GP ro.product.brand 2>/dev/null) $($GP ro.product.model 2>/dev/null)  Android $($GP ro.build.version.release 2>/dev/null)"
    echo "# 构建号: $($GP ro.build.display.id 2>/dev/null)"
    echo
    echo "## ls -l"
    ls -l /system/fonts 2>/dev/null
    echo
    echo "## 文件名 + 大小 + md5"
    md5sum /system/fonts/* 2>/dev/null
    echo
    echo "## 其它字体目录"
    for d in $FONTDIRS; do
      echo "--- $d"
      ls -l "$d" 2>/dev/null
    done
    echo
    echo "## slots.applied（当前实际替换的槽位）"
    printf '%s\n' "$APPLIED_LIST"
    echo
    echo "## 当前设置下的计划 PLAN_NOW"
    printf '%s\n' "$PLAN_NOW"
    echo
    echo "## PLAN_MAX（关闭所有保留后）"
    printf '%s\n' "$PLAN_MAX"
  } > "$ATTD/system_fonts_清单.txt" 2>/dev/null
  chmod 666 "$ATTD/system_fonts_清单.txt" 2>/dev/null
  chown media_rw:media_rw "$ATTD" 2>/dev/null
  chown media_rw:media_rw "$ATTD"/* 2>/dev/null
  return 0
}

# 生成完整报告包（体检 + 原始配置 + 哈希清单）
kit_report() {
  local tmpf="/data/local/tmp/.font_diag.$$"
  report_full > "$tmpf" 2>&1
  pack_extra >> "$tmpf" 2>&1
  write_kit "$tmpf"
  rm -f "$tmpf" 2>/dev/null
  return 0
}

case "$MODE" in
  brief)
    conclusion
    ;;
  save)
    kit_report
    if [ -n "$SAVED" ]; then
      echo "OK:$SAVED"
    else
      echo "ERROR:写入失败（检查存储空间后重试）"
    fi
    ;;
  install)
    kit_report
    conclusion
    echo
    if [ -n "$SAVED" ]; then
      echo "完整报告已保存到: Download/字体体检报告.txt（同时有 font_diag.txt）"
      echo "原始字体配置和系统字体清单在: Download/字体体检附件/"
      echo "（文件管理 → 内部存储 → Download → 把这个 txt 和「字体体检附件」文件夹一起发回给作者）"
    else
      echo "完整报告保存失败，请把上面这段截图发回给作者。"
    fi
    ;;
  *)
    report_full
    ;;
esac
exit 0
