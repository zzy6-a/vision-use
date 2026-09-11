# DSH Computer Use · dsh-vision

[English](README_EN.md) | 中文

> 让 DeepSeek Harness 的 Agent **真正看见你的屏幕、并动手操作 Windows 桌面** —— 带 Codex 风格的蓝色操作覆盖层（按 **Esc** 随时中止）。

[![Download](https://img.shields.io/badge/Download-latest-2e7d32?style=flat&logo=github&logoColor=white)](https://github.com/zzy6-a/dsh-vision/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![dsh-plugin](https://img.shields.io/badge/topic-dsh--plugin-2f6fed)](https://github.com/topics/dsh-plugin)

---

## 它能做什么

| 能力 | 工具 | 说明 |
|---|---|---|
| 👁 **看** | `view_screen` | 截 Windows 全屏 → 直接进入模型视觉通道（不是 OCR，是真·看图）|
| 👁 **看** | `view_image` | 把任意图片文件送进视觉通道（Linux / Windows 路径都行）|
| 🖱 **动** | `computer_move` | 光标平滑滑行到 (x,y) |
| 🖱 **动** | `computer_click` | 左/右/双击，带点击涟漪 |
| ⌨️ **动** | `computer_type` | 输入文字（自动判别 Chromium 走剪贴板 / WinUI 走 SendInput）|
| ⌨️ **动** | `computer_key` | 组合键（`ctrl+t` / `enter` / `alt+f4` …）|
| 🎛 **控** | `computer_overlay` | 启停操作覆盖层（start/stop/status，可设空闲自动关）|
| 📊 **控** | `computer_status` | 覆盖层状态 / ESC 标志 / 当前模式 / 光标位置 |

### 视觉反馈（Codex 风格）

```
┌───────────────────────────────────────────────┐
│  ╔═════════════════════════════════════════╗  │ ← 蓝色柔光边框（逐像素 Alpha）
│  ║   ● DeepSeek Harness 正在操作  [Esc] 取消 ║  │ ← 顶部状态徽章
│  ║                                         ║  │
│  ║         打字 → 蓝色光环 + 竖线           ║  │
│  ║         点击 → 0.7s 涟漪（钉在点击处）    ║  │
│  ║         移动 → 光环淡入跟随；静置 1s 淡出 ║  │
│  ╚═════════════════════════════════════════╝  │
└───────────────────────────────────────────────┘
```

- **整套光标**（箭头 / I 形 / 手指）都是统一的蓝白渐变风格，且**保留 Windows 原生语境切换**
- **ESC 中止**：按下即写取消标志 → 覆盖层退出 → 后续所有动作被拒绝
- **空闲自动关**：默认 30 秒无工具调用自动收工（可配 `idle_seconds`，0 = 不自动关）
- **输入框下方的状态胶囊**：彩色圆点 + `CU 待命/移动/输入/点击` + 「停止」按钮

---

## 安装

### 方式一：GitHub Release（推荐）

```bash
dsh plugin --profile web add https://github.com/zzy6-a/dsh-vision/releases/download/v0.1.0/dsh-vision-0.1.0.tgz
```

### 方式二：git 源

```bash
dsh plugin --profile web add github:zzy6-a/dsh-vision
```

装完**重启 DSH**（`client.js` 半边需要启动时注册），浏览器刷新后输入框下方会出现状态胶囊。

---

## 快速开始

对 Agent 说：

> 看一下我的屏幕

> 帮我在必应搜索 DeepSeek 官网并打开

> 打开记事本打一段字

Agent 会自动：起覆盖层 → `view_screen` 看 → `computer_*` 动手 → 再看验证。你随时可以按 **Esc** 喊停。

---

## 系统要求

| 项 | 要求 |
|---|---|
| 宿主 | **Windows + WSL2**（Agent 跑在 WSL，操控 Windows 桌面）|
| 绝对路径互操作 | WSL interop 开启（`/proc/sys/fs/binfmt_misc/WSLInterop` = enabled）|
| Windows 侧 | PowerShell 5.1（系统自带）+ .NET Framework（System.Drawing/WinForms）|
| DSH | `>= 0.1.5-rc.1` |
| Node | 插件本身零运行时依赖（纯 ESM + 子进程调 PowerShell）|

---

## 架构

```
dsh-vision/
├── lib/index.js        host 半边：8 个工具 + 2 条 API 路由 + systemPrompt 能力宣告
├── lib/client.js       browser 半边：composer-dock 状态胶囊
├── cordis.patch.yml    bundle 层：把插件行插入 profile 树
├── dsh.plugin.json     插件清单（dsh-market / 插件管理 UI 用）
└── scripts/            Windows 侧工具链（自包含，随包发布）
    ├── cu.ps1          鼠标/键盘执行器 + ESC 守卫
    ├── overlay-v2.ps1  覆盖层：边框/徽章/光环/涟漪 + C# 60fps 动画引擎
    ├── wocr.ps1        Windows 原生 OCR（零 API 成本兜底，可选）
    └── TOOLKIT.md      工具链详细文档 + 10 条实战纪律
```

**视觉原理**：图片以 `content: [{type:'image', attachment}]` 形式返回，宿主 `collectImageRefs()` 递归收集后随下一次请求发给模型 —— 这是 DSH 官方的图片通道，因此**截图会正常计入模型视觉 token**（DeepSeek 官方路由对单图约 369 tokens，上限 384）。

**动画原理**：覆盖层用 `UpdateLayeredWindow` 逐像素 Alpha 实现真正的柔光；热路径全部在编译好的 C# 里跑（PowerShell 只敲节拍），单核占用约 8.8%。

---

## 配置

| 参数 | 默认 | 说明 |
|---|---|---|
| `computer_overlay start idle_seconds` | `30` | 空闲多少秒自动关闭覆盖层（0 = 永不）|
| `-MaxSeconds` | `0` | 覆盖层最长存活时间（0 = 不限）|
| `-NoCursorChange` | 关 | 不安装蓝色光标套装（保留系统默认光标）|

隐私相关：截屏会作为图片附件进入当前会话上下文（与手动粘贴图片等价）；如不想让截图进入模型，可用本仓库的 `scripts/wocr.ps1` 走**本地 OCR**（零 API 消耗，但只能拿文字）。

---

## 计费与隐私

- **插件本身零网络请求**：不调用任何 API，只把截图存进本地附件库并把图片块交给宿主
- 图片最终**发给当前会话选中的模型路由**（DSH 的模型适配器负责发请求）
- **完全跟随你选择的模型**：插件不选路由、不改路由，截图始终随会话发给**当前模型选择器里选中的模型**
  （选 opencode-go 就走 opencode-go，选官方就走官方）
- **识图能力检查**：若选中的模型未声明图片输入能力，`view_screen` / `view_image` 会明确报错并提示切换模型
- 走官方路由时单图视觉计费约 **369 tokens**（DSH 上限 384）；走自建/订阅路由则按该路由口径
- 不想让截图进入模型时，可用 `scripts/wocr.ps1`（Windows 本地 OCR，**零 API 成本**，但只能拿文字）

## 已知限制

- **Chromium 忽略 `KEYEVENTF_UNICODE` 注入**：往 Edge/Chrome 打字请用剪贴板模式（`computer_type` 的 `auto` 已自动处理）
- **WinUI（记事本等）不认注入的 Ctrl 组合键**：`computer_key` 对这类应用可能无效
- **自绘 UI 的 UIA 坐标不可信**（Edge 标签栏、Win11 记事本标签页会返回 ∞ 或错位）：请先 `view_screen` 肉眼定位再点
- **带自绘光标的软件**（游戏、部分 Electron 应用）无法被系统级光标替换覆盖

---

## 相关项目

- [dsh-upgrade-guard](https://github.com/zzy6-a/dsh-upgrade-guard) —— DSH 升级兼容性守卫（同作者的配套插件）

## Contributors / 致谢

- [zzy6-a](https://github.com/zzy6-a) — 作者
- DeepSeek V4.1 — 架构设计、实现、测试与发布流程

## 许可证

MIT © 2026 zzy6-a
