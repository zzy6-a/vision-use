# DSH Computer-Use 工具链

Agent 操作 Windows 桌面（WSL host）的能力集合。**任何对话都能用**——工具在磁盘上，脚本入口固定。

## 一、看（视觉通道）

优先用 **dsh-vision 插件**提供的工具（插件级，任何对话自动可用）：
- `view_screen(max_width?)` —— 截 Windows 桌面全屏并直接送进模型视觉通道（默认缩到 1600px）
- `view_image(file_path)` —— 读任意图片文件进视觉通道（支持 Linux 路径和 `C:/...`）

原理：工具返回 `{type:'image', attachment}` 内容块 → 宿主 `collectImageRefs()` 递归收集 → 下一轮请求带图给模型。
若插件不可用，退化用 OCR：`wocr.ps1`（Windows 原生 OCR，中文引擎 zh-Hans-CN，带 `-Boxes` 可返回文字坐标）。

## 二、动（鼠标/键盘）

`cu.ps1`（经 `powershell.exe -File \\wsl.localhost\Ubuntu\home\zzy6\dsh-computer-use\cu.ps1 ...` 调用）

| Action | 说明 |
|---|---|
| `pos` / `fg` | 当前光标位置 / 前台窗口 |
| `move -X -Y [-Steps 25 -DelayMs 12]` | 平滑移动（Steps 越大越"人性"） |
| `click / dblclick / rclick [-X -Y ...]` | 鼠标点击（带坐标则先平滑移动） |
| `type -Text "..."` | 剪贴板粘贴式输入（Chromium 可用） |
| `typehuman -Text "..." [-DelayMs 90 -JitterMs 30]` | **SendInput Unicode 逐字输入**（WinUI 应用可用；**Chromium 会忽略**） |
| `keys -Keys "ctrl+t,enter,esc"` | VK 组合键（Edge 接受 Ctrl 组合；WinUI 应用如记事本不接受） |
| `wheel -Wheel 120` | 滚轮 |
| `shot -Out path` | 截图（带光标绘制） |
| `clear-cancel` | 清除 ESC 取消标志 |

## 三、特效与 ESC 中止

`agentoverlay.ps1 -Action start|stop|status [-MaxSeconds N] [-NoCursorChange]`
- 蓝色柔光边框（逐像素 Alpha）+ 顶部玻璃徽章 + 蓝色定制光标 + 跟随光环
- 每 50ms 轮询 `GetAsyncKeyState(VK_ESCAPE)`；按下 → 写取消标志 → 徽章变琥珀色「已取消」→ 2.2s 后退出并恢复系统光标
- 取消标志：`%TEMP%\dsh_agent_cancel.flag` ↔ `/tmp/dsh_agent_cancel.flag`（双写）
- `cu.ps1` 每个动作执行前检查该标志，被取消即拒动（exit 9）

**契约**：开工起覆盖层 → 用户按 ESC → 下一步动作拒绝 → Agent 停下询问；收工 `-Action stop`。

## 四、作业纪律（血泪教训）

1. **先看后点**：点击前必须 `view_screen` 肉眼定位；截图坐标 ×(2560/截图宽) = 真实坐标
2. **点完立刻再看**：验证是否按预期发生
3. **绝不复用缓存坐标**：标签栏/按钮会随内容移动
4. **自绘 UI 的 UIA 矩形不可信**：Edge 标签栏、Win11 记事本标签页会返回错误坐标或 ∞ —— 一律肉眼确认
5. **输入方式按目标选**：
   - Chromium（Edge/Chrome）：`type`（剪贴板）或 UIA `ValuePattern.SetValue`（推荐，零剪贴板）；`typehuman` 无效
   - WinUI（记事本）：`typehuman`（SendInput Unicode）有效；Ctrl 组合键无效
   - 通用兜底：UIA `ValuePattern.SetValue` / `InvokePattern`（不需要焦点、不依赖坐标）
6. **前台锁定**：`SetForegroundWindow` 常失败 → 先模拟一次 ALT 键再调用（经典技巧）
7. **模态对话框会阻塞一切**：检测到操作"无效"时，先 `view_screen` 看有没有对话框在等你
8. **PowerShell 5.1 坑**：脚本文件要 UTF-8 BOM（否则中文按 ANSI 读）；输出中文先设 `[Console]::OutputEncoding`
9. **`Add-Type -MemberDefinition`**：只能放成员片段，不能放整个 class；引用 `System.Drawing` 需换传 HBITMAP 句柄
10. **`SendInput` 的 INPUT 结构体**：x64 上 union 按 `MOUSEINPUT` 对齐 = **40 字节**（只算 KEYBDINPUT 的 32 字节会被 API 直接拒绝，返回 0）

