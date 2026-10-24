# 自定义字体切换模块 v1.4.8.3

### 🐞 修「魅族上什么都替换不了」（槽位计划变成 0 个）

**真机现场**（MEIZU 20 Pro / Flyme / KernelSU）：

```
[3/4] 扫描与槽位
- 槽位计划：0 个，其中中文合集槽位 0 个
上次选择：builtin_flair → 没找到可替换的槽位（范围: all）
→ 已设为「无字体」
```

**原因**：上一版为了防魅族闪退，让 Flyme **完全不做本机扫描**，只用机型清单；
而机型清单里没有 MEIZU 20 Pro 的条目 → 一个槽位都没有 → 装上也白装。

**已修**：

- Flyme **恢复本机扫描**，但**只扫 `/system` 下的字体目录**
- `/product`、`/vendor`、`/my_product`、`/my_stock` 等厂商分区**一律不碰**
  （Flyme 的 UI 字体就在这些分区里，替换它们会引发闪退/跳转失败）
- 厂商字体名单（SFPro / SFDIN / DINPro / MyriadPro…）继续排除，作为第二层保险

升级后会重扫一次（扫描印记 14083）。这一版对非魅族设备无行为变化。

---

完整日志见 [CHANGELOG](https://github.com/ayss2188/custom-font-switcher/blob/main/CHANGELOG.md)。
