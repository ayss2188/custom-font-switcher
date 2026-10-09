# GitHub 使用教程（零基础版）

这篇教程教你把模块放到 GitHub 上，并让手机能「在线检查更新、一键安装新版」。
全程不需要会写代码，也不需要会命令行，按顺序做即可。

---

## 先搞懂几个词

| 名词 | 是什么 | 在本模块里的作用 |
|---|---|---|
| 仓库（Repository） | 你在 GitHub 上的一个项目文件夹 | 存放模块源码、说明文档 |
| Release（发行版） | 仓库里的「下载页」 | 放每个版本的刷机包 zip，给机友下载 |
| Actions | GitHub 提供的免费自动化机器人 | 自动打包 zip、发布 Release、更新版本信息 |
| update.json | 一个记录「最新版本号和下载地址」的小文件 | 手机上的模块靠它判断有没有新版本 |

你只需要做两件事：**改文件**、**点按钮**。打包、发布、通知手机全部由 Actions 自动完成。

---

## 第一步：注册 GitHub 账号

1. 打开 <https://github.com>，点右上角 **Sign up**；
2. 按提示填邮箱、密码、用户名（**用户名会出现在下载地址里，建议用英文，以后别改**）；
3. 去邮箱点验证链接。

> 国内打开 GitHub 慢或打不开是常见现象，可以多刷新几次，或换个时间段/网络。

---

## 第二步：设置仓库地址（只做一次）

模块需要知道「去哪个仓库检查更新」。文件里现在是 `__REPO__` 占位符，要换成你自己的。

1. 想好仓库名，推荐就用 **`custom-font-switcher`**；
2. 在电脑上打开 `custom-font-switcher` 文件夹，**双击「设置仓库地址.bat」**；
3. 输入 `你的用户名/custom-font-switcher`，例如 `zhangsan/custom-font-switcher`，回车；
4. 看到「完成！」即可，按任意键关闭窗口。

它会自动修改 `module/module.prop`、`update.json`、`README.md`、`docs/酷安帖子.md` 里的地址。

> 如果双击后窗口一闪而过，右键「设置仓库地址.bat」→「以管理员身份运行」再试一次。

---

## 第三步：把文件传到 GitHub

两种方法任选一种。**推荐方法 A**，最省事、不会漏文件。

### 方法 A：用 GitHub Desktop（推荐）

1. 下载安装 GitHub Desktop：<https://desktop.github.com>（有中文社区汉化，但英文界面按下面步骤点也很简单）；
2. 打开后点 **Sign in to GitHub.com**，在弹出的网页里登录并授权；
3. 菜单 **File → Add local repository…**，点 **Choose…** 选中 `custom-font-switcher` 文件夹；
4. 会提示「This directory does not appear to be a Git repository」，点里面蓝色的 **create a repository**；
5. 弹出的窗口里：
   - **Name** 填 `custom-font-switcher`（必须和第二步填的仓库名一致）；
   - 其他保持默认，点 **Create repository**；
6. 点顶部的 **Publish repository**：
   - **取消勾选「Keep this code private」**（仓库必须是公开的，手机才能检查更新）；
   - 点 **Publish repository**。

等进度条走完，打开 `https://github.com/你的用户名/custom-font-switcher` 就能看到所有文件了。

### 方法 B：网页上传

1. 登录 GitHub，点右上角 **＋ → New repository**；
2. **Repository name** 填 `custom-font-switcher`，选 **Public**（公开），**其他都不要勾**，点 **Create repository**；
3. 在新页面点 **uploading an existing file** 链接；
4. 打开电脑上的 `custom-font-switcher` 文件夹，**全选里面的所有文件和文件夹**，拖进网页；
5. 等上传完成，拉到底部点 **Commit changes**。

⚠️ 网页上传经常会**漏掉以点开头的文件夹** `.github`，必须检查一下：

6. 在仓库首页看有没有 `.github` 文件夹。**没有的话**：
   - 点 **Add file → Create new file**；
   - 文件名一栏输入 `.github/workflows/release.yml`（输入 `/` 时会自动变成文件夹）；
   - 用记事本打开电脑上的 `.github\workflows\release.yml`，全选复制，粘贴进网页编辑框；
   - 点 **Commit changes…** → **Commit changes**。

---

## 第四步：打开 Actions 写权限（只做一次）

Actions 机器人需要权限才能发布 Release、更新 update.json。

1. 打开你的仓库页面，点上方 **Settings**（设置）；
2. 左侧菜单 **Actions → General**；
3. 拉到最下面 **Workflow permissions**，选 **Read and write permissions**；
4. 点 **Save**。

---

## 第五步：发布第一个版本

1. 仓库页面点上方 **Actions**；
2. 如果出现绿色按钮「I understand my workflows, go ahead and enable them」，点它启用；
3. 左侧点 **Release**；
4. 右边点 **Run workflow** → 再点绿色的 **Run workflow**；
5. 等 1～2 分钟，刷新页面，出现 **绿色 ✓** 就是成功了。

成功后：

- 仓库首页右侧 **Releases** 下会出现 `自定义字体切换模块 v1.0`，里面有 `custom-font-switcher.zip`，这就是给机友下载的刷机包；
- `update.json` 会被自动更新（可以点开看，`sha256` 那一栏有了内容）。

**下载地址**（发到酷安的就是这个）：

```text
https://github.com/你的用户名/custom-font-switcher/releases/latest
```

