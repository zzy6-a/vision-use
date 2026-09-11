# DSH Computer Use · dsh-vision

English | [中文](README.md)

> Let the DeepSeek Harness agent **actually see your screen and operate the Windows desktop** — with a Codex-style blue overlay (press **Esc** to abort at any time).

[![Download](https://img.shields.io/badge/Download-latest-2e7d32?style=flat&logo=github&logoColor=white)](https://github.com/zzy6-a/dsh-vision/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![dsh-plugin](https://img.shields.io/badge/topic-dsh--plugin-2f6fed)](https://github.com/topics/dsh-plugin)

---

## What it does

| Capability | Tool | Description |
|---|---|---|
| 👁 **See** | `view_screen` | Capture the whole Windows screen → straight into the model's vision channel (real pixels, not OCR) |
| 👁 **See** | `view_image` | Push any image file (Linux or Windows path) into the vision channel |
| 🖱 **Act** | `computer_move` | Glide the cursor smoothly to (x, y) |
| 🖱 **Act** | `computer_click` | Left / right / double click with a click ripple |
| ⌨️ **Act** | `computer_type` | Type text (automatically picks clipboard for Chromium, SendInput for WinUI) |
| ⌨️ **Act** | `computer_key` | Key combinations (`ctrl+t`, `enter`, `alt+f4`, …) |
| 🎛 **Control** | `computer_overlay` | Start / stop / status the overlay (configurable idle auto-close) |
| 📊 **Control** | `computer_status` | Overlay state / Esc flag / current mode / cursor position |

### Visual feedback (Codex style)

```
┌───────────────────────────────────────────────┐
│  ╔═════════════════════════════════════════╗  │ ← soft blue border (per-pixel alpha)
│  ║  ● DeepSeek Harness is operating  [Esc]  ║  │ ← top status badge
│  ║                                         ║  │
│  ║         typing → blue ring + caret       ║  │
│  ║         click  → 0.7s ripple (pinned)    ║  │
│  ║         move   → ring follows; fades 1s  ║  │
│  ╚═════════════════════════════════════════╝  │
└───────────────────────────────────────────────┘
```

- **One cursor set** (arrow / I-beam / hand) in a unified blue-and-white gradient, while **keeping Windows' native context switching**
- **Esc abort**: the keypress writes a cancel flag → the overlay exits → every subsequent action is rejected
- **Idle auto-close**: the overlay packs up after 30 seconds without a tool call (`idle_seconds`, 0 = never)
- **Status pill under the composer**: colored dot + `CU idle/move/type/click` + a Stop button

---

## Install

### Option 1: GitHub Release (recommended)

```bash
dsh plugin --profile web add https://github.com/zzy6-a/dsh-vision/releases/download/v0.1.0/dsh-vision-0.1.0.tgz
```

### Option 2: git source

```bash
dsh plugin --profile web add github:zzy6-a/dsh-vision
```

After installing, **restart DSH** (the `client.js` half registers at boot). Refresh the browser and the status pill appears below the composer.

---

## Quick start

Just tell the agent:

> Take a look at my screen

> Search for the DeepSeek website in Bing and open it

> Open Notepad and type something

The agent will automatically: start the overlay → `view_screen` to look → `computer_*` to act → look again to verify. You can press **Esc** to stop it at any moment.

---

## Requirements

| Item | Requirement |
|---|---|
| Host | **Windows + WSL2** (the agent runs in WSL and drives the Windows desktop) |
| Absolute-path interop | WSL interop enabled (`/proc/sys/fs/binfmt_misc/WSLInterop` = enabled) |
| Windows side | PowerShell 5.1 (built in) + .NET Framework (System.Drawing/WinForms) |
| DSH | `>= 0.1.5-rc.1` |
| Node | The plugin itself has zero runtime dependencies (pure ESM + PowerShell child processes) |

---

## Architecture

```
dsh-vision/
├── lib/index.js        host half: 8 tools + 2 API routes + systemPrompt capability declaration
├── lib/client.js       browser half: composer-dock status pill
├── cordis.patch.yml    bundle layer: inserts the plugin row into the profile tree
├── dsh.plugin.json     plugin manifest (for dsh-market / the plugin manager UI)
└── scripts/            Windows-side toolkit (self-contained, shipped with the package)
    ├── cu.ps1          mouse/keyboard executor + Esc sentinel
    ├── overlay-v2.ps1  overlay: border / badge / ring / ripple + C# 60fps animation engine
    ├── wocr.ps1        Windows native OCR (zero-API-cost fallback, optional)
    └── TOOLKIT.md      toolkit documentation + 10 field-tested rules
```

**Vision**: images are returned as `content: [{type:'image', attachment}]`; the host's `collectImageRefs()` recursively collects them and sends them with the next request — this is DSH's official image channel, so **screenshots count as normal model vision tokens** (on the DeepSeek official route, roughly 369 tokens per image, capped at 384).

**Animation**: the overlay uses `UpdateLayeredWindow` for true per-pixel alpha glow; the hot path runs entirely in compiled C# (PowerShell only keeps the beat), at about 8.8% of a single core.

---

## Configuration

| Parameter | Default | Description |
|---|---|---|
| `computer_overlay start idle_seconds` | `30` | Seconds of inactivity before the overlay closes automatically (0 = never) |
| `-MaxSeconds` | `0` | Maximum overlay lifetime (0 = unlimited) |
| `-NoCursorChange` | off | Do not install the blue cursor set (keep the system default) |

Privacy note: screenshots enter the current session context as image attachments (equivalent to pasting an image manually). If you do not want them to reach the model, use `scripts/wocr.ps1` from this repo for **local OCR** (zero API cost, text only).

---

## Billing & privacy

- **The plugin itself makes zero network requests**: it calls no API; it only stores screenshots in the local attachment store and hands the image blocks to the host
- Images are ultimately **sent to the model route selected for the current session** (DSH's model adapter performs the request)
- **It fully follows the model you choose**: the plugin does not choose or change routes; screenshots always go to **the model selected in your model picker**
  (pick opencode-go and it goes to opencode-go; pick the official route and it goes to the official route)
- **Vision-capability check**: if the selected model does not declare image-input support, `view_screen` / `view_image` fail with a clear error instead of letting the request die halfway
- On the official route, vision billing is about **369 tokens per image** (DSH caps at 384); self-hosted / subscription routes follow their own terms
- If you do not want screenshots to reach the model, use `scripts/wocr.ps1` (Windows local OCR, **zero API cost**, text only)

## Known limitations

- **Chromium ignores `KEYEVENTF_UNICODE` injection**: typing into Edge/Chrome uses clipboard mode (`computer_type`'s `auto` already handles this)
- **WinUI (Notepad, etc.) does not accept injected Ctrl combinations**: `computer_key` may not work in those apps
- **UIA coordinates are unreliable in custom-drawn UIs** (Edge tab bar, Windows 11 Notepad tabs return ∞ or wrong offsets): use `view_screen` to locate targets visually first
- **Software with its own drawn cursor** (games, some Electron apps) cannot be overridden by the system-level cursor replacement

---

## Related projects

- [dsh-upgrade-guard](https://github.com/zzy6-a/dsh-upgrade-guard) — DSH upgrade compatibility guard (companion plugin by the same author)

## Contributors

- [zzy6-a](https://github.com/zzy6-a) — author
- DeepSeek V4.1 — architecture, implementation, testing, and release workflow

## License

[MIT](LICENSE)
