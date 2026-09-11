# DSH Computer-Use 工具链

Agent 操作 Windows 桌面（Windows 原生 / WSL + Windows，插件自动识别环境）的能力集合。**任何对话都能用**。

## 一、看（视觉通道）

优先用 **dsh-vision 插件**提供的工具（插件级，任何对话自动可用）：
- `view_screen(max_width?)` —— 截 Windows 桌面全屏并直接送进模型视觉通道（默认缩到 1600px）
- `view_image(file_path)` —— 读任意图片文件进视觉通道（支持 Linux 路径和 `C:/...`）

原理：工具返回 `{type:'image', attachment}` 内容块 → 宿主 `collectImageRefs()` 递归收集 → 下一轮请求带图给模型。
若插件不可用，退化用 OCR：`wocr.ps1`（Windows 原生 OCR，中文引擎 zh-Hans-CN，带 `-Boxes` 可返回文字坐标）。

## 二、动（鼠标/键盘）

`cu.ps1` 随插件发布在 `scripts/`，由插件按当前环境自动解析路径并调用（Windows 原生直接调用；WSL 自动转 `\\wsl.localhost\<distro>` UNC）。

| Action | 说明 |
|---|---|
| `pos` / `fg` | 当前光标位置 / 前台窗口 |
| `move -X -Y [-Steps 12 -DelayMs 6]` | 平滑移动（默认 12 步 × 6ms，追求响应速度） |
| `click / dblclick / rclick [-X -Y ...]` | 鼠标点击（带坐标则先平滑移动） |
| `typevk -Text "..."` | **模拟键盘逐键注入（VK，默认路线）**：真实按键事件，跨应用通用（含 Chromium/微信），零剪贴板；非 ASCII 直接报错并提示走输入法 |
| `type -Text "..."` | 剪贴板粘贴式输入 —— **仅当调用方显式指定 `method:'clipboard'` 时才用**（默认禁用） |
| `typehuman -Text "..." [-DelayMs 55 -JitterMs 18]` | **SendInput Unicode 逐字输入**（WinUI 应用可用；**Chromium 会忽略**） |
| `keys -Keys "ctrl+t,enter,esc"` | VK 组合键（Edge 接受 Ctrl 组合；WinUI 应用如记事本不接受） |
| `wheel -Wheel 120` | 滚轮 |
| `shot -Out path` | 截图（带光标绘制） |
| `clear-cancel` | 清除 ESC 取消标志 |

## 三、特效与 ESC 中止

`overlay-v2.ps1 -Action start|stop|status [-MaxSeconds N] [-IdleSeconds N] [-NoCursorChange]`
- 蓝色柔光边框（逐像素 Alpha）+ 顶部玻璃徽章 + 蓝色定制光标 + 跟随光环
- 每 50ms 轮询 `GetAsyncKeyState(VK_ESCAPE)`；按下 → 写取消标志 → 徽章变琥珀色「已取消」→ 2.2s 后退出并恢复系统光标
- 标志目录：由插件通过 `DSH_VISION_FLAG_DIR` 传入（Windows 原生 = `%TEMP%`；WSL = `\\wsl.localhost\<distro>\tmp`），不再双写
- `cu.ps1` 每个动作执行前检查该标志，被取消即拒动（exit 9）

**契约**：开工起覆盖层 → 用户按 ESC → 下一步动作拒绝 → Agent 停下询问；收工 `-Action stop`。

## 四、作业纪律（血泪教训）

1. **先看后点**：点击前必须 `view_screen` 肉眼定位；截图坐标 ×(2560/截图宽) = 真实坐标
2. **点完立刻再看**：验证是否按预期发生
3. **绝不复用缓存坐标**：标签栏/按钮会随内容移动
4. **自绘 UI 的 UIA 矩形不可信**：Edge 标签栏、Win11 记事本标签页会返回错误坐标或 ∞ —— 一律肉眼确认
5. **输入方式（用户铁律：一律走模拟键盘，禁止剪贴板）**：
   - ASCII：`typevk`（VK 逐键注入，跨应用通用，含 Chromium/微信）
   - 中文/非 ASCII：**走输入法** —— `keys` 发拼音字母（如 `n,i,h,a,o`），组合出候选后再 `keys space`（或数字键选候选）上屏
   - `type`（剪贴板）只在显式 `method:'clipboard'` 时使用（默认不再走）；`typehuman`（SendInput Unicode 直注）在 Chromium/微信类 UI 会被静默忽略
   - 兜底（非键盘路线，仅键盘不可用时）：UIA `ValuePattern.SetValue` / `InvokePattern`（不需要焦点、不依赖坐标）
6. **前台锁定**：`SetForegroundWindow` 常失败 → 先模拟一次 ALT 键再调用（经典技巧）
7. **模态对话框会阻塞一切**：检测到操作"无效"时，先 `view_screen` 看有没有对话框在等你
8. **PowerShell 5.1 坑**：脚本文件要 UTF-8 BOM（否则中文按 ANSI 读）；输出中文先设 `[Console]::OutputEncoding`
9. **`Add-Type -MemberDefinition`**：只能放成员片段，不能放整个 class；引用 `System.Drawing` 需换传 HBITMAP 句柄
10. **`SendInput` 的 INPUT 结构体**：x64 上 union 按 `MOUSEINPUT` 对齐 = **40 字节**（只算 KEYBDINPUT 的 32 字节会被 API 直接拒绝，返回 0）

## 五、常用速查

```bash
# 脚本随插件发布在 scripts/，插件会自动按环境解析；手工调用时用当前插件目录下的脚本
CU='<插件目录>\scripts\cu.ps1'
OV='<插件目录>\scripts\overlay-v2.ps1'
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
<插件安装目录>/
├── package.json        dsh.bundle.patch + dsh.client 声明
├── cordis.patch.yml    bundle 层插入 dsh-vision entry
├── lib/index.js        host 半边：8 个工具 + 2 条 API 路由 + systemPrompt 宣告
└── lib/client.js       browser 半边：状态胶囊
```

**血的教训**：往 `dsh.profile.bundles` 加包前，package.json **必须**有 `dsh.bundle.patch` 声明且 patch 文件存在——否则 DSH 装配 profile 时直接抛错秒退。


---

## 光标说明（当前行为）

- 覆盖层默认安装一套蓝白风格光标（箭头 / I 形 / 手指），启动参数 `-NoCursorChange` 可关闭并保留系统默认。
- 系统原生语境切换（输入框 / 可点击元素）仍由 Windows 维护；覆盖层负责蓝框、徽章、光环与点击涟漪。
- 任务进行中覆盖层不会因空闲消失；本回合结束后约 4 秒自动收工（`-IdleSeconds` 为自身兜底超时）。
