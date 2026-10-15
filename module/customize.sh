#!/system/bin/sh
# 自定义字体切换模块 - 安装脚本（Magisk / KernelSU / APatch 通用）
# 刷机包里的文件已由管理器解压到 $MODPATH

LIB=/data/adb/custom_font_lib
MODID=$(sed -n 's/^id=//p' "$MODPATH/module.prop" | head -n1 | tr -d '\r')
OLD="/data/adb/modules/$MODID"

ui_print "*********************************"
ui_print "  自定义字体切换模块 $(sed -n 's/^version=//p' "$MODPATH/module.prop")"
ui_print "  默认不替换字体"
ui_print "  导入自己的字体一键切换"
ui_print "*****************************"

. "$MODPATH/common.sh"
mkdir -p "$LIB"

# 1.0.9：识别机型要读全部系统属性、还要找厂商目录，会花一两秒。
#   特意把话说在前面，免得用户看管理器"卡在那儿不动"以为死机了。
#   这一阶段等一下完全没问题 —— 它不是开机流程，不影响开机时间。
ui_print "- 正在检测你的机型与字体配置，请稍等…"
ROM_ID=$(detect_rom)
ROM_NAME=$(rom_name "$ROM_ID")
RM=$(root_manager)
echo "$ROM_ID" > "$MODPATH/current_rom"
ui_print "- 已识别：$ROM_NAME"

# 旧版设置在模块目录里，迁移到字体库目录（以后更新不会丢）
[ -f "$SETTINGS" ] || { [ -f "$OLD/settings.conf" ] && cp -f "$OLD/settings.conf" "$SETTINGS"; }

# 当前实际生效的字体（升级前的状态），用于界面显示"当前 / 待生效"
A=$(tr -d '[:space:]' 2>/dev/null < "$OLD/active_font")
[ -n "$A" ] || A=none
echo "$A" > "$MODPATH/active_font"
echo none > "$MODPATH/pending_font"

# 上次的选择：**尽量保住用户正在用的那套**（升级体验的关键）
#
# ⚠️ 原来这条链有两个毛病：
#   ① **`$OLD/active_font`（当前真正在用的）没被读** —— 它才是最该恢复的那个。
#      `pending_font` 只在"选完还没重启"时有意义；正常用着的时候它常常是 none。
#   ② `[ -n "$LAST" ] ||` 把 **"none" 也当成有效值** ——
#      于是 pending_font 里写着 none 时它挡住后面的来源，最后 apply none
#      → 用户升级完字体没了（真机反馈过"更新后变回默认"）。
#   现在：**跳过空值和 none**，一路找到第一个真正可用的来源。
#   顺序：字体库记录 → **当前生效** → 待生效
_pick() {   # $1=文件；echo 出值（空/none 视为无值）
  local v
  v=$(tr -d '[:space:]' 2>/dev/null < "$1")
  case "$v" in ""|none) return 0 ;; esac
  printf '%s' "$v"
}
LAST=$(_pick "$LIB/last_selection")
[ -n "$LAST" ] || LAST=$(_pick "$OLD/active_font")     # ★ 当前真正在用的
[ -n "$LAST" ] || LAST=$(_pick "$OLD/pending_font")
[ -n "$LAST" ] || LAST=none

for f in common.sh slots.sh mount.sh fontctl.sh update.sh google_font.sh gms_cache.sh nameclone.sh action.sh \
         diag.sh post-fs-data.sh post-mount.sh service.sh uninstall.sh; do
  chmod 755 "$MODPATH/$f" 2>/dev/null
done
rm -f "$MODPATH/customize.sh.bak" 2>/dev/null

ui_print " "
ui_print "- 识别到系统：$ROM_NAME"
ui_print "- Root 管理器：$(root_manager_name "$RM")"
if [ "$(mount_mode)" = manager ]; then
  ui_print "- 挂载方式：交给管理器 / 元模块"
else
  ui_print "- 挂载方式：模块自带挂载（无需元模块）"
fi

RESTORED=0
if [ "$LAST" != none ]; then
  ui_print "- 正在恢复上次的字体选择..."
  # ★ 2026-10-14：加"要等一会儿"的提示。
  #   为什么必须加：下一行 `fontctl.sh apply` 要**扫一遍机器上的字体配置 + 逐文件判定**，
  #   字体多的机器上要十几秒到一分钟。而这段时间安装界面**一行输出都没有** ——
  #   用户会以为卡死了、甚至去强杀管理器。真机反馈过。
  #   提示要写在 apply **之前**（写在后面就是马后炮了，用户已经等完了）。
  #   ⚠️ 改这里时别删：它不参与任何逻辑，纯粹是给用户看的。
  ui_print "  ⏳ 正在扫描你机器上的字体"
      ui_print "     大概十几秒到一分钟。"
      ui_print "     卡住不动是正常的，请稍等…"
  OUT=$(sh "$MODPATH/fontctl.sh" apply "$LAST" 2>&1 | tail -n1)
  case "$OUT" in
    OK:*)
      RESTORED=1
      ui_print "  已恢复：$(echo "$OUT" | cut -d: -f2)（$(echo "$OUT" | cut -d: -f3) 个槽位）"
      ;;
    *)
      ui_print "  恢复失败：${OUT#ERROR:}"
      ui_print "  已改为「无字体」"
      ui_print "  请开机后在 WebUI 重新选择"
      FALLBACK=0
      ;;
  esac