## 五、常用速查

```bash
CU='\\wsl.localhost\Ubuntu\home\zzy6\dsh-computer-use'
OV='\\wsl.localhost\Ubuntu\home\zzy6\dsh-computer-use\agentoverlay.ps1'
# 起覆盖层
nohup powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$OV" -Action start &
# 移动+点击
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CU\cu.ps1" -Action click -X 672 -Y 457
# 键盘
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CU\cu.ps1" -Action keys -Keys 'ctrl+t'
# 收工
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$OV" -Action stop
```

---

# 插件化（dsh-vision，2026-09-11 更新）

## 工具族（插件级，任何对话可用）

**眼睛**：`view_screen` / `view_image`

**手**（自动起覆盖层 + ESC 哨兵）：
| 工具 | 说明 |
|---|---|
| `computer_status` | 覆盖层状态/ESC 标志/当前模式/光标位置 |
| `computer_move {x,y,steps?,delay_ms?}` | 平滑移动 + 光尾 |
| `computer_click {x?,y?,button?}` | 点击（左/右/双击）+ 金色涟漪 |
| `computer_type {text,method?}` | auto 自动判别 Chromium(剪贴板)/WinUI(SendInput) |
| `computer_key {keys}` | 组合键（ctrl+t / enter / alt+f4 ...）|
| `computer_overlay {action}` | start / stop / status |

## 光标三态（overlay-v2）

| 状态 | 视觉 |
|---|---|
| 移动 | 蓝色光环 + 锥形平滑光尾（双通道：外发光+亮核，30 帧历史）|
| 输入 | **青色**光环 + 中心竖线光标（IC 文字光标）|
| 点击 | **琥珀色**光环 + 扩散涟漪（1.2 秒）|
| 取消 | 边框/徽章转琥珀「已取消」，2.2 秒后退出 |

引擎：C# 编译类（`CU.Eng`）跑 60fps 热路径，PowerShell 只敲节拍——**单核 8.8%**（旧版逐帧 New-Object 是掉帧根因）。

## UI 半边（client.js）

- 输入框下方 composer-dock 状态胶囊：彩色圆点 + `CU 待命/移动/输入/点击` + 「停止」按钮
- 数据来自 host 路由：`GET /api/dsh-computer-use/state`、`POST /api/dsh-computer-use/stop`
- ⚠️ 首次注册需要 **DSH 重启**（client-modules 启动时扫描 `dsh.client` 声明）

## 包结构（已正式安装进 profile）

```
/home/zzy6/dsh-vision/
├── package.json        dsh.bundle.patch + dsh.client 声明
├── cordis.patch.yml    bundle 层插入 dsh-vision entry
├── lib/index.js        host 半边：8 个工具 + 2 条 API 路由 + systemPrompt 宣告
└── lib/client.js       browser 半边：状态胶囊
```

**血的教训**：往 `dsh.profile.bundles` 加包前，package.json **必须**有 `dsh.bundle.patch` 声明且 patch 文件存在——否则 DSH 装配 profile 时直接抛错秒退。


---

## ⚠️ 重要修正（2026-09-11 下午）

**不再替换系统光标**。原因：`SetSystemCursor` 会破坏 Windows 原生语境光标行为——
鼠标移到输入框本该变 I 形、移到可点击元素本该变手指，全被我们的全局替换搞坏了，
且不同 DPI 下自定义 .cur 与系统箭头尺寸不一致，观感"不对齐"。

**现在的分工**：
- **系统光标**：完全交给 Windows/app（原生语境光标：箭头 / I 形 / 手指 / 缩放 …）
- **Agent 状态表达**：只靠光环与涟漪
  - 静置 >1 秒 → 光环淡出隐藏（干净）
  - 打字（任何人）→ 蓝色光环圈住光标 + 中心竖线
  - 点击（任何人）→ 蓝色双环涟漪扩散
  - 鼠标移动 → 光环淡入跟随

事件检测全在 C# `Tick()` 里轮询 `GetAsyncKeyState`（按键 ~45 个 + 鼠标左右键），16ms 一帧。
