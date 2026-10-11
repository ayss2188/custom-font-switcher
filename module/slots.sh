#!/system/bin/sh
# slots.sh - 字体槽位发现与分类
#
# 思路（吸取"按设备真实情况生成"的做法，而不是固定清单硬铺）：
#   1. 只替换设备上"真实存在"的字体文件，不凭空创建不存在的路径（减少挂载节点）
#   2. 候选来源：字体配置 XML 中的主文字族 ∪ 本 ROM 已知文件名 ∪ OEM 命名规则
#   3. 按文件名给每个槽位分角色，默认不碰：其他文字体系/日韩、符号/Emoji、
#      衬线/等宽/时钟/展示/斜体 等"高风险"槽位
#   4. 按字体实际覆盖范围决定范围（中英文 / 仅英文 / 仅中文）
#
# 用法（source 后调用）：
#   slot_plan <模块目录> <scope:all|latin|cjk> <keep_lang:0|1> <keep_special:0|1>
#     -> 每行输出 "角色 目标路径"，目标路径相对 /，如 latin system/fonts/Roboto-Regular.ttf
#   slot_report <模块目录>   -> 角色统计（诊断用）
#
# FSROOT 仅供测试：把真实路径前缀到一个模拟根目录下。

FSROOT=${FSROOT:-}

