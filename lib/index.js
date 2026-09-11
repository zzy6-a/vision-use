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
import { readFileSync, writeFileSync, mkdtempSync, existsSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
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

/** Convert a Linux /tmp path into a UNC path Windows PowerShell can write to. */
function toUnc(linuxPath) {
  const distro = process.env.WSL_DISTRO_NAME || 'Ubuntu'
  return `\\\\wsl.localhost\\${distro}${linuxPath.replace(/\//g, '\\')}`
}

/** Run a PowerShell script file, resolving the interpreter with a fallback. */
function runPowerShell(scriptPath, timeoutMs, extraArgs = []) {
  const candidates = [
    'powershell.exe',
    '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
  ]
  return new Promise((resolve, reject) => {
    const attempt = (index) => {
      if (index >= candidates.length) { reject(new Error('cannot locate powershell.exe')); return }
      execFile(
        candidates[index],
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, ...extraArgs],
        { timeout: timeoutMs, windowsHide: true },
        (error, stdout, stderr) => {
          if (error && error.code === 'ENOENT') { attempt(index + 1); return }
          if (error) { reject(new Error(`${error.message}${stderr ? ` | ${String(stderr).trim()}` : ''}`)); return }
          resolve(String(stdout))
        },
      )
    }
    attempt(0)
  })
}


/** 面向所有 agent 的能力宣告：本机已装 computer-use 工具链。 */
const COMPUTER_USE_GUIDANCE =
  '本机（WSL host = Windows）已装 DSH Computer-Use 工具链，任何对话可用：\n' +
  '• 看：view_screen（截 Windows 桌面直接进视觉通道）、view_image（读图片文件进视觉通道）；兜底 OCR 脚本 ~/dsh-computer-use/wocr.ps1。\n' +
  '• 动：~/dsh-computer-use/cu.ps1（move/click/type/typehuman/keys/wheel/shot，经 powershell.exe -File 调用）；详细用法见 ~/dsh-computer-use/README.md。\n' +
  '• 特效+中止：agentoverlay.ps1 -Action start 会显示蓝框/徽章/蓝光标，并监听 ESC；用户按 ESC 会写取消标志，cu.ps1 之后所有动作拒动 —— 此时应停下询问用户。\n' +
  '• 铁律：先 view_screen 肉眼定位再点（截图坐标×比例=真实坐标）、点完立刻再看验证、绝不复用缓存坐标、自绘 UI（Edge 标签栏/记事本标签页）的 UIA 坐标不可信（可能 ∞ 或错位）。\n' +
  '• 输入通道选择：Chromium 用 UIA ValuePattern.SetValue（推荐）或剪贴板；WinUI（记事本）用 cu.ps1 typehuman（SendInput Unicode）；Chromium 会忽略 KEYEVENTF_UNICODE 注入。'

