param(
  [ValidateSet('start','stop','status')][string]$Action = 'start',
  [int]$MaxSeconds = 0,
  [int]$IdleSeconds = 30,
  [switch]$NoCursorChange,
  [int]$HaloSize = 280,
  [int]$IntervalMs = 16
)
$ErrorActionPreference = 'Stop'
$FlagDir = if ($env:DSH_VISION_FLAG_DIR) { $env:DSH_VISION_FLAG_DIR } else { $env:TEMP }
$BOOTLOG = Join-Path $FlagDir 'ov_boot.log'
function BootLog([string]$m) { try { Add-Content -LiteralPath $BOOTLOG -Value ((Get-Date).ToString('HH:mm:ss') + ' ' + $m) -ErrorAction SilentlyContinue } catch {} }
BootLog ("boot action=" + $Action)
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { BootLog ("console-encoding-skip: " + $_.Exception.Message) }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# ================= C# 动画引擎（热路径全在编译代码里，PowerShell 只敲节拍）=================
Add-Type -Namespace CU -Name Eng -ReferencedAssemblies System.Drawing -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern short GetAsyncKeyState(int v);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetDC(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int ReleaseDC(System.IntPtr h, System.IntPtr dc);
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern System.IntPtr CreateCompatibleDC(System.IntPtr hdc);
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern System.IntPtr SelectObject(System.IntPtr hdc, System.IntPtr o);
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern bool DeleteDC(System.IntPtr hdc);
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern bool DeleteObject(System.IntPtr o);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(System.IntPtr hwnd, System.IntPtr dstDc, ref POINT dst, ref SIZE size, System.IntPtr srcDc, ref POINT src, int key, ref BLENDFUNCTION blend, int flags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetSystemCursor(System.IntPtr hcur, uint id);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)] public static extern System.IntPtr LoadCursorFromFile(string f);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, System.IntPtr c, uint d);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void keybd_event(byte v, byte s, uint f, System.UIntPtr e);
public struct POINT { public int X; public int Y; }
public struct SIZE { public int cx; public int cy; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, Pack=1)]
public struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }

static System.IntPtr _hwnd = System.IntPtr.Zero;
static int _size = 220;
static System.Drawing.Bitmap _bmp;
static System.Drawing.Graphics _g;
static string _mode = "idle";
static int _aR = 59, _aG = 130, _aB = 246;
static int _bR = 147, _bG = 197, _bB = 253;
static int _glow = 85;
static float _rippleT = 0f;
static int[] _keyVks = null;
static int _modeUntil = 0;
static string _autoMode = "idle";
static bool _prevMouse = false;
static float _vis = 0f;
static POINT _lastPos = new POINT();
static int _lastMoveTick = 0;
static bool _visInit = false;
static System.IntPtr _rHwnd = System.IntPtr.Zero;
static System.Drawing.Bitmap _rBmp;
static System.Drawing.Graphics _rG;
static int _rSize = 240;
static int _rX = 0, _rY = 0;
static bool _rShown = false;
static bool _hwndShown = true;
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);

