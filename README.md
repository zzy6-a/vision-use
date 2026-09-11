# Vision Use · DSH Computer Use

[English](README_EN.md) | 中文

> 仓库：`vision-use` · 包名：`dsh-vision`
>
> 让 DeepSeek Harness 的 Agent **真正看见你的屏幕、并动手操作 Windows 桌面** —— 带 Codex 风格的蓝色操作覆盖层（按 **Esc** 随时中止）。

[![Download](https://img.shields.io/badge/Download-latest-2e7d32?style=flat&logo=github&logoColor=white)](https://github.com/zzy6-a/vision-use/releases/latest)
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
| ⌨️ **动** | `computer_type` | 输入文字（默认 **VK 真实按键逐键注入**，零剪贴板；中文走输入法：`computer_key` 发拼音 → `space`/数字上屏）|
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
- **强制覆盖层**：所有 hands 操作（move/click/type/key）都会先强制拉起覆盖层，不存在“静默操作”
- **ESC 中止**：按下即写取消标志 → 覆盖层退出 → 后续所有动作被拒绝
- **任务级保活**：只要本回合 agent 还在工作（思考 / 执行其他工具），覆盖层就不会收；回合结束后约 4 秒收起。覆盖层自身仍有空闲兜底（`idle_seconds`，默认 30，0 = 关闭兜底）
- **输入框下方的状态胶囊**：彩色圆点 + `CU 待命/移动/输入/点击` + 「停止」按钮

---

## 安装

### 方式一：GitHub Release（推荐）

```bash
dsh plugin --profile web add https://github.com/zzy6-a/vision-use/releases/download/v0.2.0/dsh-vision-0.2.0.tgz
```

### 方式二：git 源

```bash
dsh plugin --profile web add github:zzy6-a/vision-use
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
| 宿主（自动识别） | **Windows 原生** 或 **Windows + WSL2**；插件自动识别 DSH 所在环境并选择对应路径/子进程方案 |
| WSL 时的互操作 | WSL interop 开启（`/proc/sys/fs/binfmt_misc/WSLInterop` = enabled）；插件自动走 `\\wsl.localhost\<distro>` UNC 路径 |
| Windows 侧 | PowerShell 5.1（系统自带）+ .NET Framework（System.Drawing/WinForms）|
| DSH | `>= 0.1.5-rc.1` |
| Node | 插件本身零运行时依赖（纯 ESM + 子进程调 PowerShell）|
| Linux / macOS | 不支持桌面控制；`view_screen` 与 hands 工具会明确报错，`view_image` 仍可用 |

---

## 架构

```
vision-use/
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

### 环境自动识别

插件启动时检测 `process.platform`、`WSL_DISTRO_NAME` / `WSL_INTEROP` 与 `/proc/version`：

| 检测结果 | 行为 |
|---|---|
| Windows 原生 | 直接调 `powershell.exe`；flag/state/heartbeat 写 `%TEMP%` |
| WSL + Windows | 调 `powershell.exe` interop；flag/state/heartbeat 写 `/tmp`，并自动转成 `\\wsl.localhost\<distro>\tmp` 供 PowerShell 读写 |
| Linux / macOS | 桌面工具给出明确不支持错误；`view_image` 不受影响 |

子进程统一通过 `DSH_VISION_FLAG_DIR` 环境变量获知跨端 flag 目录（WSL 下会自动加入 `WSLENV` 透传）。

**视觉原理**：图片以 `content: [{type:'image', attachment}]` 形式返回，宿主 `collectImageRefs()` 递归收集后随下一次请求发给模型 —— 这是 DSH 官方的图片通道，因此**截图会正常计入模型视觉 token**（DeepSeek 官方路由对单图约 369 tokens，上限 384）。

**动画原理**：覆盖层用 `UpdateLayeredWindow` 逐像素 Alpha 实现真正的柔光；热路径全部在编译好的 C# 里跑（PowerShell 只敲节拍），单核占用约 8.8%。

---

## 配置

| 参数 | 默认 | 说明 |
|---|---|---|
| `computer_overlay start idle_seconds` | `30` | 覆盖层自身的空闲兜底秒数；任务进行中插件会持续续心跳，不会在思考时消失（0 = 关闭兜底）|
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

- **Chromium 忽略 `KEYEVENTF_UNICODE` 注入**：往 Edge/Chrome/微信打字用 `typevk`（真实 VK 按键，跨应用通用）
- **中文/非 ASCII 走输入法**：`computer_key` 依次发拼音字母（如 `n,i,h,a,o`）→ `computer_key` `space`（或数字键选候选）上屏；`computer_type` 的默认路径会**明确拒绝**非 ASCII 而不是偷偷回退剪贴板
- **剪贴板模式默认关闭**：仅在显式 `method: 'clipboard'` 时启用（注意：它会覆盖用户剪贴板内容）
- **WinUI（记事本等）不认注入的 Ctrl 组合键**：`computer_key` 对这类应用可能无效
- **自绘 UI 的 UIA 坐标不可信**（Edge 标签栏、Win11 记事本标签页会返回 ∞ 或错位）：请先 `view_screen` 肉眼定位再点
- **带自绘光标的软件**（游戏、部分 Electron 应用）无法被系统级光标替换覆盖
- **Linux / macOS 宿主**：当前只支持 Windows 原生与 WSL + Windows；其他系统下 `view_image` 可用，桌面工具会明确报错

---

## 相关项目

- [dsh-upgrade-guard](https://github.com/zzy6-a/dsh-upgrade-guard) —— DSH 升级兼容性守卫（同作者的配套插件）

## Contributors / 致谢

- [zzy6-a](https://github.com/zzy6-a) — 作者
- DeepSeek V4.1 — 架构设计、实现、测试与发布流程

## 许可证

MIT © 2026 zzy6-a