fi
# ★ 只有「恢复失败 **且** 兜底也没成功」时才清成 none。
#   这个 if 现在看起来是等价的（主项目没内置字体，兜底就是写 none），
#   但它是**给换皮/内置字体变体留的正确形状**：保时捷内置配色版的兜底会挑一套
#   可用配色（builtin_apply_first），而无条件的 `|| apply none` 会**紧接着把
#   它的结果覆盖回 none** → 用户重启后回到默认、必须重新选一次（真机踩到过）。
#   所以这里先算出 FALLBACK 再决定，别写死。
if [ "$RESTORED" = 1 ] || [ "${FALLBACK:-0}" = 1 ]; then
  :                                   # 已有可用选择，别动它
else
  sh "$MODPATH/fontctl.sh" apply none >/dev/null 2>&1
fi
sh "$MODPATH/fontctl.sh" prop >/dev/null 2>&1

LIB_COUNT=$(ls "$LIB"/f*.ttf 2>/dev/null | wc -l)
# ★ 2026-10-14：`conflicts` 也要扫一遍机器上的字体配置，会停一会儿。
#   上面第 100-102 行那两句是静默的，加上这句提示，用户才不会以为卡死。
ui_print "- 正在检查有没有其它字体模块…"
ui_print "  （也会扫一遍字体配置，稍等）"
CONFLICTS=$(sh "$MODPATH/fontctl.sh" conflicts 2>/dev/null | cut -d'|' -f2 | tr '\n' ' ')

ui_print " "
ui_print "===================================="
ui_print "字体库已有：$LIB_COUNT 个字体（$LIB）"
ui_print "更新模块不会丢失字体库"
ui_print "卸载模块会一并删除"
ui_print "===================================="
ui_print "使用方法：在模块管理器打开 WebUI"
ui_print "  1. 导入自己的 TTF/OTF 字体（可多选）"
ui_print "  2. 点选字体卡片切换"
ui_print "  3. 重启生效；选「无字体」即恢复默认"
if [ "$RM" = magisk ]; then
  ui_print " "
  ui_print "Magisk 没有 WebUI 入口"
  ui_print "请先安装 KsuWebUI，"
  ui_print "后点模块卡片上的「操作」按钮打开。"
fi
if [ -n "$CONFLICTS" ]; then
  ui_print " "
  ui_print "⚠ 检测到其他字体模块：$CONFLICTS"
  ui_print "  建议先停用它们，避免互相覆盖。"
fi
ui_print " "
ui_print "若选字体后没能开机，下次开机会自动"
ui_print "恢复为「无字体」。"

# ---------------------------------------------------------------------------
# 安装阶段不做任何耗时收集（避免刷入卡住）
#   这里只做几个文件判断 + getprop，毫秒级完成；完整诊断报告由用户手动触发：
#     · WebUI 里点「查看诊断报告」或「保存到 Download」（后台生成，界面不卡）
#     · 或点模块卡片的「操作」按钮
# ---------------------------------------------------------------------------
GD="无"; [ -f "$OLD/disable" ] && GD="有"
GU="无"; [ -f "$OLD/update" ] && GU="有（上一次安装没被激活）"
GS="无"; case "$(getprop persist.sys.safemode)$(getprop ro.sys.safemode)" in *1*) GS="有" ;; esac
GM="无"; { command -v magisk >/dev/null 2>&1 || [ -e /data/adb/magisk ]; } && GM="有"
ui_print " "
ui_print "- 设备：$(getprop ro.product.brand) $(getprop ro.product.model)"
ui_print "  Android $(getprop ro.build.version.release)"
ui_print "- 门禁速查："
ui_print "  已禁用=$GD   待激活=$GU"
ui_print "  安全模式=$GS   Magisk共存=$GM"
ui_print "- 需要诊断报告时："
ui_print "  在 WebUI 里点「查看诊断报告」，"
ui_print "  或点模块卡片上的「操作」按钮"
ui_print "  （不用手动保存）"
ui_print "  （生成完会自动存到 Download）"
ui_print "  报告只产出一个文件："
ui_print "  Download/完整体检报告.txt"
if [ -f "$MODPATH/diag.sh" ]; then
  cp -f "$MODPATH/diag.sh" /data/local/tmp/font_diag.sh 2>/dev/null
  chmod 755 /data/local/tmp/font_diag.sh 2>/dev/null
fi
ui_print "===================================="
ui_print "- 完成"

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in common.sh slots.sh mount.sh fontctl.sh update.sh google_font.sh gms_cache.sh nameclone.sh action.sh \
         diag.sh post-fs-data.sh post-mount.sh service.sh uninstall.sh; do
  set_perm "$MODPATH/$f" 0 0 0755
done
