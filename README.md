# QuickLauncher — 极致轻量快速启动器

纯 PowerShell 5.1 + WinForms 实现，**零依赖、零安装、零常驻**。Windows 自带运行环境，单脚本 + 单 JSON 数据文件，用完即退，不占任何后台资源。

## 文件

| 文件 | 作用 |
|---|---|
| `QuickLauncher.ps1` | 主程序（GUI + 管理命令一体） |
| `launcher.json` | 数据文件（UTF-8，自动创建，可用记事本直接编辑） |

## 快速开始

### 1. 绑定全局快捷键（推荐）

在 PowerShell 里运行一次：

```powershell
& "D:\cache\codex plus\buug\QuickLauncher\QuickLauncher.ps1" install
```

会在桌面创建 `QuickLauncher.lnk`，绑定 **Ctrl+Alt+Space**。之后任何地方按快捷键即可唤出启动器（快捷方式首次生效可能需要先点一下桌面/资源管理器）。快捷键可在设置页修改。

### 2. 添加条目

```powershell
# 本地软件
& "...\QuickLauncher.ps1" app 微信 "C:\Program Files\Tencent\WeChat\WeChat.exe" -Keywords "wx,chat"

# 网页（自动补 https://，用默认浏览器打开）
& "...\QuickLauncher.ps1" web B站 "bilibili.com" -Keywords "bili,zhan"
```

或者从桌面直接拖拽 `.lnk`/`.url` 文件到「条目管理」列表，批量导入。

### 3. 使用

按 **Ctrl+Alt+Space** 唤出 → 输入关键词 → **Enter 打开**，**Esc** / 点标题栏关闭。

搜索框下方可切换「显示列表」和「大图标」模式；大图标模式以 72×72 图标展示常用条目。

## 管理命令（增删改查）

**推荐：图形管理页** —— 启动器右下角 **管理 ⚙** 按钮、启动器内 **Ctrl+M**，或运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "...\QuickLauncher.ps1" manage
```

管理页功能（全中文界面）：

- 表格列出全部条目：图标 / 类型 / 名称 / 关键词 / 目标 / 次数
- **添加软件**（带文件浏览选择器）/ **添加网页**（URL 自动补 https://）
- **编辑**（双击行也行）、**删除**（右键菜单或 Del 键）
- **从桌面导入**：扫描桌面（含公共桌面）全部 `.lnk`，勾选后批量导入。导入的是快捷方式本身，启动参数、工作目录、图标全部保留；与现有条目重名或目标缺失的自动标灰跳过
- **拖拽导入**：直接从桌面拖拽 `.lnk`/`.url` 文件到管理页列表，弹出批量选择对话框，逐条选择「软件」「网页」或跳过

每次改动即时写入 `launcher.json`。

命令行方式（适合脚本批量）：

```
QuickLauncher.ps1                          唤出 GUI
QuickLauncher.ps1 app <名称> <程序路径> [-Keywords "k1,k2"]
QuickLauncher.ps1 web <名称> <网址>     [-Keywords "k1,k2"]
QuickLauncher.ps1 list                     列出全部条目
QuickLauncher.ps1 del <名称>               删除条目
QuickLauncher.ps1 edit                     记事本打开 launcher.json（改）
QuickLauncher.ps1 manage                   打开图形管理页
QuickLauncher.ps1 install                  创建桌面快捷方式 + Ctrl+Alt+Space
QuickLauncher.ps1 help                     帮助
```

同名重复添加 = 覆盖更新。直接编辑 JSON 也完全合法（保存为 UTF-8）。

## 界面与主题（Fluent Design）

整体视觉按 Windows 11 Fluent Design 设计：圆角窗口与圆角控件、窗口投影、统一配色与留白。

管理页 → **⚙ 设置** 打开设置窗口：

- **主题模式**：跟随系统 / 白天模式 / 夜间模式（三选一）。切换**立即生效**（当前打开的所有窗口即时换肤），并写入 `launcher.json`，下次启动自动恢复。「跟随系统」读注册表 `AppsUseLightTheme` 判定。
- **窗口效果**：透明 / 毛玻璃（亚克力）。开启毛玻璃会自动带上透明效果（前置依赖）。
- **快捷键设置**：自定义「召唤搜索框」「管理页」「设置」「切换主题」「切换列表」「导入」六个快捷键（空表示禁用）。召唤搜索框修改后点「更新」重建桌面快捷方式热键。
- **导入 / 导出配置**：将 `launcher.json` 中的设置与全部条目导出为 JSON，或从 JSON 导入覆盖。

列表样式：搜索框下方可切换「普通表格」与「大图标」两种展示模式；大图标模式使用 72×72 图标、140×120 单元格，并按使用次数排序。

所有效果对**全部窗口**（启动器 / 管理页 / 设置 / 弹窗）统一即时生效并自动保存。标题栏（DWM 深色标题栏）与 ListView 表头（自绘）均随主题变色，暗色模式下不再有白色条；白天模式字体纯黑，毛玻璃效果下文字清晰可读。

技术实现零依赖：圆角窗口走 DWM `DwmSetWindowAttribute`，亚克力走 `SetWindowCompositionAttribute`，阴影用 `CS_DROPSHADOW`——全部通过一个内存编译的 C# 辅助类完成，无任何外部库，用完即退。

**主题模块化**：所有颜色定义在脚本的 `THEME MODULE` 区域（`$Script:ThemePresets`），新增一套主题只需往字典里加一组色值；控件按类型自动换色（`Walk-ThemeControls`），无需逐个改控件。

## 匹配逻辑（输入即时过滤，按得分排序）

| 优先级 | 匹配方式 | 示例 |
|---|---|---|
| 100 | 名称前缀 | `git` → GitHub |
| 80 | 名称包含 | `it` → GitHub |
| 60 | 关键词前缀 | `wx` → 微信（keywords 含 wx） |
| 50 | 关键词包含 | — |
| 40 | **拼音首字母前缀** | `wx` → 微信（无关键词也能命中） |
| 20 | 拼音首字母包含 | — |
| 1 | 空输入 | 显示全部（按使用频率排序） |

- 拼音首字母由 GB2312 区位码纯 .NET 计算，零字典零依赖（多音字取常见读音）。
- **同分按使用次数（hits）排序**：越常用的越靠前，自动学习你的习惯。
- 每次成功打开自动 +1 hits 并写回 JSON。

## 预期效果

1. 任意界面按 Ctrl+Alt+Space，屏幕中央弹出置顶小窗（约 0.3~0.5 秒）。
2. 输入框打字，下方列表**实时**过滤；每行带图标（软件显示真实程序图标，网页显示首字母彩色图标）。
3. Enter 直接打开第一项；↑↓ 换选；双击列表项也可打开。
4. 右下角 **管理 ⚙** 按钮或 Ctrl+M 进入条目管理页。
5. 窗口支持自由拖动与缩放；按 Esc 或关闭按钮 → 窗口立即关闭，进程退出，内存清零。

## 已知边界

- 拼音取 GB2312 常见读音，多音字（如"重庆"）可能取 `chong`/`qing` 中一种，用关键词兜底。
- Windows 执行策略默认 Restricted 时需带 `-ExecutionPolicy Bypass`（`install` 创建的快捷方式已自动带上）。
