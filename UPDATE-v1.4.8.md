
### 🐞 修「魅族 Flyme 上 App 闪退 / 酷安不能跳外链 / B站视频退回桌面」

**现象**（两位魅族用户报告）：

- 把「卸载模块」关掉（App 能看到模块挂载）时：WebUI 闪退、酷安点外链跳不动、B站视频卡一下退回桌面
- 把「卸载模块」单独给 WebUI 打开（App 看不到挂载）时：一切正常

**根因**：被替换的字体里包含 **Flyme 自己的 UI 字体**（SFPro / SFDIN / DINPro 这类）。
Flyme 的字体服务会校验这些文件，发现被换过就出异常，连带 App 一起崩。
识别厂商字体的名单里原本只覆盖 `MeizuSans` 一类，**漏了上面这几个**，所以它们照常被替换。

**已修**：补齐 Flyme 的厂商字体名单 —— 以下文件不再替换：

```
SFPro* / SFDIN* / SF-* / *DINPro* / *MyriadPro* / *SFRounded*
（连同原有的 MeizuSans / FlymeSans / mFlyme 等）
```

**另外，Flyme 上「本机扫描」也不再使用 `/product`、`/vendor`、`/my_product` 等厂商分区的结果**（只保留 `/system`）—— 也就是把替换范围**退回 1.4.3 那种水平**，厂商 UI 字体彻底不在替换列表里。