public static void Init(System.IntPtr hwnd, int size) {
  _hwnd = hwnd; _size = size;
  _bmp = new System.Drawing.Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
  _g = System.Drawing.Graphics.FromImage(_bmp);
  _g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
  float cx = _size / 2f, cy = _size / 2f;
  _g.Clear(System.Drawing.Color.Transparent);
  SetMode("idle");
}
public static void SetMode(string m) {
  _mode = m;
  if (m == "typing") { _aR = 96; _aG = 165; _aB = 250; _bR = 191; _bG = 219; _bB = 254; _glow = 96; }
  else if (m == "clicking") { _aR = 59; _aG = 130; _aB = 246; _bR = 147; _bG = 197; _bB = 253; _glow = 118; }
  else { _aR = 59; _aG = 130; _aB = 246; _bR = 147; _bG = 197; _bB = 253; _glow = 85; }
}
public static void Ripple(int x, int y) { _rX = x; _rY = y; _rippleT = 1f; }
public static void Tick() {
  int now = System.Environment.TickCount;
  POINT p; GetCursorPos(out p);
  if (!_visInit) { _lastPos = p; _lastMoveTick = now; _visInit = true; }
  if (p.X != _lastPos.X || p.Y != _lastPos.Y) { _lastPos = p; _lastMoveTick = now; }
  if (_keyVks == null) {
    var list = new System.Collections.Generic.List<int>();
    for (int vk = 0x41; vk <= 0x5A; vk++) list.Add(vk);
    for (int vk = 0x30; vk <= 0x39; vk++) list.Add(vk);
    foreach (int vk in new int[] { 0x20, 0x08, 0x0D, 0x09, 0x10, 0x11, 0x12, 0x14, 0x2E, 0x25, 0x26, 0x27, 0x28, 0xBC, 0xBE, 0xBD, 0x6E, 0x6A, 0x6B, 0x6D, 0x6F, 0xBA, 0xBB, 0xDB, 0xDD, 0xDC }) list.Add(vk);
    _keyVks = list.ToArray();
  }
  // ---- 鼠标按下：点击态 + 在点击位置生成涟漪 ----
  bool mdown = ((GetAsyncKeyState(0x01) & 0x8000) != 0) || ((GetAsyncKeyState(0x02) & 0x8000) != 0);
  if (mdown) {
    if (!_prevMouse) { _rX = p.X; _rY = p.Y; _rippleT = 1f; }
    _modeUntil = now + 360; _autoMode = "clicking";
  }
  _prevMouse = mdown;
  // ---- 键盘按下：输入态 ----
  bool typed = false;
  for (int i = 0; i < _keyVks.Length; i++) { if ((GetAsyncKeyState(_keyVks[i]) & 0x8000) != 0) { typed = true; break; } }
  if (typed) { _modeUntil = now + 800; _autoMode = "typing"; }
  if (now > _modeUntil) _autoMode = "idle";
  if (_autoMode != _mode) SetMode(_autoMode);
  // ---- 涟漪窗口：独立生命周期，钉在点击位置，不受光标移动影响 ----
  if (_rippleT > 0f) {
    if (!_rShown) { ShowWindow(_rHwnd, 4); _rShown = true; }
    RenderRippleWindow();
    _rippleT -= 0.024f;
    if (_rippleT <= 0f) { _rippleT = 0f; if (_rShown) { ShowWindow(_rHwnd, 0); _rShown = false; } }
  } else if (_rShown) { ShowWindow(_rHwnd, 0); _rShown = false; }
  // ---- 光环可见度：模式非 idle 或鼠标刚动过 -> 显示；静置 1s -> 淡出 ----
  bool active = _autoMode != "idle" || (now - _lastMoveTick < 1000);
  _vis += ((active ? 1f : 0f) - _vis) * 0.14f;
  if (_vis < 0.02f) _vis = 0f;
  if (_vis <= 0f) { if (_hwndShown) { _hwndShown = false; ShowWindow(_hwnd, 0); } return; }
  if (!_hwndShown) { _hwndShown = true; ShowWindow(_hwnd, 4); }
  // ---- 渲染光环 ----
  float cx = _size / 2f, cy = _size / 2f;
  _g.Clear(System.Drawing.Color.Transparent);
  using (var gp = new System.Drawing.Drawing2D.GraphicsPath()) {
    gp.AddEllipse(0, 0, _size, _size);
    using (var pg = new System.Drawing.Drawing2D.PathGradientBrush(gp)) {
      pg.CenterPoint = new System.Drawing.PointF(cx, cy);
      pg.CenterColor = System.Drawing.Color.FromArgb((int)(_glow * _vis), _aR, _aG, _aB);
      pg.SurroundColors = new System.Drawing.Color[] { System.Drawing.Color.FromArgb(0, _aR, _aG, _aB) };
      _g.FillPath(pg, gp);
    }
  }
  float pulse = (float)((System.Math.Sin(now * 0.0047) + 1.0) / 2.0);
  float rr = 15f + pulse * 1.6f;
  using (var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb((int)(215 * _vis), _bR, _bG, _bB), 2.0f))
    _g.DrawEllipse(pen, cx - rr, cy - rr, rr * 2, rr * 2);
  if (_mode == "typing") {
    using (var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb((int)(240 * _vis), 255, 255, 255), 2.0f))
      _g.DrawLine(pen, cx, cy - 7f, cx, cy + 7f);
  } else {
    using (var b = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb((int)(242 * _vis), 255, 255, 255)))
      _g.FillEllipse(b, cx - 2.8f, cy - 2.8f, 5.6f, 5.6f);
  }
  PushFrame(p.X - _size / 2, p.Y - _size / 2);
}
static void PushFrame(int x, int y) {
  System.IntPtr sdc = GetDC(System.IntPtr.Zero);
  System.IntPtr mdc = CreateCompatibleDC(sdc);
  System.IntPtr hb = _bmp.GetHbitmap(System.Drawing.Color.FromArgb(0));
  System.IntPtr ob = SelectObject(mdc, hb);
  SIZE sz = new SIZE(); sz.cx = _size; sz.cy = _size;
  POINT src = new POINT(); src.X = 0; src.Y = 0;
  POINT dst = new POINT(); dst.X = x; dst.Y = y;
  BLENDFUNCTION bf = new BLENDFUNCTION(); bf.BlendOp = 0; bf.BlendFlags = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = 1;
  UpdateLayeredWindow(_hwnd, sdc, ref dst, ref sz, mdc, ref src, 0, ref bf, 2);
  SelectObject(mdc, ob); DeleteObject(hb); DeleteDC(mdc); ReleaseDC(System.IntPtr.Zero, sdc);
}
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr h, int i);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int SetWindowLong(System.IntPtr h, int i, int v);
public static int GetWindowLongSafe(System.IntPtr h) { return GetWindowLong(h, -20); }
public static int SetWindowLongSafe(System.IntPtr h, int ex) { return SetWindowLong(h, -20, ex | 0x00080000 | 0x00000020 | 0x08000000 | 0x00000080); }
public static bool PushRaw(System.IntPtr hwnd, System.IntPtr hb, int w, int h, int x, int y) {
  System.IntPtr sdc = GetDC(System.IntPtr.Zero);
  System.IntPtr mdc = CreateCompatibleDC(sdc);
  System.IntPtr ob = SelectObject(mdc, hb);
  SIZE sz = new SIZE(); sz.cx = w; sz.cy = h;
  POINT src = new POINT(); POINT dst = new POINT(); dst.X = x; dst.Y = y;
  BLENDFUNCTION bf = new BLENDFUNCTION(); bf.BlendOp = 0; bf.BlendFlags = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = 1;
  bool ok = UpdateLayeredWindow(hwnd, sdc, ref dst, ref sz, mdc, ref src, 0, ref bf, 2);
  SelectObject(mdc, ob); DeleteDC(mdc); ReleaseDC(System.IntPtr.Zero, sdc);
  return ok;
}
public static void InitRipple(System.IntPtr hwnd, int size) {
  _rHwnd = hwnd; _rSize = size;
  _rBmp = new System.Drawing.Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
  _rG = System.Drawing.Graphics.FromImage(_rBmp);
  _rG.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
}
static void PushBitmapAt(System.IntPtr hwnd, System.Drawing.Bitmap bmp, int x, int y) {
  System.IntPtr hb = bmp.GetHbitmap(System.Drawing.Color.FromArgb(0));
  PushRaw(hwnd, hb, bmp.Width, bmp.Height, x, y);
  DeleteObject(hb);
}
static void RenderRippleWindow() {
  if (_rBmp == null) return;
  _rG.Clear(System.Drawing.Color.Transparent);
  float c = _rSize / 2f;
  float e = 1f - _rippleT;                       // 0 -> 1
  for (int k = 0; k < 3; k++) {
    float ph = e - k * 0.16f;
    if (ph <= 0f) continue;
    if (ph > 1f) ph = 1f;
    float r = 12f + 62f * ph;
    int a = (int)(205 * (1f - ph) * (1f - ph));
    if (a <= 1) continue;
    using (var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb(a, 96, 165, 250), 2.4f - k * 0.5f))
      _rG.DrawEllipse(pen, c - r, c - r, r * 2, r * 2);
  }
  float fr = 3.5f + 2.5f * _rippleT;
  using (var b = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb((int)(200 * _rippleT), 191, 219, 254)))
    _rG.FillEllipse(b, c - fr, c - fr, fr * 2, fr * 2);
  PushBitmapAt(_rHwnd, _rBmp, _rX - _rSize / 2, _rY - _rSize / 2);
}
public static string GetMode() { return _autoMode; }
public static int EscDown() { return (GetAsyncKeyState(0x1B) & 0x8000) != 0 ? 1 : 0; }
'@