_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------------------
# 真实存在的字体目录（输出绝对路径，不含 FSROOT）
# ---------------------------------------------------------------------------
slot_dirs() {
  local d p parent
  {
    for d in /system/fonts /system_ext/fonts /product/fonts /vendor/fonts /odm/fonts /oem/fonts \
             /my_product/fonts /my_region/fonts /my_company/fonts /my_carrier/fonts /my_stock/fonts \
             /my_heytap/fonts /my_manifest/fonts /my_bigball/fonts /mi_ext/fonts /hw_product/fonts \
             /prism/fonts /optics/fonts /product/vivo/fonts /system_ext/vivo/fonts /vendor/vivo/fonts \
             /oplus_product/fonts /oplus_engineering/fonts /oplus_version/fonts /oplus_region/fonts; do
      [ -d "$FSROOT$d" ] && echo "$d"
    done
    # 未知厂商分区自动发现：/xxx/fonts 与 /xxx/yyy/fonts
    for d in "$FSROOT"/*/fonts "$FSROOT"/*/*/fonts; do
      [ -d "$d" ] || continue
      parent=${d%/fonts}
      [ -L "$parent" ] && continue          # /system/product 之类的符号链接，避免重复
      p=${d#"$FSROOT"}
      case "$p" in
        /data/*|/sdcard/*|/storage/*|/mnt/*|/proc/*|/sys/*|/dev/*|/apex/*|/linkerconfig/*|\
        /config/*|/metadata/*|/cache/*|/acct/*|/debug_ramdisk/*|/second_stage_resources/*|\
        /system/etc/*|/system/usr/*|/system/app/*|/system/priv-app/*) continue ;;
      esac
      echo "$p"
    done
  } | sort -u
}

# ---------------------------------------------------------------------------
# 字体配置 XML 文件列表
# ---------------------------------------------------------------------------
slot_xml_files() {
  local x
  for x in "$FSROOT"/system/etc/*font*.xml "$FSROOT"/system_ext/etc/*font*.xml \
           "$FSROOT"/product/etc/*font*.xml "$FSROOT"/vendor/etc/*font*.xml \
           "$FSROOT"/odm/etc/*font*.xml "$FSROOT"/*/etc/*font*.xml; do
    [ -f "$x" ] && echo "$x"
  done | sort -u
}

# ---------------------------------------------------------------------------
# 一次扫完所有字体配置，列出**所有被中文（lang 以 zh 开头）引用的 .ttc 合集**：
#   每行 "<文件名> <序号> <lang>"，例如
#   NotoSansCJK-Regular.ttc 2 zh-Hans
#   NotoSansCJK-Regular.ttc 3 zh-Hant,zh-Bopo
#
# 为什么要有它：一个合集里装着好几套字（实测三星 SM-S9280 与魅族 Flyme 12.6 都是
#   0=ja  1=ko  2=zh-Hans  3=zh-Hant,zh-Bopo），**只能换中文那几号**，
# 日/韩留着原字形，否则用户的中文字体没有假名/谚文字形，日韩文本就变方块。
#
# 性能：整份 XML 只起 2 个进程（tr + sed），和 slot_xml_names 一个路子；结果在同一个
# 进程里缓存（TTC_PAIRS_CACHE），一条命令里被问多次也只扫一遍。
# ---------------------------------------------------------------------------
ttc_cn_pairs() {
  local x fam hdr body rest attrs name l idx
  if [ -z "${TTC_PAIRS_CACHE+x}" ]; then
    TTC_PAIRS_CACHE=$(
      for x in $(slot_xml_files); do
        [ -f "$x" ] || continue
        tr '\n\r\t' '   ' 2>/dev/null < "$x" | sed 's/<family/\n<family/g' \
          | while IFS= read -r fam || [ -n "$fam" ]; do
              case "$fam" in '<family'*) ;; *) continue ;; esac
              hdr=${fam%%>*}
              l=""
              case "$hdr" in *' lang="'*) l=${hdr#*' lang="'}; l=${l%%\"*} ;; esac
              case "$l" in [Zz][Hh]*) ;; *) continue ;; esac
              body=${fam#*>}
              rest=$body
              while :; do
                case "$rest" in *'<font'*) ;; *) break ;; esac
                rest=${rest#*<font}
                attrs=${rest%%>*}
                rest=${rest#*>}
                name=${rest%%<*}
                _trim "$name"
                case "$TRIM_OUT" in
                  *.[Tt][Tt][Cc])
                    idx=0
                    case "$attrs" in *' index="'*) idx=${attrs#*' index="'}; idx=${idx%%\"*} ;; esac
                    case "$idx" in ''|*[!0-9]*) idx=0 ;; esac
                    printf '%s %s %s\n' "$TRIM_OUT" "$idx" "$l"
                    ;;
                esac
              done
            done
      done | sort -u
    )
  fi
  [ -n "$TTC_PAIRS_CACHE" ] && printf '%s\n' "$TTC_PAIRS_CACHE"
  return 0
}

# ---------------------------------------------------------------------------
# 某个 .ttc 合集里"哪几号 face 是中文" —— 要换成用户字体的就是这几号
# 用法：ttc_cn_indices <文件名> [face总数]
#
# 兜底：这个文件一个中文引用都没有时，**只换 2 号**那一号 face。
#
# 为什么只换 2 号（以前是"2 号往后全换"）：2 号是 Noto / 三星这几套 CJK 合集里
# 简体中文（zh-Hans）的位置，这是最可靠的一个惯例；再往后是什么**完全没法保证**——
# 万一某机型的 3 号是日文，全换就会把日文换成用户字体、日文直接变方块。
# 换句话说：这里宁可"只让中文跟着变"，也不赌别的语言。
# （配置里能读到中文引用时走上面的 xml 分支，压根用不到这个兜底。）
#
# 顺便把"凭什么这么判"回填到两个全局变量，给诊断报告用（见 fontctl.sh 的 ttc.log）：
#   TTC_CN_SRC    = xml（按字体配置）/ fallback（按惯例兜底）/ none（没得换）
#   TTC_CN_DETAIL = 匹配到的 lang:index 明细，如 "zh-Hans:2 zh-Hant,zh-Bopo:3 "
# 注意：要拿到这两个变量，调用时别用 $(...) 包（那会开子 shell），改成重定向到临时文件再读。
# ---------------------------------------------------------------------------
ttc_cn_indices() {
  local want="$1" total="${2:-0}" pairs hans i
  TTC_CN_SRC="none"; TTC_CN_DETAIL=""
  pairs=$(ttc_cn_pairs 2>/dev/null | awk -v f="$want" '$1 == f { print $3 ":" $2 }' | sort -u)
  if [ -n "$pairs" ]; then
    TTC_CN_SRC="xml"     # 依据：字体配置里的 zh-* 引用
    # 繁体那一号要不要跳过 —— 1.0.8 起按"用户有没有自己调过 + 字体有没有繁体字形"判：
    #   · 用户自己调过 keep_lang  → 完全按他的（1=保留繁体 / 0=连繁体一起换）
    #   · 没调过 → 看字体 meta：没有繁体字形（hant=0）就跳过繁体那一号（免得变方块），有就一起换
    # 例外：如果这个合集**只**被繁中引用（纯繁体用户），就照换 —— 否则中文一点都不会变。
    _skip_hant=0
    _kl_user=$(sed -n 's/^keep_lang=//p' "$SETTINGS" 2>/dev/null | tail -n1 | tr -d '\r\n')
    if [ -n "$_kl_user" ]; then
      [ "$_kl_user" = 1 ] && _skip_hant=1
    else
      _meta_have hant || _skip_hant=1
    fi
    if [ "$_skip_hant" = 1 ]; then
      hans=$(printf '%s\n' "$pairs" | grep -vi 'hant\|bopo')
      if [ -n "$hans" ]; then
        TTC_CN_DETAIL="$(printf '%s' "$pairs" | tr '\n' ' ')（已跳过繁体那一号：你的字体没有繁体字形）"
        pairs="$hans"
      fi
    fi
    [ -n "$TTC_CN_DETAIL" ] || TTC_CN_DETAIL=$(printf '%s' "$pairs" | tr '\n' ' ')
    printf '%s\n' "$pairs" | sed 's/.*://' | sort -n -u
    return 0
  fi
  if [ "$total" -ge 3 ] 2>/dev/null; then
    TTC_CN_SRC="fallback"   # 配置里没找到中文引用 → 只按最可靠的惯例动 2 号
    TTC_CN_DETAIL="配置里没有中文引用，按惯例只换 2 号（zh-Hans 常见位置）"
    printf '2\n'
  fi
  return 0
}

# 某个 <family> 是否属于"主文字族"（无语言 / 拉丁 / 中文），排除衬线、等宽、Emoji 等
# 纯 shell 大小写不敏感匹配，不启动任何外部进程（性能关键）
_xml_family_ok() {
  case "$1" in
    *[Ee][Mm][Oo][Jj][Ii]*|*[Ss][Yy][Mm][Bb][Oo][Ll]*|*[Mm][Oo][Nn][Oo]*|*[Cc][Uu][Rr][Ss][Ii][Vv][Ee]*|\
    *[Cc][Aa][Ss][Uu][Aa][Ll]*|*[Mm][Aa][Tt][Hh]*|*[Mm][Uu][Ss][Ii][Cc]*|*[Cc][Ll][Oo][Cc][Kk]*)
      return 1 ;;
  esac
  case "$1" in
    *[Ss][Aa][Nn][Ss]-[Ss][Ee][Rr][Ii][Ff]*|*[Ss][Aa][Nn][Ss][Ss][Ee][Rr][Ii][Ff]*) : ;;
    *[Ss][Ee][Rr][Ii][Ff]*) return 1 ;;
  esac
  if [ -n "$2" ]; then
    case "$2" in
      *[Zz][Hh]*|*[Uu][Nn][Dd]-[Ll][Aa][Tt][Nn]*|[Ee][Nn]|[Ee][Nn]-*) : ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# 去掉字符串首尾空格（纯 shell，结果写入 TRIM_OUT，不启动进程）
_trim() {
  local s="$1"
  while case "$s" in ' '*) true ;; *) false ;; esac; do s=${s# }; done
  while case "$s" in *' ') true ;; *) false ;; esac; do s=${s% }; done
  TRIM_OUT="$s"
}

# 从 XML 里取主文字族引用的字体文件名
# 性能：整份 XML 只起 2 个进程（tr + sed），family/文件名都用 shell 内建解析；
# 旧写法是"每个 family 起 4~6 个进程"，500 个 family 会 fork 上千次，手机上要卡好几秒。
slot_xml_names() {
  local x fam hdr body rest name n l
  for x in $(slot_xml_files); do
    tr '\n\r\t' '   ' 2>/dev/null < "$x" \
      | sed 's/<family/\n<family/g' \
      | while IFS= read -r fam || [ -n "$fam" ]; do
          case "$fam" in '<family'*) ;; *) continue ;; esac
          hdr=${fam%%>*}
          n=""; l=""
          case "$hdr" in *' name="'*) n=${hdr#*' name="'}; n=${n%%\"*} ;; esac
          case "$hdr" in *' lang="'*) l=${hdr#*' lang="'}; l=${l%%\"*} ;; esac
          _xml_family_ok "$n" "$l" || continue
          # family 头之后的部分里，逐个取出 >名字< 形式的内容
          body=${fam#*>}
          rest=$body
          while :; do
            case "$rest" in
              *'>'*'<'*) ;;
              *) break ;;
            esac
            rest=${rest#*>}
            name=${rest%%<*}
            rest=${rest#*<}
            _trim "$name"; name="$TRIM_OUT"
            case "$name" in
              *.[Tt][Tt][Ff]|*.[Oo][Tt][Ff]) printf '%s\n' "$name" ;;
            esac
          done
        done
  done | sed 's#.*/##' | sort -u
}

# 本 ROM 已知文件名（targets/<rom>.list；aosp 清单始终包含）
slot_static_names() {
  local moddir="$1" rom list
  rom=$(tr -d '[:space:]' 2>/dev/null < "$moddir/current_rom")
  for list in "$moddir/targets/$rom.list" "$moddir/targets/aosp.list"; do
    [ -f "$list" ] || continue
    grep -v '^#' "$list" | tr -d '\r' | sed 's#.*/##' | grep -v '^[[:space:]]*$'
  done | sort -u
}

# OEM 命名规则：扫描真实目录，匹配厂商主字体命名
slot_oem_names() {
  local moddir="$1" rom pat d b l t
  rom=$(tr -d '[:space:]' 2>/dev/null < "$moddir/current_rom")
  case "$rom" in
    coloros)  pat='sysfont*|syssans*|oplussans*|oplusosui*|opposans*|opsans*|din*|oppodin*|sourcesanspro*' ;;
    originos) pat='*vivosans*|*vivo-sans*|*originsans*|*origin-sans*|*iqoosans*|*iqoo-sans*' ;;
    flyme)    pat='*flymefont*|*flymesans*|*flyme-sans*|*meizusans*|*meizu-sans*|*mflyme*' ;;
    *) return 0 ;;
  esac
  t="${TMPDIR:-/data/local/tmp}/.oem.$$"
  for d in $(slot_dirs); do
    ls -1 "$FSROOT$d" 2>/dev/null > "$t"
    tr '[:upper:]' '[:lower:]' < "$t" > "$t.l"
    exec 3< "$t"; exec 4< "$t.l"
    while IFS= read -r b <&3 && IFS= read -r l <&4; do
      case "$l" in *.ttf|*.otf) ;; *) continue ;; esac
      case "$l" in
        $pat) [ -f "$FSROOT$d/$b" ] && echo "$b" ;;
      esac
    done
    exec 3<&- 4<&-
  done | sort -u
  rm -f "$t" "$t.l" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 角色分类（按文件名；输出之一）：
