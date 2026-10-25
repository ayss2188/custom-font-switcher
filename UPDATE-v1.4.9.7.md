
### 修复：重启后一直提示「已安装完成，重启后生效」

**实测证据**：

```
cat /data/adb/custom_font_lib/.update/state
stage=finished
cur=0
total=0
msg=安装完成，重启后生效
```

这份状态文件在重启后仍然留着，界面每次都读到它 → 红灯一直在。
上一版的开机清理没有执行（脚本里 LIB 变量在那一段还是空值）。

**已修**：

1. 界面读到 `stage=finished` 且当前并没有在安装 → 直接删掉 `.update`、按空闲处理
2. 开机脚本里的清理补上 `LIB` 兜底（`LIB="${LIB:-/data/adb/custom_font_lib}"`），确保能执行