function FlagPath([string]$k) { return (Join-Path $FlagDir ("dsh_agent_" + $k + ".flag")) }
function SetFlag([string]$k, [string]$c) { Set-Content -LiteralPath (FlagPath $k) -Value $c -Encoding UTF8 -ErrorAction SilentlyContinue }
function ClearFlag([string]$k) { Remove-Item -LiteralPath (FlagPath $k) -Force -ErrorAction SilentlyContinue }
function RestoreCursor { [CU.Eng]::SystemParametersInfo(0x0057, 0, [System.IntPtr]::Zero, 3) | Out-Null }
function Col([int]$r, [int]$g, [int]$b, [int]$a) { return [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }
function StatePath { return (Join-Path $FlagDir 'dsh_cu_state.json') }

if ($Action -eq 'status') {
  foreach ($k in @('active','cancel','stop')) { $p = FlagPath $k; Write-Output ("FLAG " + $k + " exists=" + (Test-Path -LiteralPath $p)) }
  $sp = StatePath
  if (Test-Path -LiteralPath $sp) { Write-Output ("STATE " + ((Get-Content -LiteralPath $sp -Raw) -replace "`r?`n",' ')) }
  exit 0
}
if ($Action -eq 'stop') { SetFlag 'stop' 'by-stop'; Start-Sleep -Milliseconds 900; RestoreCursor; Write-Output 'STOPPED'; exit 0 }

function MakeWindow([int]$x, [int]$y, [int]$w, [int]$h) {
  $f = New-Object System.Windows.Forms.Form
  $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'
  $f.Bounds = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
  $f.TopMost = $true
  $null = $f.Handle
  $ex = [CU.Eng]::GetWindowLongSafe($f.Handle)
  [CU.Eng]::SetWindowLongSafe($f.Handle, $ex) | Out-Null
  $f.Show()
  return $f
}

# ---- 边框（静态渲染一次）----
function RoundPath([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  if ($r -lt 1) { $r = 1 }
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure(); return $p
}
function Render-Border([int]$w, [int]$h, [bool]$cancelled) {
  $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $main = if ($cancelled) { @(245,158,11) } else { @(59,130,246) }
  $bright = if ($cancelled) { @(253,186,116) } else { @(147,197,253) }
  for ($i = 0; $i -lt 84; $i++) {
    $alpha = [int](38 * [Math]::Exp(-[Math]::Pow($i / 26.0, 2)))
    if ($alpha -le 0) { continue }
    $ins = 9 + $i
    $pen = New-Object System.Drawing.Pen((Col $main[0] $main[1] $main[2] $alpha), 1.0)
    $g.DrawPath($pen, (RoundPath $ins $ins ($w - 2*$ins) ($h - 2*$ins) (30 + $i * 0.15)))
    $pen.Dispose()
  }
  $penA = New-Object System.Drawing.Pen((Col $bright[0] $bright[1] $bright[2] 235), 2.2)
  $g.DrawPath($penA, (RoundPath 8 8 ($w - 16) ($h - 16) 30)); $penA.Dispose()
  $penB = New-Object System.Drawing.Pen((Col $main[0] $main[1] $main[2] 110), 1.0)
  $g.DrawPath($penB, (RoundPath 3 3 ($w - 6) ($h - 6) 32)); $penB.Dispose()
  $g.Dispose(); return $bmp
}
# ---- 徽章（按模式渲染，切换时才重画）----
function Render-Badge([string]$mode, [bool]$cancelled, [string]$fontName) {
  $txt = if ($cancelled) { '已取消' } else { 'DeepSeek Harness 正在操作' }
  $chip = if ($cancelled) { '' } elseif ($mode -eq 'typing') { '输入中' } elseif ($mode -eq 'clicking') { '点击' } elseif ($mode -eq 'moving') { '移动' } else { '' }
  $accent = if ($cancelled) { (Col 245 158 11 255) } elseif ($mode -eq 'typing') { (Col 34 211 238 255) } elseif ($mode -eq 'clicking') { (Col 251 191 36 255) } else { (Col 96 165 250 255) }
  $font = New-Object System.Drawing.Font($fontName, 10.5)
  $fontEsc = New-Object System.Drawing.Font('Segoe UI', 8.5)
  $fontChip = New-Object System.Drawing.Font($fontName, 9)
  $mb = New-Object System.Drawing.Bitmap(1, 1); $mg = [System.Drawing.Graphics]::FromImage($mb)
  $wText = $mg.MeasureString($txt, $font).Width
  $wEsc = $mg.MeasureString('Esc', $fontEsc).Width
  $wChip = if ($chip) { $mg.MeasureString($chip, $fontChip).Width + 18 } else { 0 }
  $wCancel = if (-not $cancelled) { $mg.MeasureString('取消', $font).Width } else { 0 }
  $bw = [int](16 + 9 + 11 + $wText + 18 + $wChip + $(if (-not $cancelled) { 10 + ($wEsc + 18) + 9 + $wCancel } else { 0 }) + 18)
  $bh = 40
  $bmp = New-Object System.Drawing.Bitmap($bw, $bh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $path = RoundPath 1 1 ($bw - 2) ($bh - 2) 19
  $g.FillPath((New-Object System.Drawing.SolidBrush((Col 8 12 24 214))), $path)
  $g.DrawPath((New-Object System.Drawing.Pen((Col ($accent.R) ($accent.G) ($accent.B) 130), 1.2)), $path)
  $cx = 20.5; $cy = $bh / 2.0
  foreach ($i in @(10,8,6,4)) {
    $a = [int](7 * (1 - $i / 10.0) * 1.2); if ($a -le 0) { continue }
    $rr = 3.0 + $i * 0.55
    $g.FillEllipse((New-Object System.Drawing.SolidBrush((Col ($accent.R) ($accent.G) ($accent.B) $a))), ($cx - $rr), ($cy - $rr), ($rr*2), ($rr*2))
  }
  $g.FillEllipse((New-Object System.Drawing.SolidBrush($accent)), ($cx - 3.2), ($cy - 3.2), 6.4, 6.4)
  $brush = New-Object System.Drawing.SolidBrush((Col 233 235 240 255))
  $tx = 36; $ty = ($bh - $font.GetHeight($g)) / 2.0
  $g.DrawString($txt, $font, $brush, $tx, $ty)
  $x2 = $tx + $wText + 18
  if ($chip) {
    $cp = RoundPath $x2 ($bh/2 - 11) $wChip 22 8
    $g.FillPath((New-Object System.Drawing.SolidBrush((Col ($accent.R) ($accent.G) ($accent.B) 46))), $cp)
    $cb = New-Object System.Drawing.SolidBrush($accent)
    $g.DrawString($chip, $fontChip, $cb, ($x2 + 9), ($bh/2 - $fontChip.GetHeight($g)/2))
    $cp.Dispose(); $cb.Dispose()
    $x2 += $wChip + 10
  }
  if (-not $cancelled) {
    $kx = [int]$x2; $kh = 22; $ky = ($bh - $kh) / 2
    $kp = RoundPath $kx $ky ([int]($wEsc + 18)) $kh 6
    $g.FillPath((New-Object System.Drawing.SolidBrush((Col 255 255 255 24))), $kp)
    $g.DrawPath((New-Object System.Drawing.Pen((Col 255 255 255 65), 1.0)), $kp)
    $kb = New-Object System.Drawing.SolidBrush((Col 199 210 254 255))
    $g.DrawString('Esc', $fontEsc, $kb, ($kx + 9), ($bh/2 - $fontEsc.GetHeight($g)/2))
    $kb2 = New-Object System.Drawing.SolidBrush((Col 148 163 184 255))
    $g.DrawString('取消', $font, $kb2, ($kx + $wEsc + 27), $ty)
    $kp.Dispose(); $kb.Dispose(); $kb2.Dispose()
  }
  $brush.Dispose(); $font.Dispose(); $fontEsc.Dispose(); $fontChip.Dispose(); $mg.Dispose(); $mb.Dispose(); $g.Dispose()
  return $bmp
}
function Push-Bitmap($form, $bmp, [int]$x, [int]$y) {
  if ($null -eq $bmp) { return }
  $hb = $bmp.GetHbitmap([System.Drawing.Color]::FromArgb(0))
  try { [CU.Eng]::PushRaw($form.Handle, $hb, $bmp.Width, $bmp.Height, $x, $y) | Out-Null }
  finally { [CU.Eng]::DeleteObject($hb) | Out-Null }
}

# ---------------- 自定义系统光标 ----------------

# ---------------- 蓝色风格光标套装（箭头/I形/手指）----------------
function New-CuCursor([string]$path, [string]$style) {
  $S = 48
  $bmp = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $navy = New-Object System.Drawing.Pen((Col 15 23 42 235), 2.4)
  $navy.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $hotX = 5; $hotY = 3
  if ($style -eq 'ibeam') {
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
      (New-Object System.Drawing.PointF(16, 4)), (New-Object System.Drawing.PointF(32, 44)),
      (Col 255 255 255 255), (Col 147 197 253 255))
    $g.FillRectangle($lg, 21, 8, 6, 32)
    $g.FillRectangle($lg, 15, 6, 18, 4)
    $g.FillRectangle($lg, 15, 38, 18, 4)
    $pen = New-Object System.Drawing.Pen((Col 15 23 42 235), 1.8)
    $g.DrawRectangle($pen, 21, 8, 6, 32)
    $g.DrawRectangle($pen, 15, 6, 18, 4)
    $g.DrawRectangle($pen, 15, 38, 18, 4)
    $lg.Dispose(); $pen.Dispose()
    $hotX = 24; $hotY = 24
  } elseif ($style -eq 'hand') {
    # 手指光标：圆角造型 + 渐变 + 柔和投影（无生硬方框）
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
      (New-Object System.Drawing.PointF(12, 4)), (New-Object System.Drawing.PointF(30, 40)),
      (Col 255 255 255 255), (Col 147 197 253 255))
    $shadow = New-Object System.Drawing.SolidBrush((Col 15 23 42 55))
    $finger = RoundPath 10.5 4.5 8 21 4
    $palm   = RoundPath 9.5 22.5 25 15 6.5
    $thumb  = RoundPath 28.5 17.5 8 13 4
    $sh1 = RoundPath 11.5 5.5 8 21 4
    $sh2 = RoundPath 10.5 23.5 25 15 6.5
    $sh3 = RoundPath 29.5 18.5 8 13 4
    $g.FillPath($shadow, $sh1)
    $g.FillPath($shadow, $sh2)
    $g.FillPath($shadow, $sh3)
    $g.FillPath($lg, $finger)
    $g.FillPath($lg, $palm)
    $g.FillPath($lg, $thumb)
    $sh1.Dispose(); $sh2.Dispose(); $sh3.Dispose()
    $pen = New-Object System.Drawing.Pen((Col 15 23 42 210), 1.7)
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($pen, $finger); $g.DrawPath($pen, $palm); $g.DrawPath($pen, $thumb)
    $hl = New-Object System.Drawing.Pen((Col 255 255 255 120), 1.0)
    $g.DrawLine($hl, 13.5, 7, 13.5, 22)
    $lg.Dispose(); $pen.Dispose(); $hl.Dispose(); $shadow.Dispose()
    $finger.Dispose(); $palm.Dispose(); $thumb.Dispose()
    $hotX = 13; $hotY = 5
  } else {
    $pts = @(
      (New-Object System.Drawing.PointF(5, 3)), (New-Object System.Drawing.PointF(5, 37)),
      (New-Object System.Drawing.PointF(13, 29)), (New-Object System.Drawing.PointF(19, 43)),
      (New-Object System.Drawing.PointF(26, 40)), (New-Object System.Drawing.PointF(20, 26)),
      (New-Object System.Drawing.PointF(31, 26))
    )
    $shadowPts = $pts | ForEach-Object { New-Object System.Drawing.PointF(($_.X + 1.4), ($_.Y + 1.6)) }
    $g.FillPolygon((New-Object System.Drawing.SolidBrush((Col 15 23 42 60))), $shadowPts)
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
      (New-Object System.Drawing.PointF(6, 4)), (New-Object System.Drawing.PointF(28, 42)),
      (Col 255 255 255 255), (Col 147 197 253 255))
    $g.FillPolygon($lg, $pts)
    $g.DrawPolygon($navy, $pts)
    $lg.Dispose()
  }
  $navy.Dispose()
  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([UInt16]0); $bw.Write([UInt16]2); $bw.Write([UInt16]1)
  $xor = $S * $S * 4; $and = [int]($S * $S / 8); $data = 40 + $xor + $and
  $bw.Write([Byte]$S); $bw.Write([Byte]$S); $bw.Write([Byte]0); $bw.Write([Byte]0)
  $bw.Write([UInt16]$hotX); $bw.Write([UInt16]$hotY)
  $bw.Write([UInt32]$data); $bw.Write([UInt32]22)
  $bw.Write([UInt32]40); $bw.Write([Int32]$S); $bw.Write([Int32]($S * 2))
  $bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]0)
  $bw.Write([UInt32]$xor); $bw.Write([Int32]0); $bw.Write([Int32]0); $bw.Write([UInt32]0); $bw.Write([UInt32]0)
  for ($y = $S - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $S; $x++) { $c = $bmp.GetPixel($x, $y); $bw.Write([Byte]$c.B); $bw.Write([Byte]$c.G); $bw.Write([Byte]$c.R); $bw.Write([Byte]$c.A) } }
  $z = New-Object byte[] $and; $bw.Write($z, 0, $and); $bw.Flush()
  [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
  $bw.Dispose(); $ms.Dispose(); $bmp.Dispose()
}