#   sym     符号 / Emoji / 图标 / 彩色            默认永不替换
#   lang    其他文字体系 / 日韩                     keep_lang=1 时不替换
#   italic  斜体                                   keep_special=1 时不替换
#   serif mono clock display                       keep_special=1 时不替换
#   latin   拉丁主字体（Roboto / GoogleSans 等）
#   cjk     中文专用槽位（Hans / Hant / SC / TC）
#   main    其他主文字槽位（OEM 中英混合主字体、数字命名权重文件等）
# ---------------------------------------------------------------------------
_role_set() {
  local l="$1"
  case "$l" in
    *emoji*|*symbol*|*icon*|*material*|*color*|*flag*|*dingbat*|*lottie*|*braille*|*mathematical*|*music*)
      ROLE=sym; return ;;
    *kore*|*hangul*|*korean*|*jpan*|*japan*|*kana*|*jp[-_.]*|*kr[-_.]*|\
    *arab*|*hebr*|*thai*|*deva*|*beng*|*taml*|*telu*|*gujr*|*guru*|*knda*|*mlym*|*orya*|*sinh*|\
    *khmr*|*khmer*|*laoo*|*mymr*|*myanmar*|*geor*|*armn*|*ethi*|*tibt*|*tibetan*|*cherokee*|\
    *milanpro*|*naskh*|*nastaliq*|*kufi*|*lao[-_.]*)
      ROLE=lang; return ;;
    *clock*) ROLE=clock; return ;;
    *mono*|*courier*|*cutive*|*michroma*|*consol*|*monaco*|*menlo*) ROLE=mono; return ;;
    *italic*|*oblique*) ROLE=italic; return ;;
    *sansserif*|*sans-serif*) : ;;
    *serif*) ROLE=serif; return ;;
  esac
  case "$l" in
    *lobster*|*dancing*|*comingsoon*|*carrois*|*dela*|*chamberi*|*gulfs*|*neumatic*|*interscaled*|\
    *bebas*|*beihai*|*silk*|*condensed*|*cond[-_.]*|*rounded*|*square*|*hz[-_.]*|*qinghe*|*mihaus*|\
    *c800*|*rcf*)
      ROLE=display; return ;;
  esac
  case "$l" in
    # 繁体/香港专用的那一份，归到 lang（=「保留日韩及其他文字」管的范围）。
    # 原因：很多用户导入的是"简体字库"或某字体的 SC 版，里面没有 靉/鶚/懞 这类繁体字；
    # 而 MIUI 的 zh-Hant 家族正好指向 MiSansTCVF.ttf 这类文件 —— 一旦被顶掉，
    # 后面没有别的兜底，那些字就变成方块。保持让它走系统字体最安全；
    # 用户若确实想让繁体也换，把「保留日韩及其他文字的字体槽」关掉即可。
    # 注意：这一组必须排在 `*hans*` 前面，否则 SourceHanSansHK 这类会被 hans 抢先吃掉。
    *hant*|*tc[-_.]*|*tcvf*|*misanstc*|*traditional*|*big5*|*hk[-_.]*) ROLE=lang; return ;;
    *hans*|*cjk*|*chinese*|*sc[-_.]*|*misansl3*) ROLE=cjk; return ;;
    roboto*|googlesans*|google-sans*|productsans*|*latin*|samsungone*|notosans-*|\
    miuiex*|mitype*|inter*|opensans*|lato*|sourcesans*|worksans*|nunito*) ROLE=latin; return ;;
  esac
  ROLE=main
}

