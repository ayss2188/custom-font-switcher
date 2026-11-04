
### 一、修「WebView / 米家这类界面字体没换」

```
· HyperOS 上 /system/fonts/MiSansVF_Overlay.ttf 是指向
  /data/system/fonts/theme_webview/Roboto-Regular.ttf 的符号链接
· 以前所有 /data 槽位一律跳过（不写用户盘），这个目标文件就从来没被换过
  → WebView 渲染的页面（米家控制页这类 H5）读到的还是原来的字体
· 现在对 /data/system/fonts/theme_webview 和 /data/system/theme/fonts 两类目录
  做 bind 挂载（只挂载、不写盘，不动其它 /data 槽位）
```

### 二、自检不再把「策略性跳过」算成「看不到」

```
· PID 1 视角校验里，按策略跳过的 /data 槽位单独排除，不再误报
```

---