# ---------------- 启动 ----------------
# 安装蓝色风格光标套装（保留原生语境切换：箭头 / I形 / 手指）
ClearFlag 'cancel'; ClearFlag 'stop'
SetFlag 'active' ("pid=" + $PID)
BootLog ("flags written pid=" + $PID)
if (-not $NoCursorChange) {
  try {
    $map = @(
      @{ style = 'arrow'; id = 32512; file = (Join-Path $env:TEMP 'dsh_cu_arrow.cur') },
      @{ style = 'ibeam'; id = 32513; file = (Join-Path $env:TEMP 'dsh_cu_ibeam.cur') },
      @{ style = 'hand';  id = 32649; file = (Join-Path $env:TEMP 'dsh_cu_hand.cur') }
    )
    foreach ($m in $map) {
      New-CuCursor $m.file $m.style
      $hc = [CU.Eng]::LoadCursorFromFile($m.file)
      if ($hc -ne [System.IntPtr]::Zero) { [CU.Eng]::SetSystemCursor($hc, [uint32]$m.id) | Out-Null; BootLog ("cursor installed " + $m.style) }
    }
  } catch { BootLog ("cursor install failed: " + $_.Exception.Message) }
}

$fontName = 'Microsoft YaHei UI'
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen

$borderForm = MakeWindow $vs.X $vs.Y $vs.Width $vs.Height
$badgeBmp = Render-Badge 'idle' $false $fontName
$badgeForm = MakeWindow ([int](($vs.Width - $badgeBmp.Width) / 2 + $vs.X)) ($vs.Y + 16) $badgeBmp.Width $badgeBmp.Height
$haloForm = MakeWindow 0 0 $HaloSize $HaloSize
$rippleForm = MakeWindow 0 0 240 240
$rippleForm.Hide()