# 对外接口：输入原始文件名，输出角色
slot_role() { _role_set "$(_lc "$1")"; echo "$ROLE"; }

# ---------------------------------------------------------------------------
# 自动让路（2026-10-12 新增）—— 1.0.8 的核心
#
# 背景：以前"日文/韩文/繁体"和"时钟/斜体/衬线"默认**保留系统字体**，理由是"怕用户字体缺字形"。
#   但作者指出：**用户装了字体就是想全变**，默认保守反而让人以为"模块没生效"；
#   而"缺字形"这件事**导入时就已经测出来了**（界面用 JS 探针把 latin/cjk/hant/kana/hangul
#   写进 $LIB/<id>.meta），根本不用等用户看到方块再回来关开关。
#
# 所以改成：**默认全替换**；只有"字体确实没有那一类字形"时，才**自动**把那部分留给系统字体。
#   · meta 说没有韩文     → 韩文槽位自动保留（不会造方块）
#   · meta 说都有         → 全部替换（用户要的"全局生效"）
#   · 老字体没有 meta     → 保守保留（宁可少换，也不给用户造方块）
# 用户不需要懂这些；报告里会写清"哪些没换、因为你的字体没有那些字形"。
# ---------------------------------------------------------------------------
_meta_have() {   # $1=latin|cjk|hant|kana|hangul  → 0=可以换（有字形，或未知）/ 1=字体确实没有
  local k="$1" id v
  case "$k" in latin|cjk|hant|kana|hangul) ;; *) return 0 ;; esac
  [ -n "${LIB:-}" ] || return 0
  # 选中的字体：优先用外面传进来的（make_plan 会设），否则读 pending_font（开机脚本也用得上）
  id="${SEL_FONT:-}"
  [ -n "$id" ] || id=$(tr -d '[:space:]' 2>/dev/null < "${MODDIR:-}/pending_font")
  case "$id" in ""|none) return 0 ;; esac
  id=${id%%+*}                       # 组合字体（a+b）取主字体做判定
  # 没有元数据（老字体、导入时没测到）→ 按"有"处理、照换。
  #   为什么不保守：保守会让用户看到"某处永远不变"，那正是作者最烦的现象；
  #   而"字体确实缺字形"的情况正常都会被 meta 记下来（hangul=0 这种），不会走到这里。
  [ -f "$LIB/$id.meta" ] || return 0
  v=$(sed -n "s/^$k=//p" "$LIB/$id.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')
  case "$v" in
    1) return 0 ;;                   # 有 → 可以替换
    *) return 1 ;;                   # 0 或空 → 让路
  esac
}

