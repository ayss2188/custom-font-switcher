# 自定义字体切换模块 v1.4.7.4

**性能与手感优化**

- 首屏：两次同步 exec → 一次（新增 `fontctl.sh quick`），槽位来源统计改后台补
- 字体读取分块（256KB/次），修掉大字体把管理器 WebView 撑爆的隐患
- 渲染改离屏构建（DocumentFragment），只重排一次
- 动效统一：卡片错峰入场、按压回弹、面板可打断过渡、骨架屏、尊重减少动态

**删除「同族字重自动配对」开关**：族名相同不代表同一套字体，混挂可能缺字/开不了机。
这件事交给更安全的「字重组」（手动勾选 + 五道校验）。

详细内容见 [CHANGELOG](https://github.com/ayss2188/custom-font-switcher/blob/main/CHANGELOG.md)。