export function apply(ctx) {
  const attachments = ctx.attachments

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
      const drive = /^([A-Za-z]):[\\/](.*)$/.exec(raw)
      if (drive) local = `/mnt/${drive[1].toLowerCase()}/${drive[2].replace(/\\/g, '/')}`
      const buf = readFileSync(local)
      const mediaType = sniffMediaType(buf) ?? MEDIA_BY_EXT[extname(local).toLowerCase()]
      if (!mediaType) throw new Error(`not a supported image (PNG/JPEG/WebP/GIF): ${raw}`)
      return commitImage(buf, mediaType, raw, basename(local))
    },
  ))

  const disposeViewScreen = ctx.tools.register(makeTool(
    'view_screen',
    'Capture the Windows desktop (WSL host) and attach the screenshot so you can see the screen. ' +
    'Use it to look at the user desktop, verify GUI automation results, or read on-screen state. ' +
    'The screenshot is captured at native resolution and downscaled to max_width (default 1600).',
    {
      type: 'object',
      additionalProperties: false,
      properties: {
        max_width: { type: 'integer', description: 'Maximum width of the attached screenshot (default 1600).' },
        delay_ms: { type: 'integer', description: 'Optional delay before capture, milliseconds (default 0).' },
      },
      required: [],
    },
    async (args, exec) => {
      await assertSelectedModelSupportsVision(ctx, exec)
      const maxWidth = Number.isFinite(args.max_width)
        ? Math.max(320, Math.min(3840, Math.trunc(args.max_width)))
        : 1600
      const delay = Number.isFinite(args.delay_ms) ? Math.max(0, Math.min(10000, Math.trunc(args.delay_ms))) : 0
      const dir = mkdtempSync(join(tmpdir(), 'dsh-vision-'))
      const shot = join(dir, 'screen.png')
      const scriptPath = join(dir, 'capture.ps1')
      const script = [
        'Add-Type -AssemblyName System.Windows.Forms,System.Drawing',
        '$b = [System.Windows.Forms.SystemInformation]::VirtualScreen',
        '$bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)',
        '[System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)',
        `$w = ${maxWidth}`,
        `$out = "${toUnc(shot)}"`,
        'if ($b.Width -gt $w) {',
        '  $h = [int]($b.Height * $w / $b.Width)',
        '  $s = New-Object System.Drawing.Bitmap($w, $h)',
        '  $g = [System.Drawing.Graphics]::FromImage($s)',
        '  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic',
        '  $g.DrawImage($bmp, 0, 0, $w, $h)',
        '  $s.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)',
        '  $g.Dispose(); $s.Dispose()',
        '} else { $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png) }',
        '$bmp.Dispose()',
        'Write-Output ("CAPTURED " + $out)',
      ].join('\n')
      writeFileSync(scriptPath, '\ufeff' + script, 'utf8')
      if (delay > 0) await new Promise((r) => setTimeout(r, delay))
      await runPowerShell(scriptPath, 20000)
      const buf = readFileSync(shot)
      return commitImage(buf, 'image/png', `screen://desktop (${maxWidth}px max)`, 'screen.png')
    },
  ))

  // ======================= 计算机操作工具族（hands）=======================
  const WSL_DISTRO = process.env.WSL_DISTRO_NAME || 'Ubuntu'
  const HERE = dirname(fileURLToPath(import.meta.url))
  const BUNDLED = join(HERE, '..', 'scripts')
  const CU_DIR = existsSync(join(BUNDLED, 'cu.ps1')) ? BUNDLED : '/home/zzy6/dsh-computer-use'
  const toUnc = (p) => `\\\\wsl.localhost\\${WSL_DISTRO}${p.replace(/\//g, '\\')}`
  const CU_PS1 = toUnc(`${CU_DIR}/cu.ps1`)
  const OVERLAY_PS1 = toUnc(`${CU_DIR}/overlay-v2.ps1`)
  const FLAG_ACTIVE = '/tmp/dsh_agent_active.flag'
  const FLAG_CANCEL = '/tmp/dsh_agent_cancel.flag'
  const STATE_FILE = '/tmp/dsh_cu_state.json'

  const overlayRunning = () => existsSync(FLAG_ACTIVE)
  const cancelled = () => existsSync(FLAG_CANCEL)

  // ===== 任务级保活 =====
  // 覆盖层不应在 agent 还在思考/执行其他工具时自动消失。
  // 每次 hands 操作会获得一个 20 分钟的"工作租约"；agent 的 session 事件会持续续约，
  // turn 结束后给 4 秒余辉再收工。租约到期仍无人续约时才兜底关闭。
  const KEEPALIVE_MS = 20 * 60 * 1000
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

  function startOverlay(idleSeconds = 30) {
    armOverlay()
    const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', OVERLAY_PS1, '-Action', 'start']
    if (Number.isFinite(idleSeconds)) args.push('-IdleSeconds', String(Math.max(0, Math.trunc(idleSeconds))))
    const child = spawn('powershell.exe', args, { detached: true, stdio: 'ignore', windowsHide: true })
    child.unref()
  }

  /** 确保覆盖层在跑（ESC 中止哨兵 + 特效）；被 ESC 取消时直接抛错拒动。 */
  // 强制开启：hands 操作永远不允许绕过覆盖层（用户必须能看到电脑正在被操作）。
  async function ensureOverlay() {
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
    try { writeFileSync('/tmp/dsh_agent_heartbeat', stamp) } catch {}
    try { writeFileSync(`/mnt/c/Users/${process.env.USER || '19827'}/AppData/Local/Temp/dsh_agent_heartbeat`, stamp) } catch {}
  }

  async function runCu(action, extra = [], timeoutMs = 120000) {
    touchHeartbeat()
    return runPowerShell(CU_PS1, timeoutMs, ['-Action', action, ...extra])
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
      let active = ''
      let cancel = ''
      let state = ''
      try { active = readFileSync(FLAG_ACTIVE, 'utf8').trim() } catch {}
      try { cancel = readFileSync(FLAG_CANCEL, 'utf8').trim() } catch {}
      try { state = readFileSync(STATE_FILE, 'utf8').trim() } catch {}
      const fg = await runCu('fg', [], 30000).catch((e) => `error: ${e.message}`)
      const pos = await runCu('pos', [], 30000).catch((e) => `error: ${e.message}`)
      return {
        path: 'computer://status',
        overlay: active ? `running (${active})` : 'stopped',
        escCancel: cancel ? `SET (${cancel})` : 'clear',
        mode: state || 'idle',
        foreground: fg,
        cursor: pos,
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
      },
      required: [],
    },
    async (args) => {
      await ensureOverlay()
      const action = args.button === 'right' ? 'rclick' : args.button === 'double' ? 'dblclick' : 'click'
      const extra = []
      if (Number.isFinite(args.x) && Number.isFinite(args.y)) extra.push('-X', S(Math.trunc(args.x)), '-Y', S(Math.trunc(args.y)), '-Steps', '12', '-DelayMs', '6')
      const out = await runCu(action, extra)
      return { path: 'computer://click', result: out }
    },
  ))

  const disposeComputerTypeReal = ctx.tools.register(makeTextTool(
    'computer_type',
    'Type text into the focused window on Windows. method: auto (detects Chromium vs WinUI; default), clipboard (Ctrl+V, works in Edge/Chrome), sendinput (per-character Unicode, works in WinUI/Notepad). Uses no clipboard when method=sendinput.',
    {
      type: 'object', additionalProperties: false,
      properties: {
        text: { type: 'string', description: 'Text to type (Unicode OK).' },
        method: { type: 'string', description: 'auto (default) | clipboard | sendinput' },
      },
      required: ['text'],
    },
    async (args) => {
      await ensureOverlay()
      let method = args.method ?? 'auto'
      if (method === 'auto') {
        let fg = ''
        try { fg = await runCu('fg', [], 30000) } catch {}
        method = /msedge|chrome|brave|firefox/i.test(fg) ? 'clipboard' : 'sendinput'
      }
      const action = method === 'sendinput' ? 'typehuman' : 'type'
      const extra = ['-Text', S(args.text)]
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
      },
      required: ['keys'],
    },
    async (args) => {
      await ensureOverlay()
      const out = await runCu('keys', ['-Keys', S(args.keys)])
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
        idle_seconds: { type: 'integer', description: '空闲多少秒后自动关闭覆盖层（默认 30，0=不自动关）' },
      },
      required: ['action'],
    },
    async (args) => {
      const action = String(args.action || 'status')
      if (action === 'start') {
        try { rmSync(FLAG_CANCEL, { force: true }) } catch {}
        startOverlay(args.idle_seconds ?? 30)
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
          writeFlag('/tmp/dsh_agent_stop.flag', 'ui-stop');
          try {
            const distro = process.env.WSL_DISTRO_NAME || 'Ubuntu';
            writeFileSync(`/mnt/c/Users/${process.env.USER || '19827'}/AppData/Local/Temp/dsh_agent_cancel.flag`, 'ui-stop');
          } catch {}
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
  }, 'dsh-vision: tools')
}