# 某个槽位需要哪一类字形（用文件名判，够稳且不依赖文件名之外的任何东西）
#   hangul 韩文 / kana 日文假名 / hant 繁体 / cjk 其它中文（含简体、没写明语言的 CJK 槽）
_slot_script() {
  case "$1" in
    *[Kk]orean*|*[Hh]angul*|*[Kk]ore*)                  echo hangul ;;
    *[Jj]apan*|*[Kk]ana*)                              echo kana ;;
    *[Tt][Cc][Vv][Ff]*|*[Tt]raditional*|*[Bb]ig5*)  echo hant ;;
    *[Ss]erif[Cc][Jj][Kk]*|*[Cc][Jj][Kk]*)              echo cjk ;;
    *) echo "" ;;
  esac
}

# 该角色在当前设置下是否参与替换
_role_wanted() {
  local role="$1" scope="$2" keep_lang="$3" keep_special="$4" name="${5:-}"
  case "$role" in
    # ttc = .ttc 合集槽位（三星简中这类）。合集里同时装着 ja/ko/zh 好几套字形，
    # 只有用户选的是"中英文/全覆盖"字体时替换才合理，所以限定 scope=all。
    ttc)
      [ "$scope" = all ] || return 1
      return 0 ;;
    sym) return 1 ;;
    lang)
      [ "$keep_lang" = 1 ] && return 1
      [ "$scope" = all ] || return 1
      # 1.0.8：**按槽位**自动让路（比"缺一类就整体保留"精确得多）：
      #   韩文槽位只在字体真的没有韩文字形时才留，繁中是繁中、日文是日文，互不牵连。
      # 判不出来（文件名看不出语言）→ 保守保留，宁可少换也不造方块。
      # ★ 只在"用户没自己调过这个开关"时才自动让路：他手动选了全替换（或从界面切过开关），
      #   就完全按他的来 —— 这正是"出问题给个开关、遇到了就开/关"的语义。
      [ "${SLOT_AUTO_RESERVE:-1}" = 1 ] || return 0
      case "$(_slot_script "$name")" in
        hangul) _meta_have hangul || return 1 ;;
        kana)   _meta_have kana   || return 1 ;;
        hant)   _meta_have hant   || return 1 ;;
        cjk)    _meta_have cjk    || return 1 ;;
        *)      return 1 ;;
      esac
      return 0 ;;
    italic|serif|mono|clock|display)
      [ "$keep_special" = 1 ] && return 1 ;;
  esac
  case "$scope" in
    latin) case "$role" in latin|italic|serif|mono|clock|display) return 0 ;; esac; return 1 ;;
    cjk)   [ "$role" = cjk ] && return 0; return 1 ;;
    *)     return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# 候选枚举：输出 "角色 目录 文件名"（目录为真实路径），仅限设备上真实存在的文件