> 出现 **红色 ✗** 也别慌，点进去看哪一步报错，对照文末「常见问题」处理。

---

## 第六步：以后发新版本

每次改完模块要发新版，只需要改两个文件、点一次按钮。

### 1. 改版本号：`module/module.prop`

```text
version=v1.1
versionCode=110
```

- `version`：显示给用户看的版本号，例如 `v1.1`、`v1.2`；
- `versionCode`：**纯数字，每次都必须比上一版大**（手机靠它判断有没有新版），例如 v1.0=100、v1.1=110、v1.2=120。

### 2. 写更新日志：`CHANGELOG.md`

在**最上面**（`# 更新日志` 下一行）加一段，标题必须和 version 完全一样：

```markdown
## v1.1

- 修复了 xxx
- 新增了 xxx
```

Release 页面和手机 WebUI 里的「更新日志」显示的就是这里的内容。

### 3. 把修改传上去

- **用 GitHub Desktop**：在电脑上改好文件 → 打开 GitHub Desktop → 左下角 Summary 随便写一句（如「v1.1」）→ 点 **Commit to main** → 点顶部 **Push origin**；
- **用网页**：在仓库里点开文件 → 右上角铅笔图标 ✏️ 编辑 → 改完点 **Commit changes**。

> 改了模块里的脚本（比如 `fontctl.sh`）也是一样的方法上传。

### 4. 发布

**Actions → Release → Run workflow**，等绿色 ✓。

完成！几分钟后（GitHub 有缓存，最多可能要十几分钟）：

- 机友在 WebUI 里点「检查更新」就能看到新版本，点「下载并安装」即可；
- Magisk / KernelSU / APatch 的模块列表也会显示「有更新」。

---

## 机友这边是怎么更新的？

```text
你点 Run workflow
   ↓
Actions 自动打包 zip → 发布到 Releases → 更新 update.json
   ↓
手机 WebUI「检查更新」读取 update.json → 发现版本号变大
   ↓
下载 zip → 校验 sha256 和模块 ID → 用 Root 管理器安装 → 重启生效
```

字体库、设置和当前选择的字体都会保留，机友不需要重新导入。

---

## 常见问题

**Q：Actions 红色 ✗，提示「module.prop 里还是 __REPO__ 占位符」**
A：第二步没做或没生效。在网页上打开 `module/module.prop`，点铅笔编辑，把 `__REPO__` 改成 `你的用户名/custom-font-switcher`，保存后重新 Run workflow。`update.json`、`README.md` 里的同理（update.json 发布成功后会被自动覆盖，不改也行）。

**Q：提示「Release v1.0 已经存在」**
A：同一个版本号只能发布一次。改大 `module.prop` 里的 `version` 和 `versionCode` 再发；如果确实想重新发同一版，先到 Releases 页面删掉那个版本（右上角 ··· → Delete），再到仓库 **Tags** 页删掉同名标签。

**Q：提示 `Permission denied` / `403` / 推送 update.json 失败**
A：第四步的写权限没打开。

**Q：机友手机上「检查失败：无法连接 GitHub」**
A：国内网络常见。让机友在 WebUI「下载镜像」里填一个 GitHub 加速镜像前缀（如 `https://ghfast.top`）。镜像是第三方服务，可能失效，失效换一个即可；下载后模块仍会校验 sha256，镜像无法篡改刷机包。

**Q：发布了新版，手机上还显示已是最新**
A：GitHub 的文件有几分钟缓存，等一会儿再检查；WebUI 每天自动检查一次，手动点「检查更新」会立即检查。另外确认 `versionCode` 确实比旧版大。

**Q：仓库能设成私有吗？**
A：不能。私有仓库别人无法下载，手机也无法检查更新。

**Q：能把字体文件也传到仓库吗？**
A：不建议。大部分商业字体不允许二次分发，而且仓库已经设置了忽略 `.ttf/.otf/.ttc` 文件。模块本身也不需要内置字体。

**Q：我想在电脑上自己打包 zip 试刷**
A：双击「本地打包.bat」，生成的刷机包在 `dist\custom-font-switcher.zip`。

**Q：怎么改仓库首页的介绍？**
A：首页显示的是 `README.md`，像改其他文件一样编辑它即可。

---

## 文件说明

```text
custom-font-switcher/
├── module/                    刷机包内容（打包时整个目录打进 zip）
│   ├── module.prop            模块名称、版本号、更新地址
│   ├── customize.sh           安装脚本
│   ├── fontctl.sh             字体管理核心（WebUI 调用）
│   ├── slots.sh               字体槽位发现
│   ├── mount.sh               自带挂载
│   ├── update.sh              在线更新
│   ├── google_font.sh         谷歌字体兼容
│   ├── webroot/index.html     WebUI 界面
│   ├── targets/*.list         各系统已知字体槽清单
│   └── tools/optimize_font.py 电脑端字体精简工具
├── update.json                最新版本信息（自动维护，一般不用手动改）
├── CHANGELOG.md               更新日志（每次发版都要写）
├── README.md                  仓库首页介绍
├── docs/
│   ├── GitHub使用教程.md       本教程
│   └── 酷安帖子.md             酷安发帖文案
├── 设置仓库地址.bat             首次设置仓库地址
├── 本地打包.bat                 在电脑上打包 zip
├── scripts/                   上面两个 bat 实际调用的脚本
└── .github/workflows/         Actions 自动发布配置
```
