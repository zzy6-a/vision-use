// dsh-vision — give the agent a pair of eyes.
//
// Zero runtime dependency on @deepseek-ai/* SDK packages: the tool objects use
// the raw ToolDefinition shape ctx.tools.register accepts (standard JSON Schema,
// an output.render projection, and execute), same strategy as dsh-opencode-usage.
//
// Why this works: the Request assembly collects image blocks recursively from
// message content AND from tool-result content, so an image block produced by a
// tool result reaches the model on the next step.

import { execFile, spawn } from 'node:child_process'
import { readFileSync, writeFileSync, mkdtempSync, existsSync, rmSync, appendFileSync, mkdirSync, statSync, renameSync } from 'node:fs'
import { tmpdir, homedir } from 'node:os'
import { join, extname, basename, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-vision'
export const inject = ['tools', 'attachments', 'systemPrompt', 'webServer']

const MEDIA_BY_EXT = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
}

/** Detect a supported raster media type from magic bytes. */
function sniffMediaType(buf) {
  if (buf.length >= 8 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47 &&
      buf[4] === 0x0d && buf[5] === 0x0a && buf[6] === 0x1a && buf[7] === 0x0a) return 'image/png'
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg'
  if (buf.length >= 6) {
    const sig = buf.subarray(0, 6).toString('latin1')
    if (sig === 'GIF87a' || sig === 'GIF89a') return 'image/gif'
  }
  if (buf.length >= 12 && buf.subarray(0, 4).toString('latin1') === 'RIFF' &&
      buf.subarray(8, 12).toString('latin1') === 'WEBP') return 'image/webp'
  return undefined
}

const ATTACHMENT_SCHEMA = {
  type: 'object',
  additionalProperties: true,
  properties: {
    attachmentId: { type: 'string' },
    mediaType: { type: 'string' },
    bytes: { type: 'integer' },
    width: { type: 'integer' },
    height: { type: 'integer' },
    name: { type: 'string' },
  },
  required: ['attachmentId', 'mediaType', 'bytes', 'width', 'height'],
}

const OUTPUT_SCHEMA = {
  type: 'object',
  additionalProperties: true,
  properties: {
    path: { type: 'string' },
    mediaType: { type: 'string' },
    width: { type: 'integer' },
    height: { type: 'integer' },
    bytes: { type: 'integer' },
    originalWidth: { type: 'integer' },
    originalHeight: { type: 'integer' },
    attachment: ATTACHMENT_SCHEMA,
  },
  required: ['path', 'attachment'],
}

/** Model-facing envelope text that rides beside the image block. */
function envelopeText(value) {
  const scaled = value.originalWidth
    ? ` (downscaled from ${value.originalWidth}x${value.originalHeight} px)`
    : ''
  return `<path>${value.path}</path>\n<type>image</type>\n<content>\n${value.mediaType} image, ${value.width}x${value.height} px, ${value.bytes} bytes${scaled}\n</content>`
}

/** Build one registrable tool definition. */
function makeTool(toolName, description, parameters, handler) {
  return {
    name: toolName,
    description,
    parameters,
    output: {
      schema: OUTPUT_SCHEMA,
      render: (_args, value) => [
        { type: 'text', text: envelopeText(value) },
        { type: 'image', attachment: value.attachment },
      ],
    },
    async execute(args, exec) {
      return handler(args ?? {}, exec)
    },
  }
}

/** Build one registrable TEXT-output tool (no image block). */
function makeTextTool(toolName, description, parameters, handler) {
  return {
    name: toolName,
    description,
    parameters,
    output: {
      schema: {
        type: 'object',
        additionalProperties: true,
        properties: {
          path: { type: 'string' },
          result: { type: 'string' },
        },
        required: [],
      },
      render: (_args, value) => {
        if (value === null || value === undefined) return [{ type: 'text', text: '(no output)' }]
        if (typeof value === 'string') return [{ type: 'text', text: value }]
        const head = value.path ? `${value.path}\n` : ''
        const body = typeof value.result === 'string' ? value.result : JSON.stringify(value, null, 2)
        return [{ type: 'text', text: head + body }]
      },
    },
    async execute(args, exec) {
      return handler(args ?? {}, exec)
    },
  }
}

/**
 * 跟随用户当前选择的模型：只检查它是否声明图片输入能力。
 * 插件不选路由、不改路由——图片始终随会话发给用户选中的模型。
 * 模型未声明识图能力时明确报错（而不是让请求在中途莫名失败）。
 */
async function assertSelectedModelSupportsVision(ctx, exec) {
  let provider = '';
  let model = '';
  let mods;
  try {
    const routed = exec?.agent?.session?.requestHeader?.()?.config;
    provider = String(routed?.provider ?? exec?.agent?.options?.provider ?? '');
    model = String(routed?.model ?? exec?.agent?.options?.model ?? '');
    const llm = typeof ctx.get === 'function' ? ctx.get('llm') : undefined;
    if (!provider || !model || !llm) return;
    const info = await llm.resolveModelInfo(provider, model, exec?.signal);
    mods = info?.inputModalities;
  } catch {
    return; // 查询失败不阻断，交给请求自身报错
  }
  if (Array.isArray(mods) && mods.length > 0 && !mods.includes('image')) {
    throw new Error(
      `当前选择的模型（${provider}/${model}）未声明图片输入能力（inputModalities=${mods.join(',')}）。` +
      `请在模型选择器里切到支持识图的模型；或用本地 OCR 兜底（零 API 成本）：scripts/wocr.ps1`,
    );
  }
}

/** Detect where DSH itself is running: Windows native, WSL, Linux or macOS. */
export function detectHost(platform = process.platform, env = process.env, procVersion = '') {
  if (platform === 'win32') return { kind: 'windows', label: 'Windows 原生', distro: '' }
  if (platform === 'darwin') return { kind: 'darwin', label: 'macOS', distro: '' }
  if (platform === 'linux') {
    let text = procVersion
    if (!text) { try { text = readFileSync('/proc/version', 'utf8') } catch { text = '' } }
    const isWsl = Boolean(env.WSL_DISTRO_NAME) || Boolean(env.WSL_INTEROP) || /microsoft|wsl/i.test(text)
    if (isWsl) return { kind: 'wsl', label: 'WSL + Windows', distro: env.WSL_DISTRO_NAME || 'Ubuntu' }
    return { kind: 'linux', label: 'Linux', distro: '' }
  }
  return { kind: String(platform), label: String(platform), distro: '' }
}

const HOST = detectHost()
const IS_WSL = HOST.kind === 'wsl'
const IS_WINDOWS = HOST.kind === 'windows'
const HAS_WINDOWS_DESKTOP = IS_WSL || IS_WINDOWS
/** Host-local temp dir: /tmp on WSL, %TEMP% on Windows. */
const HOST_TMP = IS_WSL ? '/tmp' : tmpdir()
/** Windows-side flag/state dir handed to PowerShell children. */
const PS_FLAG_DIR = IS_WSL
  ? `\\\\wsl.localhost\\${HOST.distro}${HOST_TMP.replace(/\//g, '\\')}`
  : (IS_WINDOWS ? HOST_TMP : '')
export const hostInfo = { ...HOST, tmp: HOST_TMP, flagDir: PS_FLAG_DIR }
const WSLENV_PASS = IS_WSL
  ? [(process.env.WSLENV || ''), 'DSH_VISION_MODE', 'DSH_VISION_FLAG_DIR'].filter(Boolean).join(':')
  : process.env.WSLENV