# 整份名单只转一次小写、成对读取，避免为每个文件名单独启动外部进程
# ---------------------------------------------------------------------------
slot_candidates() {
  local moddir="$1" t name l d dirs
  t="${TMPDIR:-/data/local/tmp}/.cand.$$"
  mkdir -p "${t%/*}" 2>/dev/null
  { slot_xml_names; slot_static_names "$moddir"; slot_oem_names "$moddir"; } \
    | grep -v '^[[:space:]]*$' | sort -u > "$t"
  tr '[:upper:]' '[:lower:]' < "$t" > "$t.l"
  dirs=$(slot_dirs)
  exec 3< "$t"; exec 4< "$t.l"
  while IFS= read -r name <&3 && IFS= read -r l <&4; do
    case "$l" in *.ttf|*.otf) ;; *) continue ;; esac
    _role_set "$l"
    for d in $dirs; do
      [ -f "$FSROOT$d/$name" ] && printf '%s %s %s\n' "$ROLE" "$d" "$name"
    done
  done
  exec 3<&- 4<&-
  rm -f "$t" "$t.l" 2>/dev/null

  # .ttc 合集槽位（三星这类机器的中文，见 common.sh 的 ttc_enabled）：
  # 三星简中来自 .ttc 合集，单文件字体顶不了 —— 由 fontctl 把用户的字体包成
  # "同样 face 数"的 TTC 再挂上去（见 ttcwrap.sh）。
  # 默认 auto：三星自动开；其它机器不开（可在界面「替换范围（高级）」里手动打开）。
  if ttc_enabled; then
    for d in $dirs; do
      for f in "$FSROOT$d"/*.ttc "$FSROOT$d"/*.TTC; do
        [ -f "$f" ] || continue
        case "${f##*/}" in *'*') continue ;; esac      # glob 没匹配到会原样留着
        printf 'ttc %s %s\n' "$d" "${f##*/}"
      done
    done
  fi
}

# ---------------------------------------------------------------------------
# 生成槽位计划
# ---------------------------------------------------------------------------
# 主题字体槽位（MIUI / HyperOS / 三星）：
#   小米把"设置 → 显示 → 字体大小和样式"里选的字体放在 /data/system/theme/fonts/，
#   **同名文件优先级高于 /system/fonts** —— 于是那几个名字（MiuiEx-*.ttf、Roboto-*.ttf）
#   永远是主题字体，模块换了系统目录也看不到变化，报告只能让用户"切回默认再重启"。
#   三星是同一个机制，目录不同：/data/overlays/font/（在"设置 → 字体大小和样式"里
#   选了字体包/flipfont 之后，落点就在这里）。
#   这里把这几个也纳入计划：只挑「名字和本次计划里已有槽位完全相同」的，
#   覆盖范围跟用户的选择一致，不多碰主题自带的其他文件。
#   注意：/data 上的文件在"交给管理器挂载"模式下挂不了（魔法挂载只覆盖系统分区），那种模式直接跳过。
#
# ★ 默认**不做**这件事（theme_fonts=0）★ —— 有真机教训：
#   MIUI/HyperOS 把"设置 → 字体样式"里选的字体放在 data/system/theme/fonts，
#   而且**整目录都是一个真实文件 + 一堆符号链接**（实测 18 个文件全指向 Roboto-Regular.ttf）。
#   我们去替换它，就等于把用户在设置里做的选择盖掉：
#     · 用户选「小米兰亭 Pro」是为了用它的**可变字重轴**调粗细 —— 被换成单字重字体后，
#       「字体粗细」直接调不动了（真机反馈："小米兰亭pro 已经字体都不生效了"）
#     · 挂载落在**符号链接**上本身也不可靠（同一台机器上"实际生效"校验会少一个）
#   所以改成可选：界面上的「也替换设置里选的字体」开关，默认关。
# 某个目录里有没有"可变字体"（带 fvar 轴的表）—— 小米那台用于调「字体粗细」的就是它。
# 只看文件头部的表目录（前 4KB），不做全文件扫描：够用且快。
_has_varfont() {
  local d="$1" f
  for f in "$FSROOT$d"/*.ttf "$FSROOT$d"/*.otf "$FSROOT$d"/*.TTF "$FSROOT$d"/*.OTF; do
    [ -f "$f" ] || continue
    case "${f##*/}" in *'*') continue ;; esac
    if head -c 4096 "$f" 2>/dev/null | grep -qa 'fvar'; then return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# 1.0.8：主题字体目录（"设置里选的那个字体"）要不要一起替换 —— **自动判，不要用户操心**
#
# 为什么删掉那个开关：实测那个开关是"静默空转" —— theme_slots 只挑「名字和系统槽位完全相同」
#   的文件，而各家目录里常常是 flymeFont.ttf、MiuiEx-*.ttf 这类对不上的名字，开关开着也什么都不做，
#   用户还以为"多挂了一个目录"。改成按机型/按事实自动判，判不出来就**不动**（保守）。
#
# 判据（全部来自真机报告，见 跨项目同步表 10.41 / 1.0.8-设计稿 第六节）：
#   flyme    /data/customizecenter/font  → 无条件的"主题字体"，一起换（魅族那台已验证）
#   hyperos  /data/system/theme/fonts    → ★ 先看有没有**可变字体**：
#                                          有 → 那是用户拿来调「字体粗细」的，**不碰**（真机教训）
#                                          没有 → 一起换
#   samsung  /data/overlays/font         → 一起换
#   originos /data/vfonts                → 一起换（VivoFont.ttf 是指向它的符号链接，会挂真身）
#   其它/判不出                            → **不动**
# ---------------------------------------------------------------------------
_theme_auto_ok() {
  local rom d
  rom=$(_rom_cached)
  case "$rom" in
    flyme)
      [ -d "$FSROOT/data/customizecenter/font" ] && return 0
      return 1 ;;
    hyperos)
      d=/data/system/theme/fonts
      [ -d "$FSROOT$d" ] || return 1
      _has_varfont "$d" && return 1      # 有可变字体 → 尊重用户在设置里调的粗细，不动
      return 0 ;;
    samsung)
      [ -d "$FSROOT/data/overlays/font" ] && return 0
      return 1 ;;
    originos)
      [ -d "$FSROOT/data/vfonts" ] && return 0
      return 1 ;;
  esac
  return 1
}