$borderBmp = Render-Border $vs.Width $vs.Height $false
Push-Bitmap $borderForm $borderBmp $vs.X $vs.Y
Push-Bitmap $badgeForm $badgeBmp ([int](($vs.Width - $badgeBmp.Width) / 2 + $vs.X)) ($vs.Y + 16)
BootLog 'C# engine ready'
[CU.Eng]::Init($haloForm.Handle, $HaloSize)
[CU.Eng]::InitRipple($rippleForm.Handle, 240)

$script:cancelled = $false
$script:lastMode = 'idle'
$script:lastClickTs = 0
$script:n = 0
$script:startTs = [DateTime]::UtcNow

$tick = New-Object System.Windows.Forms.Timer
$tick.Interval = $IntervalMs
$tick.Add_Tick({
  if ($script:cancelled) { return }
  [CU.Eng]::Tick()
  $script:n++
  if (($script:n % 6) -eq 0) {
    $m = [CU.Eng]::GetMode()
    if ($m -ne $script:lastMode) {
      $script:lastMode = $m
      $nb = Render-Badge $m $false $fontName
      Push-Bitmap $badgeForm $nb ([int](($vs.Width - $nb.Width) / 2 + $vs.X)) ($vs.Y + 16)
      $nb.Dispose()
    }
  }
  if (($script:n % 3) -eq 0) {
    if ([CU.Eng]::EscDown() -eq 1) {
      $script:cancelled = $true
      SetFlag 'cancel' 'esc'
      $cb = Render-Border $vs.Width $vs.Height $true
      Push-Bitmap $borderForm $cb $vs.X $vs.Y; $cb.Dispose()
      $cbb = Render-Badge 'idle' $true $fontName
      Push-Bitmap $badgeForm $cbb ([int](($vs.Width - $cbb.Width) / 2 + $vs.X)) ($vs.Y + 16); $cbb.Dispose()
      $haloForm.Hide()
      Start-Sleep -Milliseconds 2200
      [System.Windows.Forms.Application]::Exit()
      return
    }
    if (Test-Path -LiteralPath (FlagPath 'stop')) { [System.Windows.Forms.Application]::Exit(); return }
    if ($IdleSeconds -gt 0 -and ($script:n % 30) -eq 0) {
      $hb1 = Join-Path $FlagDir 'dsh_agent_heartbeat'
      $hb2 = Join-Path $env:TEMP 'dsh_agent_heartbeat'
      $lastUtc = $script:startTs
      foreach ($hb in @($hb1, $hb2)) {
        if (Test-Path -LiteralPath $hb) {
          $t = (Get-Item -LiteralPath $hb).LastWriteTimeUtc
          if ($t -gt $lastUtc) { $lastUtc = $t }
        }
      }
      if (([DateTime]::UtcNow - $lastUtc).TotalSeconds -gt $IdleSeconds) {
        BootLog ("idle-timeout after " + $IdleSeconds + "s -> exit")
        [System.Windows.Forms.Application]::Exit(); return
      }
    }
    if ($MaxSeconds -gt 0 -and ([DateTime]::UtcNow - $script:startTs).TotalSeconds -gt $MaxSeconds) { [System.Windows.Forms.Application]::Exit(); return }
  }
})
BootLog 'timer starting'
$tick.Start()
BootLog 'entering message loop'
[System.Windows.Forms.Application]::Run()
$tick.Stop()
ClearFlag 'active'
RestoreCursor  # 保险：确保系统光标处于默认状态
Write-Output ("OVERLAY_V2_EXIT cancel=" + $script:cancelled)
