#!/system/bin/sh
# mount.sh - 模块自带挂载（不依赖元模块，覆盖 my_product / mi_ext 等厂商分区）
#
# 原理：开机时把字体库里的字体文件直接 bind mount 到每个真实字体槽上，
#       不在模块目录生成任何副本（一份字体，零额外占用，也不受模块目录是镜像分区的影响）；
#       模块带 skip_mount，管理器不会重复挂载。
#   Magisk          -> post-fs-data 阶段挂载（Magisk 没有 post-mount 阶段）
#   KernelSU/APatch -> post-mount 阶段挂载（在元模块等挂载之后，避免被目录级挂载盖住）
#
# slots.map 每行 "<字体id> <目标路径>"，目标路径相对 /，如 f1700000000 system/fonts/Roboto-Regular.ttf
#
# 用法（source 后调用；需先 source common.sh）：
#   payload_mount <模块目录> <阶段名>   挂载，结果写入 mount.state
#   payload_verify <模块目录>          检查当前可见的系统字体是否就是本模块的文件，输出 "生效数 总数"

payload_mount() {
  local moddir="$1" id rel src dst err ok=0 fail=0 skip=0
  local map="$moddir/slots.map"
  [ -s "$map" ] || return 0
  while read -r id rel || [ -n "$rel" ]; do
    rel=$(printf '%s' "$rel" | tr -d '\r')
    case "$id" in ""|*[!A-Za-z0-9_]*) continue ;; esac
    case "$rel" in ""|/*|*..*) continue ;; esac
    src="$LIB/$id.ttf"; dst="/$rel"
    if [ ! -f "$src" ] || [ ! -f "$dst" ]; then
      skip=$((skip+1)); continue
    fi
    if err=$(mount -o bind "$src" "$dst" 2>&1); then
      mount -o remount,bind,ro "$dst" 2>/dev/null
      ok=$((ok+1))
    else
      fail=$((fail+1))
      echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 绑定失败 $src -> $dst : ${err:-未知错误}" >> "$LIB/mount.log" 2>/dev/null
    fi
  done < "$map"
  echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 阶段=${2:-unknown} 成功=$ok 失败=$fail 跳过=$skip" >> "$LIB/mount.log" 2>/dev/null
  if [ -f "$LIB/mount.log" ]; then
    tail -n 100 "$LIB/mount.log" > "$LIB/mount.log.tmp.$$" 2>/dev/null && mv -f "$LIB/mount.log.tmp.$$" "$LIB/mount.log" 2>/dev/null
  fi
  if command -v beat >/dev/null 2>&1; then
    beat mount "phase=${2:-unknown} ok=$ok fail=$fail skip=$skip"
  fi
  {
    echo "boot=$(boot_id)"
    echo "ok=$ok"
    echo "fail=$fail"
    echo "skip=$skip"
    echo "stage=${2:-unknown}"
    echo "time=$(date +%s)"
  } > "$moddir/mount.state"
}

payload_verify() {
  local moddir="$1" id rel a b n=0 hit=0 mode
  mode=$(tr -d '[:space:]' 2>/dev/null < "$moddir/payload.mode")
  [ -s "$moddir/slots.map" ] || { echo "0 0"; return 0; }
  while read -r id rel || [ -n "$rel" ]; do
    rel=$(printf '%s' "$rel" | tr -d '\r')
    case "$rel" in ""|/*|*..*) continue ;; esac
    n=$((n+1))
    if [ "$mode" = manager ]; then
      # 管理器挂载会经过 overlay/tmpfs，inode 不同，只能比较大小
      a=$(stat -L -c '%s' "$moddir/$(mgr_path "$rel")" 2>/dev/null)
      b=$(stat -L -c '%s' "/$rel" 2>/dev/null)
    else
      # bind mount 后两边的 设备号:inode 完全一致
      a=$(stat -L -c '%d:%i' "$LIB/$id.ttf" 2>/dev/null)
      b=$(stat -L -c '%d:%i' "/$rel" 2>/dev/null)
    fi
    [ -n "$a" ] && [ "$a" = "$b" ] && hit=$((hit+1))
  done < "$moddir/slots.map"
  echo "$hit $n"
}