theme_slots() {
  local base="$1" names d tdir f n real
  [ "$(mount_mode 2>/dev/null)" = manager ] && return 0
  # 1.0.8：不再要用户点开关 —— 按机型**自动判**。三条路：
  #   theme_fonts=1 / 0  ：用户在界面上手动指定过，照办
  #   未设置（默认）      ：自动 —— 见下面 _theme_auto_ok
  case "$(cfg_get theme_fonts auto)" in
    1) ;;
    0) return 0 ;;
    *) _theme_auto_ok || return 0 ;;
  esac
  names=$(printf '%s\n' "$base" | while read -r _r _p; do
            [ -n "$_p" ] || continue
            printf '%s\n' "${_p##*/}"
          done | sort -u)
  [ -n "$names" ] || return 0
  # 各家"在设置里选的字体"落点都看；.ttc 也在内（apply 的合集分支会按目标 face 数合成）
  #   data/system/theme/fonts  MIUI / HyperOS
  #   data/overlays/font       三星
  #   data/vfonts              vivo —— /system/fonts/VivoFont.ttf 就是指向这里的**符号链接**
  #   data/customizecenter/font  魅族 Flyme —— ★ 这一家是**不按名字匹配**的，见下面 datafont_any
  for d in data/system/theme/fonts data/overlays/font data/vfonts; do
    tdir="$FSROOT/$d"
    [ -d "$tdir" ] || continue
    for f in "$tdir"/*.ttf "$tdir"/*.TTF "$tdir"/*.otf "$tdir"/*.OTF "$tdir"/*.ttc "$tdir"/*.TTC; do
      [ -f "$f" ] || continue
      n=${f##*/}
      case "$n" in *'*') continue ;; esac        # glob 没匹配到会原样留着
      printf '%s\n' "$names" | grep -qxF "$n" || continue
      # 目录里常见"一堆符号链接指向同一个真实文件"（MIUI 实测：18 个文件全指向 Roboto-Regular.ttf）。
      # 这时只替换那个**真实文件** —— 既不去挂符号链接本身（挂上去不可靠，真机上校验都对不上），
      # 也不会把同一份文件挂十几遍（同名的整行会被 slot_plan 去重）。
      real=""
      if command -v readlink >/dev/null 2>&1; then
        real=$(readlink -f "$FSROOT$d/$n" 2>/dev/null)
        case "$real" in [A-Za-z]:/*) real=${real#?:} ;; esac   # 沙箱（Windows）会带盘符前缀
        case "$real" in "$FSROOT"/*) real=${real#"$FSROOT"} ;; esac
        # 注意：FSROOT 在真机上是空的，上面那步不会去掉开头的斜杠 —— 必须单独再剥一次，
        # 否则解析结果永远不等于 "$d/$n"，会把每个普通文件都误判成符号链接（测试抓到过）。
        case "$real" in /*) real=${real#/} ;; esac
        case "$real" in *..*) real="" ;; esac                  # 保守：带 .. 的直接不动
        [ "$real" = "$d/$n" ] && real=""                       # 解析结果就是它自己 = 不是符号链接
      fi
      case "$real" in
        "") printf 'theme %s/%s\n' "$d" "$n" ;;                # 普通文件：原样
        */fonts/*) printf 'theme %s\n' "$real" ;;              # 真身在某个字体目录里 → 挂真身
        *) : ;;                                               # 真身跑到别处 → 不动它，避免误伤
      esac
    done
  done
  # ---------------------------------------------------------------------------
  # 魅族 Flyme：/data/customizecenter/font/ —— **不按名字匹配**
  #
  # 为什么单独写一段：用户报告里这个文件叫 flymeFont.ttf（18 位十六进制前缀的
  # f1791638786.ttf 那种名字根本对不上），而且系统字体目录里**没有**任何同名槽位，
  # 上面那套"名字要相同"的规则在这里永远不会命中。
  # 真机依据（Redmi M098FE / Flyme 12.6 / Android 16，2026-10-12 报告）：
  #   · 用户在主题商店下了免费主题（设置里 using_font_name=静静字体）→ 这个文件就出现了；
  #   · 同一时刻 /system/fonts 里 FlymeSansVF.ttf、Roboto-Regular.ttf 等 7 个主字体
  #     全都变成**同样大小 17143856 字节 / 同样 mtime** —— 就是这份字体被主题机制铺进去的。
  #   所以这个文件**至少**是"用户选过的字体"的落点，替换它 = 让主题商店/个性字体链路也走用户的字体。
  # ⚠️ 老实说清楚：**它到底会不会盖过 /system/fonts，我们没在真机上验过**
  #   （那份报告里 dumpsys 显示框架读的是 /system/fonts/FlymeSansVF.ttf，配置里也没有指向这里的引用）。
  #   所以这条**只跟着用户手动打开的开关走**，默认关；关着的时候一个字都不碰。
  # ---------------------------------------------------------------------------
  if [ -d "$FSROOT/data/customizecenter/font" ]; then
    for f in "$FSROOT"/data/customizecenter/font/*.ttf  "$FSROOT"/data/customizecenter/font/*.TTF \
             "$FSROOT"/data/customizecenter/font/*.otf  "$FSROOT"/data/customizecenter/font/*.OTF; do
      [ -f "$f" ] || continue
      n=${f##*/}
      case "$n" in *'*') continue ;; esac          # glob 没匹配到会原样留着
      printf 'theme data/customizecenter/font/%s\n' "$n"
    done
  fi
}

