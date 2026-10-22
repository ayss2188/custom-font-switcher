# 自定义字体切换模块 v1.4.7.2

**热修：字重组报「档案里没有族名原文」**（重新导入也没用）。

原因是批量写档案时多个字段被空格拼接、后端又按空格切分，导致 `family=Source Han Sans TC` 这类带空格的族名写不进去。

已改为「一个字段一行」并且后端按行解析；同时缺 `family/upem/subfamily` 的老字体也会自动补写 —— **不用重新导入**，升级后打开一次界面即可。

详细内容见 [CHANGELOG](https://github.com/ayss2188/custom-font-switcher/blob/main/CHANGELOG.md)。