const PS_ENV = {
  ...process.env,
  DSH_VISION_MODE: HOST.kind,
  DSH_VISION_FLAG_DIR: PS_FLAG_DIR,
  // 让 cu.ps1 知道宿主进程名：前台是它时拒绝注入，避免把测试/自动化输入灌进用户正在编辑的消息框
  DSH_VISION_FORBID_TARGET: 'DeepSeek Harness',
  ...(WSLENV_PASS ? { WSLENV: WSLENV_PASS } : {}),
}

/** Convert a host-local path to one Windows can open (identity on Windows). */
function toWindowsPath(p) {
  return IS_WSL ? `\\\\wsl.localhost\\${HOST.distro}${String(p).replace(/\//g, '\\')}` : String(p)
}

function assertWindowsDesktop() {
  if (!HAS_WINDOWS_DESKTOP) {
    throw new Error(`当前 DSH 运行在 ${HOST.label}，桌面控制仅支持 Windows 原生与 WSL + Windows；view_image 仍可用于本地图片。`)
  }
}

/** Run a PowerShell script file, resolving the interpreter with a fallback. */
function runPowerShell(scriptPath, timeoutMs, extraArgs = []) {
  if (!HAS_WINDOWS_DESKTOP) {
    return Promise.reject(new Error(`当前 DSH 运行在 ${HOST.label}，桌面控制需要 Windows 原生或 WSL + Windows。`))
  }
  const candidates = IS_WINDOWS
    ? ['powershell.exe', join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')]
    : ['powershell.exe', '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe']
  const winScript = toWindowsPath(scriptPath)
  return new Promise((resolve, reject) => {
    const attempt = (index) => {
      if (index >= candidates.length) { reject(new Error('cannot locate powershell.exe')); return }
      execFile(
        candidates[index],
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', winScript, ...extraArgs],
        { timeout: timeoutMs, windowsHide: true, env: PS_ENV },
        (error, stdout, stderr) => {
          if (error && error.code === 'ENOENT') { attempt(index + 1); return }
          if (error) {
            // cu.ps1 / uia.ps1 把「为什么拒绝」写在 stdout（REFUSED / CANCELLED /
            // UNKNOWN ACTION），退出码才是非零。只拼 stderr 会让上层只看到一句
            // "Command failed: powershell.exe ..."——原因全丢，agent 无从自愈。
            const detail = [String(stdout || '').trim(), String(stderr || '').trim()].filter(Boolean).join(' | ')
            reject(new Error(`${error.message}${detail ? ` | ${detail}` : ''}`))
            return
          }
          resolve(String(stdout))
        },
      )
    }
    attempt(0)
  })
}

/** 面向所有 agent 的能力宣告（环境自动识别）。 */
const COMPUTER_USE_GUIDANCE = HAS_WINDOWS_DESKTOP
  ? `本机 DSH 运行在「${HOST.label}」，插件已自动识别环境，桌面 = Windows。\n` +
    '• 看：view_screen（截 Windows 桌面直接进视觉通道；支持 window=只截某个窗口、region=x,y,w,h 只截一块、grid=100 画坐标标尺、marker_x/marker_y 画红十字确认位置）、view_image（读图片文件进视觉通道）。\n' +
    '• 定位（优先于坐标）：uia_windows 列窗口 → uia_tree 看控件树 → uia_find 按名字找控件（回控件名 + 中心坐标 + 可用 pattern）→ uia_locate 回一张以控件为中心的近景图（不带坐标）→ uia_click 按名字点。\n' +
    '• uia_click 优先走 UI Automation pattern（invoke/toggle/select/expand），这类操作不移动鼠标；只有控件无 pattern 时才退化为坐标点击。点完它会返回前后指纹对比：指纹没变就别盲目重点，先重新观察。\n' +
    '• 边界：原生控件（按钮/菜单/输入框/列表项）UIA 树完整，一律先走 uia_*；Chromium/Electron 自绘界面 UIA 往往是空树，那种情况退回 view_screen + 坐标。\n' +
    '• 动：computer_move / computer_click / computer_type / computer_key（统一走插件内置 scripts/cu.ps1）；所有 hands 操作强制开启覆盖层，任务进行中不会自动关闭。\n' +
    '• 特效+中止：覆盖层由插件自动管理；用户按 ESC 会写取消标志，之后所有动作拒动——此时应停下询问用户。\n' +
    '• 前台冲突（常见踩坑）：DSH 窗口在前台时，**不带 hwnd 的输入注入会被拒绝**——防止键盘事件落进用户正在编辑的消息框。' +
    '要往别的窗口打字，先用 uia_windows 取目标 hwnd，再带 hwnd 调用 computer_type / computer_key / computer_sequence' +
    '（脚本会先激活目标窗口，不会误伤）。被拒时会明确回 REFUSED 原因，照它补 hwnd 重试即可。\n' +
    '• 铁律：先 view_screen 肉眼定位再点、点完立刻再看验证、不复用缓存坐标；自绘 UI 的 UIA 坐标不可信。\n' +
    '• 输入通道（铁律·用户指定）：一律模拟键盘注入，禁止剪贴板。ASCII 用 computer_type（VK 逐键，跨应用通用）；中文走输入法——'
    + 'computer_key 依次发拼音字母（如 n,i,h,a,o），再 computer_key space/数字 上屏；typehuman（Unicode 直注）在 Chromium/微信类 UI 会被静默忽略，别用。'
  : `本机 DSH 运行在「${HOST.label}」，桌面控制仅支持 Windows 原生与 WSL + Windows；view_image 仍可用于本地图片。`

export function apply(ctx) {
  const attachments = ctx.attachments

  // ===== 工具脚本位置（view_screen 与新 UIA 工具共用，提到最前）=====
  const HERE = dirname(fileURLToPath(import.meta.url))
  const BUNDLED = join(HERE, '..', 'scripts')
  const TOOLKIT_FALLBACK = process.env.DSH_VISION_TOOLKIT_DIR || join(homedir(), 'dsh-computer-use')
  const CU_DIR = existsSync(join(BUNDLED, 'cu.ps1')) ? BUNDLED : TOOLKIT_FALLBACK
  const CU_PS1 = join(CU_DIR, 'cu.ps1')
  const UIA_PS1 = join(CU_DIR, 'uia.ps1')
  const OVERLAY_PS1 = join(CU_DIR, 'overlay-v2.ps1')
  const AUDIT_DIR = join(homedir(), '.dsh', 'vision')

  /** 审计日志：每个会改变桌面状态的动作追加一行 JSONL（只追加，不覆盖）。 */
  function audit(entry) {
    try {
      mkdirSync(AUDIT_DIR, { recursive: true })
      const day = new Date().toISOString().slice(0, 10)
      const file = join(AUDIT_DIR, `audit-${day}.jsonl`)
      // 单日文件超过 5 MB 就滚到 .1（只保留一代），避免长期运行无限增长
      try {
        const st = statSync(file)
        if (st.size > 5 * 1024 * 1024) renameSync(file, `${file}.1`)
      } catch { /* 文件不存在或改名失败都继续写 */ }
      appendFileSync(file, JSON.stringify({ ts: Date.now(), ...entry }) + '\n', 'utf8')
    } catch { /* 审计失败不阻断动作 */ }
  }

  /** 解析 PowerShell 输出的 JSONL，返回对象数组（忽略非 JSON 行）。 */
  function parseJsonLines(out) {
    const rows = []
    for (const line of String(out).split(/\r?\n/)) {
      const s = line.trim()
      if (!s.startsWith('{')) continue
      try { rows.push(JSON.parse(s)) } catch { /* 跳过 */ }
    }
    return rows
  }

  // 能力宣告：让每个 agent 都知道本机有计算机操作能力
  let disposeGuidance
  try {
    disposeGuidance = ctx.systemPrompt.section({
      name: 'plugin:dsh-vision',
      order: 150,
      text: COMPUTER_USE_GUIDANCE,
    })
  } catch { /* systemPrompt 未挂载时静默跳过 */ }

  /** Commit image bytes to the attachment store and shape the tool value. */
  async function commitImage(bytes, mediaType, displayPath, name) {
    const ref = await attachments.saveImage({
      data: new Uint8Array(bytes),
      mediaType,
      ...(name ? { name } : {}),
    })
    return {
      path: displayPath,
      mediaType: ref.mediaType,
      width: ref.width,
      height: ref.height,
      bytes: ref.bytes,
      ...(ref.originalDimensions
        ? { originalWidth: ref.originalDimensions.width, originalHeight: ref.originalDimensions.height }
        : {}),
      attachment: ref,
    }
  }

  const disposeViewImage = ctx.tools.register(makeTool(
    'view_image',
    'Load a local PNG/JPEG/WebP/GIF image into the conversation so you can actually see it. ' +
    'Use it to inspect screenshots, UI photos, diagrams, or rendered outputs. ' +
    'Accepts Linux paths and Windows paths (C:/Users/...). The image is validated and downscaled ' +
    'by the harness before it reaches you.',
    {
      type: 'object',
      additionalProperties: false,
      properties: {
        file_path: { type: 'string', description: 'Path to the image file (Linux or Windows path).' },
      },
      required: ['file_path'],
    },
    async (args, exec) => {
      await assertSelectedModelSupportsVision(ctx, exec)
      const raw = String(args.file_path ?? '').trim()
      if (raw.length === 0) throw new Error('file_path must be a non-empty string')
      // Map a Windows drive path to its WSL mount when running inside WSL.
      let local = raw
      if (IS_WSL) {
        const drive = /^([A-Za-z]):[\\/](.*)$/.exec(raw)
        if (drive) local = `/mnt/${drive[1].toLowerCase()}/${drive[2].replace(/\\/g, '/')}`
      } else if (IS_WINDOWS) {
        const mnt = /^\/mnt\/([a-z])(?:\/(.*))?$/i.exec(raw)
        if (mnt) local = `${mnt[1].toUpperCase()}:\\${(mnt[2] || '').replace(/\//g, '\\')}`
      }
      const buf = readFileSync(local)
      const mediaType = sniffMediaType(buf) ?? MEDIA_BY_EXT[extname(local).toLowerCase()]
      if (!mediaType) throw new Error(`not a supported image (PNG/JPEG/WebP/GIF): ${raw}`)
      return commitImage(buf, mediaType, raw, basename(local))
    },
  ))

  const disposeViewScreen = ctx.tools.register(makeTool(
    'view_screen',
    'Capture the Windows screen and attach the screenshot so you can actually see it. ' +
    'Three capture modes: whole desktop (default), one window (pass `window`, a fragment of its title), ' +
    'or one region (pass `region` as "x,y,w,h"). Optional `grid` draws coordinate rulers so you can read ' +
    'positions off the image instead of guessing; optional `marker_x`/`marker_y` draws a red crosshair at a ' +
    'point so you can verify "is this the control I think it is". Prefer `uia_find`/`uia_locate` when the ' +
    'target is a real control — they avoid coordinate math entirely.',
    {
      type: 'object',
      additionalProperties: false,
      properties: {
        max_width: { type: 'integer', description: 'Maximum width of the attached screenshot (default 1600).' },
        delay_ms: { type: 'integer', description: 'Optional delay before capture, milliseconds (default 0).' },
        window: { type: 'string', description: 'Only capture the first window whose title contains this text.' },
        hwnd: { type: 'integer', description: 'Exact window handle: capture that window via PrintWindow, so it works even when the window is covered.' },
        region: { type: 'string', description: 'Only capture this rectangle: "x,y,w,h" in screen pixels.' },
        grid: { type: 'integer', description: 'Draw a coordinate grid every N pixels (e.g. 100) with labelled axes.' },
        marker_x: { type: 'integer', description: 'Optional X of a point to crosshair-mark on the image.' },
        marker_y: { type: 'integer', description: 'Optional Y of a point to crosshair-mark on the image.' },
      },
      required: [],
    },
    async (args, exec) => {
      assertWindowsDesktop()
      await assertSelectedModelSupportsVision(ctx, exec)
      const maxWidth = Number.isFinite(args.max_width)
        ? Math.max(320, Math.min(3840, Math.trunc(args.max_width)))
        : 1600
      const delay = Number.isFinite(args.delay_ms) ? Math.max(0, Math.min(10000, Math.trunc(args.delay_ms))) : 0
      const dir = mkdtempSync(join(tmpdir(), 'dsh-vision-'))
      const shot = join(dir, 'screen.png')
      const extra = ['-Action', 'shot', '-Out', toWindowsPath(shot), '-MaxWidth', String(maxWidth)]
      if (typeof args.region === 'string' && args.region.trim() !== '') extra.push('-Rect', args.region.trim())
      if (typeof args.window === 'string' && args.window.trim() !== '') extra.push('-Window', args.window.trim())
      if (Number.isFinite(args.hwnd) && args.hwnd !== 0) extra.push('-Hwnd', String(Math.trunc(args.hwnd)))
      if (Number.isFinite(args.grid) && args.grid > 0) extra.push('-Grid', String(Math.trunc(args.grid)))
      const mx = Number.isFinite(args.marker_x) ? Math.trunc(args.marker_x) : -1
      const my = Number.isFinite(args.marker_y) ? Math.trunc(args.marker_y) : -1
      if (mx >= 0 && my >= 0) extra.push('-MarkerX', String(mx), '-MarkerY', String(my))
      if (delay > 0) await new Promise((r) => setTimeout(r, delay))
      let out
      try {
        out = await serializeHands(() => runPowerShell(CU_PS1, 30000, extra))
      } catch (e) {
        // hwnd 模式失败（句柄失效 / 应用不支持 PrintWindow）→ 去掉 -Hwnd 退回屏幕捕获
        const h = extra.indexOf('-Hwnd')
        if (h < 0) throw e
        const fallback = extra.slice(0, h).concat(extra.slice(h + 2))
        out = await runPowerShell(CU_PS1, 30000, fallback)
      }
      const mode = args.window ? `window "${args.window}"` : args.region ? `region ${args.region}` : 'desktop'
      audit({ tool: 'view_screen', mode, grid: args.grid ?? null, marker: mx >= 0 ? [mx, my] : null, ok: /^SHOT/.test(out) })
      const buf = readFileSync(shot)
      try { rmSync(dir, { recursive: true, force: true }) } catch { /* 临时目录清理失败不阻断 */ }
      return commitImage(buf, 'image/png', `screen://${mode} (${maxWidth}px max)`, 'screen.png')
    },
  ))

  // ======================= 计算机操作工具族（hands）=======================
  // 脚本路径常量已在 apply() 开头定义（view_screen 与新 UIA 工具共用）
  const FLAG_ACTIVE = join(HOST_TMP, 'dsh_agent_active.flag')
  const FLAG_CANCEL = join(HOST_TMP, 'dsh_agent_cancel.flag')
  const STATE_FILE = join(HOST_TMP, 'dsh_cu_state.json')

  const overlayRunning = () => existsSync(FLAG_ACTIVE)
  // Esc 取消标记是"一次性"的：它只描述「刚才那一下用户喊停了」，
  // 不能永久生效。历史上 overlay 写完 'esc' 就再没清过 → 之后每次
  // hands 调用都被误判成「用户按下了 Esc」（用户实际没按）。
  // 三层收敛：① apply 时清残留 ② 新 turn 开始即清（新一轮＝重新授权）
  // ③ 超过 TTL 的陈旧标记自动作废。
  const CANCEL_TTL_MS = 5 * 60 * 1000
  const clearCancel = () => { try { rmSync(FLAG_CANCEL, { force: true }) } catch {} }
  const cancelled = () => {
    if (!existsSync(FLAG_CANCEL)) return false
    try {
      if (Date.now() - statSync(FLAG_CANCEL).mtimeMs > CANCEL_TTL_MS) { clearCancel(); return false }
    } catch { return false }
    return true
  }
  // ① 启动即清：上个进程遗留的 Esc 不该阻塞新会话（DSH 重启后 flag 仍在是历史 bug）。
  clearCancel()

  // ===== 任务级保活 =====
  // 覆盖层不应在 agent 还在思考/执行其他工具时自动消失。
  // 每次 hands 操作会获得一个 20 分钟的"工作租约"；agent 的 session 事件会持续续约，
  // turn 结束后给 4 秒余辉再收工。租约到期仍无人续约时才兜底关闭。
  // 工作租约：每次 agent 活动（工具调用 / step 事件）都会续约。
  // 3 分钟足够覆盖模型的思考间隔；超时说明这一轮真的结束了，兜底收工。
  const KEEPALIVE_MS = 3 * 60 * 1000
  const GRACE_MS = 4000
  let overlayArmed = false
  let workLeaseUntil = 0
  let stopTimer = null
  function armOverlay() {
    overlayArmed = true
    workLeaseUntil = Date.now() + KEEPALIVE_MS
    if (stopTimer) { clearTimeout(stopTimer); stopTimer = null }
  }
  function noteAgentActivity() {
    if (overlayArmed && workLeaseUntil > 0) workLeaseUntil = Date.now() + KEEPALIVE_MS
  }
  function endOverlayTask() {
    if (!overlayArmed) return
    workLeaseUntil = 0
    overlayArmed = false
    if (stopTimer) clearTimeout(stopTimer)
    stopTimer = setTimeout(() => {
      stopTimer = null
      if (overlayRunning()) runPowerShell(OVERLAY_PS1, 30000, ['-Action', 'stop']).catch(() => {})
    }, GRACE_MS)
    stopTimer.unref?.()
  }

  function startOverlay(idleSeconds = 600) {
    assertWindowsDesktop()
    armOverlay()
    const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', toWindowsPath(OVERLAY_PS1), '-Action', 'start']
    if (Number.isFinite(idleSeconds)) args.push('-IdleSeconds', String(Math.max(0, Math.trunc(idleSeconds))))
    // 注意：这里不能 detached —— 实测 detached 时 WPF 消息循环起不来，
    // overlay 启动即退出（active.flag 不落地，computer_status 恒报 stopped）。
    // 保留 windowsHide 以免闪一个 PowerShell 控制台窗口。
    const child = spawn('powershell.exe', args, { stdio: 'ignore', windowsHide: true, env: PS_ENV })
    child.unref()
  }

  /** 确保覆盖层在跑（ESC 中止哨兵 + 特效）；被 ESC 取消时直接抛错拒动。 */
  // 强制开启：hands 操作永远不允许绕过覆盖层（用户必须能看到电脑正在被操作）。
  async function ensureOverlay() {
    assertWindowsDesktop()
    if (cancelled()) throw new Error('用户按下了 Esc，操作已被取消（computer_overlay stop 或再次 start 可重置）')
    armOverlay()
    touchHeartbeat()
    if (overlayRunning()) return false
    startOverlay()
    for (let i = 0; i < 20; i += 1) {
      await new Promise((r) => setTimeout(r, 200))
      if (overlayRunning()) return true
    }
    return true
  }

  /** 刷新覆盖层心跳（每次工具调用都刷新；覆盖层空闲超时会自行退出）。 */
  function touchHeartbeat() {
    const stamp = String(Date.now())
    try { writeFileSync(join(HOST_TMP, 'dsh_agent_heartbeat'), stamp) } catch {}
  }

  // 桌面动作必须串行：模型可能并行发起多个工具调用（click + type 同时），
  // 两个 PowerShell 进程会争抢同一个光标/焦点，结果不可预测。这里排成一条队列。
  let handsLock = Promise.resolve()
  function serializeHands(fn) {
    const next = handsLock.then(fn, fn)
    handsLock = next.then(() => {}, () => {})
    return next
  }

  async function runCu(action, extra = [], timeoutMs = 120000) {
    return serializeHands(async () => {
      touchHeartbeat()
      return runPowerShell(CU_PS1, timeoutMs, ['-Action', action, ...extra])
    })
  }

  // ===== 只要 agent 还在干活，就不让覆盖层空闲退出 =====
  try {
    ctx.effect(() => {
      const ACTIVITY = new Set([
        'turn/start', 'step/start', 'step/end',
        'tool/call', 'tool/result', 'assistant/message', 'assistant/attempt',
      ])
      const off = typeof ctx.on === 'function'
        ? ctx.on('session/event', (session, event) => {
            const type = event?.type
            if (type === 'turn/end') { endOverlayTask(); return }
            // ② 新一轮用户回合开始＝重新授权：清掉上一轮遗留的 Esc 标记。
            if (type === 'turn/start') clearCancel()
            if (ACTIVITY.has(type)) noteAgentActivity()
          })
        : undefined
      const timer = setInterval(() => {
        if (!overlayArmed || !overlayRunning()) return
        if (Date.now() < workLeaseUntil) { touchHeartbeat(); return }
        // 租约到期且没有后续 session 事件（例如事件 API 不可用）→ 兜底收工
        overlayArmed = false
        runPowerShell(OVERLAY_PS1, 30000, ['-Action', 'stop']).catch(() => {})
      }, 3000)
      timer.unref?.()
      return () => {
        try { off?.() } catch {}
        clearInterval(timer)
        if (stopTimer) { clearTimeout(stopTimer); stopTimer = null }
      }
    }, 'dsh-vision: overlay keepalive')
  } catch { /* 无事件/effect API 时退化为覆盖层自身空闲超时兜底 */ }

  const S = (v) => String(v)

  const disposeComputerStatus = ctx.tools.register(makeTextTool(
    'computer_status',
    'Report the computer-use state: overlay running (pid), Esc-cancel flag, current cursor mode, and whether the hands toolkit is ready.',
    { type: 'object', additionalProperties: false, properties: {}, required: [] },
    async () => {
      if (!HAS_WINDOWS_DESKTOP) {
        return { path: 'computer://status', overlay: 'unsupported', reason: `${HOST.label}: 桌面控制仅支持 Windows 原生与 WSL + Windows`, toolkit: CU_DIR }
      }
      // 一次 PowerShell 调用取齐全部状态（原先是 fg + pos 两个进程，约 0.9s）
      let st = null
      try {
        const out = await runCu('status', [], 30000)
        const line = String(out).split(/\r?\n/).map((l) => l.trim()).find((l) => l.startsWith('{'))
        st = line ? JSON.parse(line) : null
      } catch (e) {
        st = { ok: false, error: e.message }
      }
      if (!st || st.ok === false) {
        return {
          path: 'computer://status',
          overlay: 'unknown',
          error: st?.error ?? 'status query returned no JSON',
          toolkit: `${CU_DIR} (cu.ps1 + overlay-v2.ps1)`,
        }
      }
      let modeRaw = String(st.mode ?? '')
      let modePretty = modeRaw
      try {
        const parsed = JSON.parse(modeRaw)
        modePretty = parsed?.mode ? `${parsed.mode}` : modeRaw
      } catch { /* 保留原始字符串 */ }
      return {
        path: 'computer://status',
        overlay: st.overlayPid ? `running (${st.overlayPid})` : 'stopped',
        escCancel: st.cancel ? `SET (${st.cancel})` : 'clear',
        mode: modePretty || 'idle',
        foreground: st.fgName ? `FG pid=${st.fgPid} name=${st.fgName} title=${st.fgTitle}` : '(no foreground process)',
        cursor: `POS ${st.cursorX},${st.cursorY}`,
        toolkit: `${CU_DIR} (cu.ps1 + overlay-v2.ps1)`,
      }
    },
  ))

  const disposeComputerMove = ctx.tools.register(makeTextTool(
    'computer_move',
    'Move the Windows mouse cursor smoothly to (x, y). Steps and delay control speed/visibility. Shows the on-screen cursor trail. The overlay (blue frame + Esc abort) is always forced on.',
    {
      type: 'object', additionalProperties: false,
      properties: {
        x: { type: 'integer', description: 'Target X in screen pixels.' },
        y: { type: 'integer', description: 'Target Y in screen pixels.' },
        steps: { type: 'integer', description: 'Interpolation steps (default 12, higher = slower/smoother).' },
        delay_ms: { type: 'integer', description: 'Delay per step in ms (default 6).' },
      },
      required: ['x', 'y'],
    },
    async (args) => {
      await ensureOverlay()
      const out = await runCu('move', ['-X', S(Math.trunc(args.x)), '-Y', S(Math.trunc(args.y)), '-Steps', S(args.steps ?? 12), '-DelayMs', S(args.delay_ms ?? 6)])
      return { path: 'computer://move', result: out }
    },
  ))

  const disposeComputerClick = ctx.tools.register(makeTextTool(
    'computer_click',
    'Click the Windows mouse at an optional (x, y) — moves there first with a visible glide and a click ripple effect. button: left|right|double. The overlay is always forced on.',
    {
      type: 'object', additionalProperties: false,
      properties: {
        x: { type: 'integer', description: 'Optional target X.' },
        y: { type: 'integer', description: 'Optional target Y.' },
        button: { type: 'string', description: 'left (default) | right | double' },
        hwnd: { type: 'integer', description: 'Window handle to force to the foreground before clicking. REQUIRED when the target window is covered by another window — otherwise the click lands on whatever is on top.' },
      },
      required: [],
    },
    async (args) => {
      await ensureOverlay()
      const action = args.button === 'right' ? 'rclick' : args.button === 'double' ? 'dblclick' : 'click'
      const extra = []
      if (Number.isFinite(args.hwnd) && args.hwnd !== 0) extra.push('-ActivateHwnd', String(Math.trunc(args.hwnd)))
      if (Number.isFinite(args.x) && Number.isFinite(args.y)) extra.push('-X', S(Math.trunc(args.x)), '-Y', S(Math.trunc(args.y)), '-Steps', '12', '-DelayMs', '6')
      const out = await runCu(action, extra)
      return { path: 'computer://click', result: out }
    },
  ))

  const disposeComputerTypeReal = ctx.tools.register(makeTextTool(
    'computer_type',
    'Type ASCII text into the focused window via real simulated keystrokes (VK), no clipboard involved. Default method vk applies to any app including Chromium/WeChat. Non-ASCII is rejected on purpose: for Chinese use the IME route instead - computer_key with pinyin letters (e.g. \"n,i,h,a,o\") then computer_key \"space\" (or a digit) to commit the candidate. method: vk (default/auto) | clipboard (explicit opt-in, uses the system clipboard) | sendinput (Unicode injection, WinUI/Notepad only).',
    {
      type: 'object', additionalProperties: false,
      properties: {
        text: { type: 'string', description: 'Text to type (Unicode OK).' },
        method: { type: 'string', description: 'auto (default: ASCII→vk real keystrokes; non-ASCII/text with Chinese→clipboard) | vk (real VK keystrokes, ASCII only — CJK chars are dropped) | clipboard (paste; saves and restores the previous clipboard content) | uia (UIA ValuePattern; REPLACES the whole control value; not supported by every control) | sendinput (KEYEVENTF_UNICODE; silently ignored by Win11 Notepad and Chromium)' },
        hwnd: { type: 'integer', description: 'Window handle to force to the foreground before typing.' },
      },
      required: ['text'],
    },
    async (args) => {
      await ensureOverlay()
      let method = args.method ?? 'auto'
      const rawText = String(args.text ?? '')
      const hasNonAscii = /[^\x00-\x7F]/.test(rawText)
      if (method === 'auto') {
        // 铁律：ASCII 一律真实按键（绝不默认走剪贴板）；
        // 只有文本里出现非 ASCII（中文等）才用剪贴板 —— 那是唯一通用通道，
        // 且 cu.ps1 的 type 动作会保存并还原用户原剪贴板内容。
        // 长 ASCII 文本也走剪贴板：VK 逐键受 Start-Sleep 精度限制（实测每字符约 30ms），
        // 100 字符要 3.7 秒；剪贴板 0.5 秒。剪贴板内容会保存并还原，不污染。
        method = (hasNonAscii || rawText.length > 120) ? 'clipboard' : 'vk'
      }
      const action = method === 'uia' ? 'uiatype'
        : method === 'sendinput' ? 'typehuman'
        : method === 'clipboard' ? 'type'
        : 'typevk'
      const extra = ['-Text', rawText]
      if (Number.isFinite(args.hwnd) && args.hwnd !== 0) extra.push('-ActivateHwnd', String(Math.trunc(args.hwnd)))
      if (action === 'typehuman') extra.push('-DelayMs', '55', '-JitterMs', '18')
      const out = await runCu(action, extra)
      return { path: `computer://type (${method})`, result: out }
    },
  ))

  const disposeComputerKey = ctx.tools.register(makeTextTool(
    'computer_key',
    'Send keyboard shortcuts / keys to the focused Windows window. keys is a comma-separated list of combos, e.g. "ctrl+t", "enter", "alt+f4", "ctrl+shift+t".',
    {
      type: 'object', additionalProperties: false,
      properties: {
        keys: { type: 'string', description: 'Combos like ctrl+t,enter,esc' },
        hwnd: { type: 'integer', description: 'Window handle to force to the foreground before sending keys.' },
      },
      required: ['keys'],
    },
    async (args) => {
      await ensureOverlay()
      const kargs = ['-Keys', S(args.keys)]
      if (Number.isFinite(args.hwnd) && args.hwnd !== 0) kargs.push('-ActivateHwnd', String(Math.trunc(args.hwnd)))
      const out = await runCu('keys', kargs)
      return { path: 'computer://key', result: out }
    },
  ))

  const disposeComputerOverlay = ctx.tools.register(makeTextTool(
    'computer_overlay',
    'Control the computer-use overlay (blue frame + badge + agent cursor + Esc abort sentinel). action: start | stop | status.',
    {
      type: 'object', additionalProperties: false,
      properties: {
        action: { type: 'string', description: 'start | stop | status' },
        idle_seconds: { type: 'integer', description: '覆盖层自身空闲兜底秒数（默认 600，仅防崩溃时永驻）。正常关闭由插件在回合结束后 4 秒自动执行，不用传这个。' },
      },
      required: ['action'],
    },
    async (args) => {
      const action = String(args.action || 'status')
      if (action === 'start') {
        try { rmSync(FLAG_CANCEL, { force: true }) } catch {}
        startOverlay(Number.isFinite(args.idle_seconds) ? args.idle_seconds : 600)
        await new Promise((r) => setTimeout(r, 1500))
        return { path: 'computer://overlay', result: overlayRunning() ? 'started' : 'start requested (check computer_status)' }
      }
      if (action === 'stop') {
        const out = await runPowerShell(OVERLAY_PS1, 30000, ['-Action', 'stop'])
        return { path: 'computer://overlay', result: out || 'stopped' }
      }
      return { path: 'computer://overlay', result: overlayRunning() ? 'running' : 'stopped' }
    },
  ))

  // ======================= UIA 定位工具族 =======================
  // 借鉴：Yu-tao-Li/dsh-computer-use-win（控件树定位）、STARDUSTLC666（操作后重新观察）、
  //       sxwsc667/dsh-use-computer（坐标不进对话，只回近景图）、rayadesune/dsh-ui（坐标映射）。
  // 设计原则：能按名字点就不按坐标点；点完给指纹对比，让模型自己判断"到底变了没有"。

  async function runUia(action, extra = [], timeoutMs = 45000) {
    const out = await serializeHands(() => runPowerShell(UIA_PS1, timeoutMs, ['-Action', action, ...extra]))
    return parseJsonLines(out)
  }

  function uiaTargetArgs(args) {
    const extra = []
    if (typeof args.window === 'string' && args.window.trim() !== '') extra.push('-Window', args.window.trim())
    if (Number.isFinite(args.hwnd) && args.hwnd !== 0) extra.push('-Handle', String(Math.trunc(args.hwnd)))
    return extra
  }

  function rectOf(node) {
    const r = node?.rect
    return r && Number.isFinite(r.x) ? r : null
  }

  /** PowerShell 5.1 的 ConvertTo-Json 会把单元素数组压成字符串，这里统一成数组。 */
  function patsOf(node) {
    const p = node?.patterns
    if (Array.isArray(p)) return p
    if (typeof p === 'string' && p !== '') return p.split(',')
    return []
  }

  const disposeUiaWindows = ctx.tools.register(makeTextTool(
    'uia_windows',
    'List top-level windows on the Windows desktop: title, pid, class, rect, center, and which one is foreground. ' +
    'Call this first when you have to act on a window you did not open — the other uia_* tools accept the title or hwnd you get here.',
    { type: 'object', additionalProperties: false, properties: {}, required: [] },
    async () => {
      assertWindowsDesktop()
      const rows = await runUia('windows')
      const head = rows.find((r) => r && Array.isArray(r.windows))
      if (!head) return { path: 'uia://windows', result: '(no windows reported)' }
      const body = head.windows.map((w) => {
        const mark = w.foreground ? '*' : ' '
        const r = w.rect
        return `${mark} "${w.title}"\n    hwnd=${w.hwnd} pid=${w.pid} cls=${w.cls}\n    rect=${r.x},${r.y} ${r.w}x${r.h} center=${r.cx},${r.cy}`
      }).join('\n')
      return { path: 'uia://windows', result: `${head.count} windows (* = foreground)\n\n${body}` }
    },
  ))

  const disposeUiaTree = ctx.tools.register(makeTextTool(
    'uia_tree',
    'Dump the UI Automation control tree of one window: control type, name, AutomationId, center/rect, enabled/offscreen flags and supported patterns. ' +
    'This is how you learn what the UI is actually made of (buttons, edits, list items) instead of guessing from pixels. ' +
    'Note: Chromium/Electron windows only expose a few nodes unless the app enables accessibility — for those, fall back to view_screen + coordinates.',
    {
      type: 'object', additionalProperties: false,
      properties: {
        window: { type: 'string', description: 'Title fragment. Defaults to the foreground window.' },
        hwnd: { type: 'integer', description: 'Exact window handle (overrides window).' },
        max_depth: { type: 'integer', description: 'Tree depth limit (default 4).' },
        max_items: { type: 'integer', description: 'Node budget (default 80, max 400).' },
        control_type: { type: 'string', description: 'Only emit this control type: Button / Edit / MenuItem / Text ...' },
        enabled_only: { type: 'boolean', description: 'Only enabled controls.' },
      },
      required: [],
    },
    async (args) => {
      assertWindowsDesktop()
      const extra = uiaTargetArgs(args)
      extra.push('-MaxDepth', String(Number.isFinite(args.max_depth) ? Math.trunc(args.max_depth) : 4))
      extra.push('-MaxItems', String(Math.min(400, Number.isFinite(args.max_items) ? Math.trunc(args.max_items) : 80)))
      if (typeof args.control_type === 'string' && args.control_type.trim() !== '') extra.push('-ControlType', args.control_type.trim())
      if (args.enabled_only === true) extra.push('-EnabledOnly')
      const rows = await runUia('tree', extra)
      if (!rows.length) return { path: 'uia://tree', result: '(no output from uia.ps1)' }
      const meta = rows[0]
      if (meta && meta.ok === false) return { path: 'uia://tree', result: `error: ${meta.error}` }
      const win = meta.window
      const nodes = rows.filter((r) => r && typeof r.depth === 'number')
      const tail = rows.find((r) => r && typeof r.emitted === 'number')
      const body = nodes.map((n) => {
        const indent = '  '.repeat(n.depth)
        const r = rectOf(n)
        const where = r ? `${r.cx},${r.cy} (${r.w}x${r.h})` : '-'
        const pl = patsOf(n)
        const pats = pl.length ? ` [${pl.join(',')}]` : ''
        const flags = `${n.enabled ? '' : ' disabled'}${n.offscreen ? ' offscreen' : ''}`
        const autoId = n.autoId ? ` #${n.autoId}` : ''
        return `${indent}${n.type} "${n.name}"${autoId} @${where}${pats}${flags}`
      }).join('\n')
      return {
        path: 'uia://tree',
        result: `window: "${win?.title}" hwnd=${win?.hwnd} pid=${win?.pid}\n${nodes.length} nodes${tail?.truncated ? ' (truncated — raise max_items or lower max_depth)' : ''}\n\n${body}`,
      }
    },
  ))

  const disposeUiaFind = ctx.tools.register(makeTextTool(
    'uia_find',
    'Find controls by name inside one window (fuzzy, case-insensitive; also matches AutomationId and ClassName). ' +
    'Returns control type, name, rect center and supported patterns for every hit, plus an index you can feed to uia_click. ' +
    'This is the "look before you click" step — no pixel math needed. Prefer it over coordinate clicking whenever the target is a real control.',
    {
      type: 'object', additionalProperties: false,
      properties: {
        name: { type: 'string', description: 'Fragment of the control name / AutomationId / ClassName. Empty = list everything.' },
        window: { type: 'string', description: 'Title fragment of the window. Defaults to the foreground window.' },
        hwnd: { type: 'integer', description: 'Exact window handle (overrides window).' },
        max_depth: { type: 'integer', description: 'Search depth (default 5).' },
        enabled_only: { type: 'boolean', description: 'Skip disabled controls.' },
        control_type: { type: 'string', description: 'Restrict to a control type, e.g. Button.' },
      },
      required: [],
    },
    async (args) => {
      assertWindowsDesktop()
      const extra = uiaTargetArgs(args)
      extra.push('-Name', String(args.name ?? ''))
      extra.push('-MaxDepth', String(Number.isFinite(args.max_depth) ? Math.trunc(args.max_depth) : 5))
      if (args.enabled_only === true) extra.push('-EnabledOnly')
      if (typeof args.control_type === 'string' && args.control_type.trim() !== '') extra.push('-ControlType', args.control_type.trim())
      const rows = await runUia('find', extra)
      const head = rows.find((r) => r && Array.isArray(r.matches))
      if (!head) return { path: 'uia://find', result: rows[0]?.error ?? '(no output from uia.ps1)' }
      if (head.hits === 0) {
        return {
          path: 'uia://find',
          result: `window "${head.window?.title}" — 0 controls match "${args.name}" (scanned ${head.scanned}). ` +
            `Try a shorter fragment, another language (UI labels may be English), or uia_tree to see what exists.`,
        }
      }
      const lines = head.matches.map((m) => {
        const r = m.rect
        const pl = patsOf(m)
        const pats = pl.length ? ` [${pl.join(',')}]` : ' [no-pattern → coordinate click only]'
        const flags = `${m.enabled ? '' : ' disabled'}${m.offscreen ? ' offscreen' : ''}`
        return `[${m.index}] ${m.type} "${m.name}"${m.autoId ? ` #${m.autoId}` : ''}\n     center=${r?.cx},${r?.cy} size=${r?.w}x${r?.h}${pats}${flags}`
      }).join('\n')
      return {
        path: 'uia://find',
        result: `window "${head.window?.title}" — ${head.hits} hit(s) of ${head.scanned} scanned\n\n${lines}\n\n` +
          `Next: uia_click with name="${args.name}"${head.hits > 1 ? ' and index=N' : ''}.`,
      }
    },
  ))

  const disposeUiaLocate = ctx.tools.register(makeTool(
    'uia_locate',
    'Locate a control by name and return a CLOSE-UP screenshot centred on it — the image carries no coordinates, ' +
    'so you confirm by looking rather than by arithmetic. Use it right before clicking something you must not get wrong ' +
    '(dialogs, destructive buttons, inputs in dense toolbars).',
    {
      type: 'object', additionalProperties: false,
      properties: {
        name: { type: 'string', description: 'Fragment of the control name / AutomationId.' },
        window: { type: 'string', description: 'Title fragment. Defaults to the foreground window.' },
        hwnd: { type: 'integer', description: 'Exact window handle (overrides window).' },
        index: { type: 'integer', description: 'Which hit to show when several match (default 0).' },
        span: { type: 'integer', description: 'Half-size of the crop in pixels (default 240 → ~480x320 crop).' },
      },
      required: ['name'],
    },
    async (args, exec) => {
      assertWindowsDesktop()
      await assertSelectedModelSupportsVision(ctx, exec)
      const extra = uiaTargetArgs(args)
      extra.push('-Name', String(args.name))
      extra.push('-MaxDepth', '5')
      const rows = await runUia('find', extra)
      const head = rows.find((r) => r && Array.isArray(r.matches))
      if (!head || !head.matches || head.matches.length === 0) {
        throw new Error(`uia_locate: 没有匹配 "${args.name}" 的控件（窗口 "${head?.window?.title ?? '?'}"）`)
      }
      const idx = Number.isFinite(args.index) && args.index >= 0 && args.index < head.matches.length ? Math.trunc(args.index) : 0
      const m = head.matches[idx]
      const r = rectOf(m)
      if (!r) throw new Error(`uia_locate: 控件 "${m.name}" 没有可用矩形（可能 offscreen）`)
      const span = Math.max(80, Math.min(600, Number.isFinite(args.span) ? Math.trunc(args.span) : 240))
      const rx = r.cx - span
      const ry = r.cy - Math.round(span * 0.66)
      const rw = span * 2
      const rh = Math.round(span * 1.32)
      const dir = mkdtempSync(join(tmpdir(), 'dsh-vision-locate-'))
      const shot = join(dir, 'locate.png')
      const winHwnd = Number.isFinite(head.window?.hwnd)
        ? head.window.hwnd
        : (Number.isFinite(args.hwnd) ? args.hwnd : 0)
      const shotArgs = [
        '-Action', 'shot', '-Out', toWindowsPath(shot),
        '-Rect', `${rx},${ry},${rw},${rh}`,
        '-MarkerX', String(r.cx), '-MarkerY', String(r.cy),
        '-MaxWidth', '900',
      ]
      // 有窗口句柄就走 PrintWindow：截窗口自身内容，即使被别的窗口盖住也能截对
      if (winHwnd) {
        try {
          await runPowerShell(CU_PS1, 30000, [...shotArgs, '-Hwnd', String(winHwnd)])
        } catch {
          // 句柄失效（窗口在枚举之后关掉了）→ 退回屏幕捕获，不让整次调用失败
          await runPowerShell(CU_PS1, 30000, shotArgs)
        }
      } else {
        await runPowerShell(CU_PS1, 30000, shotArgs)
      }
      audit({ tool: 'uia_locate', name: String(args.name), hit: m.name, center: [r.cx, r.cy] })
      const buf = readFileSync(shot)
      try { rmSync(dir, { recursive: true, force: true }) } catch { /* 同上 */ }
      return commitImage(
        buf, 'image/png',
        `uia://${m.type} "${m.name}"`,
        'locate.png',
      )
    },
  ))

  const disposeUiaClick = ctx.tools.register(makeTextTool(
    'uia_click',
    'Click a control identified by name. Tries real UI Automation patterns first — invoke / toggle / select / expand — ' +
    'which do NOT move your mouse; it only falls back to a coordinate click when the control supports no pattern. ' +
    'Returns how it clicked plus a before/after UI fingerprint (foreground window, focused control, interactive count, hash) ' +
    'so you can judge whether the action actually did something. If the fingerprint is unchanged, look again before retrying.',
    {
      type: 'object', additionalProperties: false,
      properties: {
        name: { type: 'string', description: 'Fragment of the control name / AutomationId' },
        window: { type: 'string', description: 'Title fragment of the window. Defaults to the foreground window.' },
        hwnd: { type: 'integer', description: 'Exact window handle (overrides window).' },
        index: { type: 'integer', description: 'Which hit to click when several match (default 0).' },
        max_depth: { type: 'integer', description: 'Search depth (default 5).' },
        dry_run: { type: 'boolean', description: 'Only report what would be clicked; do not click.' },
      },
      required: ['name'],
    },
    async (args) => {
      assertWindowsDesktop()
      const name = String(args.name ?? '')
      if (name === '') throw new Error('uia_click: name 不能为空')
      const dry = args.dry_run === true
      if (!dry) await ensureOverlay()
      const tgt = uiaTargetArgs(args)
      const before = dry ? null : (await runUia('fingerprint', tgt))[0] ?? null
      const extra = [...tgt, '-Name', name, '-MaxDepth', String(Number.isFinite(args.max_depth) ? Math.trunc(args.max_depth) : 5)]
      if (Number.isFinite(args.index) && args.index >= 0) extra.push('-Index', String(Math.trunc(args.index)))
      if (dry) extra.push('-DryRun')
      const rows = await runUia('invoke', extra)
      const res = rows[0] ?? null
      if (!res) return { path: 'uia://click', result: '(no output from uia.ps1)' }
      if (res.ok === false) return { path: 'uia://click', result: `failed: ${res.error}` }
      if (dry) {
        const m = res.matched
        return { path: 'uia://click', result: `[dry-run] would click ${m.type} "${m.name}" @${m.rect?.cx},${m.rect?.cy} (${res.candidates} candidate(s))` }
      }
      await new Promise((r) => setTimeout(r, 380))
      const after = (await runUia('fingerprint', tgt))[0] ?? null
      const changed = Boolean(before && after && before.fingerprint !== after.fingerprint)
      const winAfter = after?.window ?? null
      const focusAfter = after?.focused ?? null
      audit({
        tool: 'uia_click', name, how: res.how, matched: res.matched?.name,
        changed, fpBefore: before?.fingerprint, fpAfter: after?.fingerprint,
      })
      const m = res.matched
      const lines = [
        `clicked: ${m?.type} "${m?.name}" @${m?.rect?.cx},${m?.rect?.cy} via ${res.how}${res.how === 'mouse-click' ? ' (coordinate fallback — the mouse moved)' : ' (no mouse movement)'}`,
      ]
      if (res.toggleState) lines.push(`toggle state now: ${res.toggleState}`)
      if (res.expandState) lines.push(`expand state now: ${res.expandState}`)
      lines.push(
        `ui changed: ${changed ? 'YES' : 'NO'}  fingerprint ${before?.fingerprint ?? '?'} -> ${after?.fingerprint ?? '?'}`,
        `window now: "${winAfter?.title ?? '?'}"` + (focusAfter ? `  focused: ${focusAfter.type} "${focusAfter.name}"` : ''),
      )
      if (!changed && !res.toggleState && !res.expandState) {
        lines.push('→ 指纹未变：这次点击可能没生效，或变化在 UIA 看不到的层面（画布 / 自绘 UI）。重新 view_screen 观察再决定，不要盲目重复点击。')
      }
      return { path: 'uia://click', result: lines.join('\n') }
    },
  ))

  const disposeComputerSequence = ctx.tools.register(makeTextTool(
    'computer_sequence',
    'Run several desktop actions in ONE call, inside one PowerShell process, instead of one model round-trip per action. ' +
    'A single call typically replaces 3-5 separate computer_* calls and saves 30-60 seconds of latency. ' +
    'Syntax: steps joined by "|", each "kind:value". ' +
    'Kinds: click:x,y | dblclick:x,y | move:x,y | type:text (ASCII, VK keystrokes) | key:ctrl+l (combos, comma-separated) | wait:ms | shot:path.png. ' +
    'Example: "click:1163,439|type:deepseek|wait:200|key:enter|wait:2500|shot:C:\\tmp\\after.png"',
    {
      type: 'object', additionalProperties: false,
      properties: {
        seq: { type: 'string', description: 'Steps joined by "|": click:x,y / dblclick:x,y / move:x,y / type:text / key:ctrl+l / wait:ms / shot:path.png' },
        hwnd: { type: 'integer', description: 'Window handle to force to the foreground before running the sequence.' },
      },
      required: ['seq'],
    },
    async (args) => {
      await ensureOverlay()
      const extra = ['-Seq', String(args.seq ?? '')]
      if (Number.isFinite(args.hwnd) && args.hwnd !== 0) extra.push('-ActivateHwnd', String(Math.trunc(args.hwnd)))
      const out = await runCu('seq', extra, 300000)
      audit({ tool: 'computer_sequence', seq: String(args.seq ?? '').slice(0, 300), ok: /^SEQ_OK/.test(out) })
      return { path: 'computer://seq', result: out }
    },
  ))

  // ---------------- /api/dsh-computer-use 路由（client 半边用）----------------
  try {
    const readFlag = (p) => { try { return readFileSync(p, 'utf8').trim() } catch { return '' } };
    const writeFlag = (p, v) => { try { writeFileSync(p, v, 'utf8') } catch {} };
    const json = (res, status, body) => {
      res.writeHead(status, {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        'referrer-policy': 'no-referrer',
      });
      res.end(JSON.stringify(body));
    };
    const loopback = (req) => {
      const a = req.socket.remoteAddress;
      return a === '127.0.0.1' || a === '::1' || a === '::ffff:127.0.0.1';
    };
    const routes = [
      {
        kind: 'exact',
        path: '/api/dsh-computer-use/state',
        handler: async (req, res) => {
          if (!loopback(req)) { json(res, 403, { error: 'forbidden: loopback-only' }); return }
          const active = readFlag(FLAG_ACTIVE);
          const cancel = readFlag(FLAG_CANCEL);
          let mode = 'idle';
          try { mode = JSON.parse(readFlag(STATE_FILE) || '{}').mode || 'idle' } catch {}
          json(res, 200, {
            overlay: Boolean(active),
            pid: active,
            cancel: Boolean(cancel),
            mode,
            toolkit: `${CU_DIR}/cu.ps1 + overlay-v2.ps1`,
          });
        },
      },
      {
        kind: 'exact',
        path: '/api/dsh-computer-use/stop',
        handler: async (req, res) => {
          if (!loopback(req)) { json(res, 403, { error: 'forbidden: loopback-only' }); return }
          if (req.method !== 'POST') { json(res, 405, { error: 'method not allowed' }); return }
          writeFlag(FLAG_CANCEL, 'ui-stop');
          writeFlag(join(HOST_TMP, 'dsh_agent_stop.flag'), 'ui-stop');
          json(res, 200, { ok: true, stopped: true });
        },
      },
    ];
    ctx.effect(() => routes.map((r) => ctx.webServer.register(r)), 'dsh-vision: routes');
  } catch { /* webServer 缺失时跳过 */ }

  ctx.effect(() => () => {
    disposeViewImage?.()
    disposeViewScreen?.()
    disposeGuidance?.()
    disposeComputerStatus?.()
    disposeComputerMove?.()
    disposeComputerClick?.()
    disposeComputerTypeReal?.()
    disposeComputerKey?.()
    disposeComputerOverlay?.()
    disposeComputerSequence?.()
    disposeUiaWindows?.()
    disposeUiaTree?.()
    disposeUiaFind?.()
    disposeUiaLocate?.()
    disposeUiaClick?.()
  }, 'dsh-vision: tools')
}