slot_plan() {
  # 默认值 1.0.8 起改为"全替换"（作者定的规矩：默认可开就开、替换得最全；
  # 出问题（方块/某处没变）再用界面开关回退）。第三方调用方（fontctl/diag）会显式传值。
  local moddir="$1" scope="${2:-all}" keep_lang="${3:-0}" keep_special="${4:-0}"
  local role d name base
  #------------------------------------------------------------------------
  # 自动让路：用户**没有自己调过**这个开关时（settings.conf 里没这一行），
  #   字体缺哪一类字形，就把相关槽位自动留给系统字体 —— 这样"默认全替换"也不会造方块。
  # 用户一旦自己动过（哪怕只是切换一次开关写成 0），就**完全按他的来**，不再自动干预：
  #   这正是"出问题给个开关、遇到了就开/关"的语义。
  # 为什么用"配置里有没有这一行"来判：cfg_get 的默认值分不清"用户选的"和"默认给的"。
  #------------------------------------------------------------------------
  if [ -z "$(sed -n 's/^keep_lang=//p' "$SETTINGS" 2>/dev/null | tail -n1)" ]; then
    # 用户没自己调过 → 打开"按槽位自动让路"（具体判定在 _role_wanted 里，逐槽位做）
    SLOT_AUTO_RESERVE=1
  else
    # 用户自己调过 → 关掉自动让路，完全听他的（手动选"也换日韩"就该连缺字的也换）
    SLOT_AUTO_RESERVE=0
  fi
  base=$(slot_candidates "$moddir" | while read -r role d name; do
           _role_wanted "$role" "$scope" "$keep_lang" "$keep_special" "$name" || continue
           printf '%s %s/%s\n' "$role" "${d#/}" "$name"
         done | sort -u -k2,2)
  [ -n "$base" ] || return 0
  # 最后按**整行**（= 完整目标路径）再兜一次去重。
  # base 上面已经按"目录/文件名"去过重，而主题字体那批是**追加**的、不参与那一步，
  # 所以这里对整体再来一次，保证计划生成端不会出现同一个目标路径两遍
  # （否则「已替换槽位」会虚高，挂载日志里也会多出重复的"跳过"）。
  # 注意：不能用文件名去重 —— /product/fonts/X 与 /system/fonts/X 是两条合法槽位，
  # 按文件名去重会把它们误删（真机报告里 same=N 那批正是这种成对槽位）。
  { printf '%s\n' "$base"; theme_slots "$base"; } | awk '!seen[$0]++'
}

# 诊断：按角色统计设备上"候选且存在"的槽位数量
slot_report() {
  local moddir="$1" role d name
  local c_latin=0 c_cjk=0 c_main=0 c_lang=0 c_sym=0 c_italic=0 c_serif=0 c_mono=0 c_clock=0 c_display=0 c_ttc=0
  local tmp="${TMPDIR:-/data/local/tmp}/.slotrep.$$"
  mkdir -p "${tmp%/*}" 2>/dev/null
  slot_candidates "$moddir" > "$tmp"
  while read -r role d name; do
    case "$role" in
      latin) c_latin=$((c_latin+1)) ;; cjk) c_cjk=$((c_cjk+1)) ;; main) c_main=$((c_main+1)) ;;
      lang) c_lang=$((c_lang+1)) ;; sym) c_sym=$((c_sym+1)) ;; italic) c_italic=$((c_italic+1)) ;;
      serif) c_serif=$((c_serif+1)) ;; mono) c_mono=$((c_mono+1)) ;; clock) c_clock=$((c_clock+1)) ;;
      display) c_display=$((c_display+1)) ;; ttc) c_ttc=$((c_ttc+1)) ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  echo "latin=$c_latin cjk=$c_cjk main=$c_main ttc=$c_ttc | 保留：lang=$c_lang sym=$c_sym italic=$c_italic serif=$c_serif mono=$c_mono clock=$c_clock display=$c_display"
}
