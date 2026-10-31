param(
  [Parameter(Mandatory=$true)][string]$Action,
  [int]$X = -1, [int]$Y = -1,
  [string]$Text = '',
  [int]$Steps = 12,
  [int]$DelayMs = 6,
  [int]$JitterMs = 30,
  [string]$Keys = '',
  [int]$Wheel = 0,
  [string]$Out = '',
  [string]$Rect = '',
  [string]$Window = '',
  [int]$MarkerX = -1, [int]$MarkerY = -1,
  [int]$Grid = 0,
  [int]$MaxWidth = 0,
  [int]$Hwnd = 0,
  [int]$ActivateHwnd = 0,
  [string]$Seq = '',
  [switch]$Force,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
# ---- flag 目录：由插件通过 DSH_VISION_FLAG_DIR 传入（Windows 原生 = %TEMP%，WSL = \\wsl.localhost\<distro>\tmp）----
$FlagDir = if ($env:DSH_VISION_FLAG_DIR) { $env:DSH_VISION_FLAG_DIR } else { $env:TEMP }
# ---- ESC cancel guard: 用户在覆盖层按 Esc 后，所有动作拒动 ----
$cancelFlag = Join-Path $FlagDir 'dsh_agent_cancel.flag'
# ESC 取消只拦"会动桌面"的动作；只读查询（pos/fg/shot/status）必须放行，
# 否则用户按过 Esc 之后连 computer_status 都查不了（实测踩到）。
$HANDS_ACTIONS = @('move','click','dblclick','rclick','type','typehuman','typevk','keys','wheel','seq')
if (($HANDS_ACTIONS -contains $Action) -and (-not $Force)) {
  if (Test-Path -LiteralPath $cancelFlag) {
    Write-Output 'CANCELLED: 用户按下了 Esc，本操作已中止（恢复用 -Action clear-cancel）'
    exit 9
  }
}
if ($DryRun) {
  Write-Output ("DRYRUN action=" + $Action + " x=" + $X + " y=" + $Y + " textLen=" + $Text.Length + " keys=" + $Keys + " rect=" + $Rect + " window=" + $Window)
  exit 0
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not ("CuWin" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CuWin {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("imm32.dll")] public static extern IntPtr ImmGetContext(IntPtr hWnd);
  [DllImport("imm32.dll")] public static extern bool ImmGetConversionStatus(IntPtr hIMC, out int lpfdwConversion, out int lpfdwSentence);
  [DllImport("imm32.dll")] public static extern bool ImmReleaseContext(IntPtr hWnd, IntPtr hIMC);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@
}
Add-Type -Namespace CU -Name W -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, System.UIntPtr e);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
public struct POINT { public int X; public int Y; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public System.UIntPtr dwExtraInfo; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct INPUT { public uint type; public KEYBDINPUT ki; }
public static void Key(byte vk, bool up) { keybd_event(vk, 0, up ? 2u : 0u, System.UIntPtr.Zero); }
public static bool SendChar(char c, bool up) {
  INPUT[] a = new INPUT[1];
  a[0].type = 1;
  a[0].ki.wVk = 0;
  a[0].ki.wScan = (ushort)c;
  a[0].ki.dwFlags = up ? 0x0006u : 0x0004u;
  a[0].ki.time = 0;
  a[0].ki.dwExtraInfo = System.UIntPtr.Zero;
  return SendInput(1, a, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT))) == 1;
}
'@

# ---- 状态发布：驱动覆盖层光标形态（idle/moving/typing/clicking）----
function Set-CuState([string]$mode, [int]$cx = -1, [int]$cy = -1) {
  try {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $click = if ($cx -ge 0) { '{"x":' + $cx + ',"y":' + $cy + ',"t":' + $ts + '}' } else { 'null' }
    $json = '{"mode":"' + $mode + '","ts":' + $ts + ',"click":' + $click + '}'
    Set-Content -LiteralPath (Join-Path $FlagDir 'dsh_cu_state.json') -Value $json -Encoding UTF8 -ErrorAction SilentlyContinue
  } catch { }
}

function Get-Pos { $p = New-Object CU.W+POINT; [CU.W]::GetCursorPos([ref]$p) | Out-Null; return $p }
function Move-Smooth([int]$tx, [int]$ty, [int]$steps, [int]$delay) {
  $p0 = Get-Pos; $x0 = $p0.X; $y0 = $p0.Y
  if ($steps -lt 1) { $steps = 1 }
  for ($i = 1; $i -le $steps; $i++) {
    $nx = [int]($x0 + ($tx - $x0) * $i / $steps)
    $ny = [int]($y0 + ($ty - $y0) * $i / $steps)
    [CU.W]::SetCursorPos($nx, $ny) | Out-Null
    Start-Sleep -Milliseconds $delay
  }
  [CU.W]::SetCursorPos($tx, $ty) | Out-Null
}
$vkmap = @{ 'ctrl'=0x11; 'control'=0x11; 'alt'=0x12; 'shift'=0x10; 'win'=0x5B;
  'enter'=0x0D; 'return'=0x0D; 'tab'=0x09; 'esc'=0x1B; 'escape'=0x1B; 'space'=0x20;
  'backspace'=0x08; 'bs'=0x08; 'delete'=0x2E; 'del'=0x2E; 'insert'=0x2D;
  'up'=0x26; 'down'=0x28; 'left'=0x25; 'right'=0x27; 'home'=0x24; 'end'=0x23;
  'pgup'=0x21; 'pgdn'=0x22; 'f1'=0x70; 'f2'=0x71; 'f3'=0x72; 'f4'=0x73; 'f5'=0x74;
  'f6'=0x75; 'f7'=0x76; 'f8'=0x77; 'f9'=0x78; 'f10'=0x79; 'f11'=0x7A; 'f12'=0x7B }
function Send-Keys([string]$spec) {
  foreach ($combo in $spec -split ',') {
    $parts = @($combo.Trim().ToLower() -split '\+')
    $mods = @(); $main = $null
    foreach ($p in $parts) {
      if ($vkmap.ContainsKey($p)) {
        if ($p -in @('ctrl','control','alt','shift','win')) { $mods += [byte]$vkmap[$p] } else { $main = [byte]$vkmap[$p] }
      } elseif ($p -match '^[a-z]$') { $main = [byte]([byte][char]([char]::ToUpper($p[0]))) }
      elseif ($p -match '^[0-9]$') { $main = [byte](0x30 + [int]$p) }
      else { throw "unknown key: $p" }
    }
    foreach ($m in $mods) { [CU.W]::Key($m, $false); Start-Sleep -Milliseconds 10 }
    if ($main -ne $null) { [CU.W]::Key($main, $false); Start-Sleep -Milliseconds 10; [CU.W]::Key($main, $true); Start-Sleep -Milliseconds 10 }
    foreach ($m in ($mods | Sort-Object -Descending)) { [CU.W]::Key($m, $true); Start-Sleep -Milliseconds 10 }
  }
}
function Get-WindowRect([string]$title) {
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction SilentlyContinue
  try {
    $AE = [System.Windows.Automation.AutomationElement]
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)
    $wins = $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    foreach ($w in $wins) {
      $c = $w.Current
      if ($c.Name -like "*$title*") {
        $r = $c.BoundingRectangle
        if (-not $r.IsEmpty -and -not [double]::IsInfinity($r.X) -and $r.Width -gt 0) {
          return @([int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
        }
      }
    }
  } catch { }
  return $null
}

function Save-Shot([string]$path) {
  # 捕获区域优先级：-Rect > -Window > 全虚拟屏；给了 -Hwnd 则走 PrintWindow（不受遮挡影响）
  $region = $null
  if ($Rect -ne '') {
    $p = $Rect -split ','
    if ($p.Count -eq 4) { $region = @([int]$p[0], [int]$p[1], [int]$p[2], [int]$p[3]) }
  }
  if (-not $region -and $Window -ne '') { $region = Get-WindowRect $Window }

  if ($Hwnd -ne 0) {
    $wr = New-Object CuWin+RECT
    [CuWin]::GetWindowRect([IntPtr]$Hwnd, [ref]$wr) | Out-Null
    $ww = $wr.Right - $wr.Left; $wh = $wr.Bottom - $wr.Top
    if ($ww -le 0 -or $wh -le 0) { throw "invalid window rect for hwnd $Hwnd" }
    $full = New-Object System.Drawing.Bitmap($ww, $wh)
    $gf = [System.Drawing.Graphics]::FromImage($full)
    $hdc = $gf.GetHdc()
    $ok = $false
    try { $ok = [CuWin]::PrintWindow([IntPtr]$Hwnd, $hdc, 2) } catch { }
    if (-not $ok) { try { $ok = [CuWin]::PrintWindow([IntPtr]$Hwnd, $hdc, 0) } catch { } }
    $gf.ReleaseHdc($hdc); $gf.Dispose()
    if (-not $ok) { $full.Dispose(); throw "PrintWindow failed for hwnd $Hwnd" }
    if ($region) {
      $cx = [Math]::Max(0, $region[0] - $wr.Left)
      $cy = [Math]::Max(0, $region[1] - $wr.Top)
      $cw = [Math]::Min($region[2], $ww - $cx)
      $ch = [Math]::Min($region[3], $wh - $cy)
      if ($cw -le 0 -or $ch -le 0) { $full.Dispose(); throw "region outside window" }
      $bmp = $full.Clone((New-Object System.Drawing.Rectangle($cx, $cy, $cw, $ch)), $full.PixelFormat)
      $full.Dispose()
      $rx = $wr.Left + $cx; $ry = $wr.Top + $cy; $rw = $cw; $rh = $ch
    } else {
      $bmp = $full
      $rx = $wr.Left; $ry = $wr.Top; $rw = $ww; $rh = $wh
    }
  } else {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if (-not $region) { $region = @($vs.X, $vs.Y, $vs.Width, $vs.Height) }
    $rx = $region[0]; $ry = $region[1]; $rw = $region[2]; $rh = $region[3]
    if ($rw -le 0 -or $rh -le 0) { throw "invalid capture region" }
    $vx1 = $vs.X; $vy1 = $vs.Y; $vx2 = $vs.X + $vs.Width; $vy2 = $vs.Y + $vs.Height
    $cx1 = [Math]::Max($rx, $vx1); $cy1 = [Math]::Max($ry, $vy1)
    $cx2 = [Math]::Min($rx + $rw, $vx2); $cy2 = [Math]::Min($ry + $rh, $vy2)
    if ($cx2 -le $cx1 -or $cy2 -le $cy1) { throw "capture region outside the desktop" }
    $rx = $cx1; $ry = $cy1; $rw = $cx2 - $cx1; $rh = $cy2 - $cy1
    $bmp = New-Object System.Drawing.Bitmap($rw, $rh)
    $g0 = [System.Drawing.Graphics]::FromImage($bmp)
    $g0.CopyFromScreen((New-Object System.Drawing.Point($rx, $ry)), [System.Drawing.Point]::Empty, (New-Object System.Drawing.Size($rw, $rh)))
    $g0.Dispose()
  }

  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

  # 网格标尺：每 N 像素一条线，边缘标注全局坐标
  if ($Grid -gt 0) {
    $penMin = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 0, 200, 255), 1)
    $penMajor = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(140, 0, 160, 255), 1)
    $font = New-Object System.Drawing.Font('Consolas', 9)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220, 0, 220, 255))
    $step = $Grid
    for ($x = 0; $x -lt $rw; $x += $step) {
      $pen = if ((($rx + $x) % ($step * 5)) -eq 0) { $penMajor } else { $penMin }
      $g.DrawLine($pen, $x, 0, $x, $rh)
      if ($x -ge 46 -and ($x + 34) -lt $rw) { $g.DrawString([string]($rx + $x), $font, $brush, ($x + 3), 2) }
    }
    for ($y = 0; $y -lt $rh; $y += $step) {
      $pen = if ((($ry + $y) % ($step * 5)) -eq 0) { $penMajor } else { $penMin }
      $g.DrawLine($pen, 0, $y, $rw, $y)
      if (($y + 16) -lt $rh) { $g.DrawString([string]($ry + $y), $font, $brush, 3, ($y + 2)) }
    }
    $g.DrawString("region=$rx,$ry ${rw}x${rh} grid=$step", $font, $brush, 3, ($rh - 16))
    $font.Dispose(); $brush.Dispose(); $penMin.Dispose(); $penMajor.Dispose()
  }

  # 目标点标记：十字 + 圆圈
  if ($MarkerX -ge 0 -and $MarkerY -ge 0) {
    $mx = $MarkerX - $rx; $my = $MarkerY - $ry
    if ($mx -ge 0 -and $my -ge 0 -and $mx -lt $rw -and $my -lt $rh) {
      $mp = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(235, 255, 60, 60), 2)
      $g.DrawLine($mp, ($mx - 18), $my, ($mx + 18), $my)
      $g.DrawLine($mp, $mx, ($my - 18), $mx, ($my + 18))
      $g.DrawEllipse($mp, ($mx - 12), ($my - 12), 24, 24)
      $mp.Dispose()
    }
  }

  # 真实光标只在"全屏/全窗口"捕获时画
  if ($Rect -eq '' -and $Window -eq '') {
    $pp = Get-Pos
    $cur = [System.Windows.Forms.Cursor]::Current
    $cur.Draw($g, (New-Object System.Drawing.Rectangle(($pp.X - $rx), ($pp.Y - $ry), $cur.Size.Width, $cur.Size.Height)))
  }

  if ($MaxWidth -gt 0 -and $rw -gt $MaxWidth) {
    $nh = [int]($rh * $MaxWidth / $rw)
    $small = New-Object System.Drawing.Bitmap($MaxWidth, $nh)
    $g2 = [System.Drawing.Graphics]::FromImage($small)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($bmp, 0, 0, $MaxWidth, $nh)
    $g2.Dispose()
    $small.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $small.Dispose()
    $g.Dispose(); $bmp.Dispose()
    return ("$rw x $rh @ $rx,$ry (scaled to $MaxWidth x $nh)")
  }
  $g.Dispose()
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return ("$rw x $rh @ $rx,$ry")
}

# -ActivateHwnd：执行动作前把目标窗口强制提到最前。
# 实测坑：Edge 被别的大窗口遮挡时，屏幕坐标点击会落到遮挡窗口上（z-order 决定点击目标），
# 所以"看得见"（PrintWindow）不等于"点得中"。先置顶再点才可靠。
if ($ActivateHwnd -ne 0) {
  try {
    [CuWin]::SetWindowPos([IntPtr]$ActivateHwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0003) | Out-Null
    [CuWin]::BringWindowToTop([IntPtr]$ActivateHwnd) | Out-Null
    [CuWin]::SetForegroundWindow([IntPtr]$ActivateHwnd) | Out-Null
    Start-Sleep -Milliseconds 280
  } catch { }
}

# ===== 危险目标保护 =====
# 目的：别让自动化键盘事件落进用户正在编辑的消息框。
# 判定必须基于「这次要操作哪个窗口」，而不是「此刻前台是谁」——
# overlay 拉起/收起、用户切窗口都会让前台抖动，按前台判会随机误杀（实测：
# DSH 在前台时 computer_key/computer_sequence 全部 exit 8，而 overlay 抢到前台
# 的瞬间又莫名放行）。规则：
#   · 显式指定了 ActivateHwnd 且它不是宿主进程 → 放行（上面已把它切到前台）；
#   · 只往宿主自己身上注入 → 仍拒绝，并告诉调用方怎么带 hwnd 重试。
if (($HANDS_ACTIONS -contains $Action) -and (-not $Force)) {
  $forbidName = $env:DSH_VISION_FORBID_TARGET
  if ($forbidName) {
    $targetsHost = $false
    if ($ActivateHwnd -ne 0) {
      try {
        $tpid2 = [uint32]0
        [void][CuWin]::GetWindowThreadProcessId([IntPtr]$ActivateHwnd, [ref]$tpid2)
        $tproc2 = if ($tpid2 -ne 0) { Get-Process -Id $tpid2 -ErrorAction SilentlyContinue } else { $null }
        $targetsHost = [bool]($tproc2 -and ($tproc2.ProcessName -like "*$forbidName*"))
      } catch { $targetsHost = $false }
    }
    if ($ActivateHwnd -eq 0 -or $targetsHost) {
      try {
        $fgH2 = [CuWin]::GetForegroundWindow()
        $fpid2 = [uint32]0
        [void][CuWin]::GetWindowThreadProcessId($fgH2, [ref]$fpid2)
        if ($fpid2 -ne 0) {
          $proc2 = Get-Process -Id $fpid2 -ErrorAction SilentlyContinue
          if ($proc2 -and ($proc2.ProcessName -like "*$forbidName*")) {
            $hint = if ($ActivateHwnd -ne 0) { "（指定的 hwnd " + $ActivateHwnd + " 本身就属于宿主进程，换一个目标窗口）" } else { "（先用 uia_windows 取目标窗口 hwnd，再带 hwnd 重试：脚本会先把目标切到前台）" }
            Write-Output ("REFUSED: 前台窗口属于 " + $proc2.ProcessName + "（宿主自身），拒绝注入 —— 键盘事件会落进你正在编辑的消息框。" + $hint + " 确需在当前窗口强推请加 -Force。")
            exit 8
          }
        }
      } catch { Write-Output ("GUARD_SKIP: " + $_.Exception.Message) }
    }
  }
}

switch ($Action) {
  'pos'   { $p = Get-Pos; Write-Output ("POS " + $p.X + "," + $p.Y) }
  'fg'    { $h = [CU.W]::GetForegroundWindow(); $pid2 = 0; [CU.W]::GetWindowThreadProcessId($h, [ref]$pid2) | Out-Null; $pr = Get-Process -Id $pid2 -ErrorAction SilentlyContinue; Write-Output ("FG pid=" + $pid2 + " name=" + $pr.ProcessName + " title=" + $pr.MainWindowTitle) }
  'move'  { Set-CuState 'moving'; Move-Smooth $X $Y $Steps $DelayMs; $p = Get-Pos; Set-CuState 'idle'; Write-Output ("POS " + $p.X + "," + $p.Y) }
  'click' { if ($X -ge 0) { Move-Smooth $X $Y $Steps $DelayMs }; $pp = Get-Pos; Set-CuState 'clicking' $pp.X $pp.Y; [CU.W]::mouse_event(0x0002,0,0,0,[System.UIntPtr]::Zero); Start-Sleep -Milliseconds 35; [CU.W]::mouse_event(0x0004,0,0,0,[System.UIntPtr]::Zero); Start-Sleep -Milliseconds 120; Set-CuState 'idle'; Write-Output 'CLICK' }
  'dblclick' { if ($X -ge 0) { Move-Smooth $X $Y $Steps $DelayMs }; [CU.W]::mouse_event(0x0002,0,0,0,[System.UIntPtr]::Zero); [CU.W]::mouse_event(0x0004,0,0,0,[System.UIntPtr]::Zero); Start-Sleep -Milliseconds 45; [CU.W]::mouse_event(0x0002,0,0,0,[System.UIntPtr]::Zero); [CU.W]::mouse_event(0x0004,0,0,0,[System.UIntPtr]::Zero); Write-Output 'DBLCLICK' }
  'rclick' { if ($X -ge 0) { Move-Smooth $X $Y $Steps $DelayMs }; [CU.W]::mouse_event(0x0008,0,0,0,[System.UIntPtr]::Zero); Start-Sleep -Milliseconds 35; [CU.W]::mouse_event(0x0010,0,0,0,[System.UIntPtr]::Zero); Write-Output 'RCLICK' }
  'type'  {
    # 中文唯一的通用通道：VK 逐键只能打 ASCII，SendChar(KEYEVENTF_UNICODE) 在 Win11 记事本/Chromium
    # 都被静默忽略（实测）。这里走剪贴板，但先保存用户原剪贴板内容，粘完立刻还原。
    Set-CuState 'typing'
    $savedCb = $null
    $hadCb = $false
    try { $savedCb = Get-Clipboard -Raw -ErrorAction Stop; $hadCb = $true } catch { }
    Set-Clipboard -Value $Text
    Start-Sleep -Milliseconds 60
    Send-Keys 'ctrl+v'
    Start-Sleep -Milliseconds 140
    try {
      if ($hadCb -and $null -ne $savedCb) { Set-Clipboard -Value $savedCb } else { Set-Clipboard -Value '' }
    } catch { }
    Start-Sleep -Milliseconds 60
    Set-CuState 'idle'
    Write-Output ("TYPED " + $Text.Length + " chars (clipboard, restored)")
  }
  'typehuman' {
    Set-CuState 'typing'
    $n = 0
    foreach ($ch in $Text.ToCharArray()) {
      if ($ch -eq "`n" -or $ch -eq "`r") { [CU.W]::Key(0x0D, $false); Start-Sleep -Milliseconds 40; [CU.W]::Key(0x0D, $true) }
      else { [CU.W]::SendChar($ch, $false) | Out-Null; Start-Sleep -Milliseconds 15; [CU.W]::SendChar($ch, $true) | Out-Null }
      $d = $DelayMs + (Get-Random -Minimum (-$JitterMs) -Maximum ($JitterMs + 1))
      if ($d -lt 5) { $d = 5 }
      Start-Sleep -Milliseconds $d
      $n++
    }
    Start-Sleep -Milliseconds 100
    Set-CuState 'idle'
    Write-Output ("TYPED_HUMAN " + $n + " chars")
  }
  # ===== seq：一次进程内连续执行多个动作（click / type / key / wait / shot / move）=====
  # 动机：每次 powershell.exe 冷启动约 400ms，且每个动作单独调用还要多一轮模型往返（10-20 秒）。
  # 把"点输入框 → 输入 → 回车 → 截图"合成一次调用，省掉中间轮次。
  # 语法：-Seq "click:1163,439|type:deepseek|key:enter|wait:2500|shot:C:\path\a.png"
  'seq' {
    try {
    Set-CuState 'typing'
    # 文本里想写字面量 | 时用 \| 转义（否则会被当成分步符）
    $seqEsc = $Seq -replace '\\\|', [string][char]1
    $actionList = $seqEsc -split '\|'   # 注意：不能叫 $steps，param 里已有 [int]$Steps
    $results = New-Object System.Collections.ArrayList
    foreach ($raw in $actionList) {
      $st = ([string]$raw).Replace([string][char]1, '|').Trim()
      if ($st -eq '') { continue }
      $k = $st
      $v = ''
      $ci = $st.IndexOf(':')
      if ($ci -ge 0) { $k = $st.Substring(0, $ci); $v = $st.Substring($ci + 1) }
      $k = $k.ToLower()
      switch ($k) {
        'wait' { Start-Sleep -Milliseconds ([int]$v); [void]$results.Add("wait $v") }
        'move' {
          $xy = $v -split ','
          Move-Smooth ([int]($xy[0])) ([int]($xy[1])) 10 6
          [void]$results.Add("move $v")
        }
        'click' {
          $xy = $v -split ','
          Move-Smooth ([int]($xy[0])) ([int]($xy[1])) 10 6
          Set-CuState 'clicking' ([int]($xy[0])) ([int]($xy[1]))
          [CU.W]::mouse_event(0x0002, 0, 0, 0, [System.UIntPtr]::Zero); Start-Sleep -Milliseconds 35
          [CU.W]::mouse_event(0x0004, 0, 0, 0, [System.UIntPtr]::Zero); Start-Sleep -Milliseconds 90
          [void]$results.Add("click $v")
        }
        'dblclick' {
          $xy = $v -split ','
          Move-Smooth ([int]($xy[0])) ([int]($xy[1])) 10 6
          [CU.W]::mouse_event(0x0002, 0, 0, 0, [System.UIntPtr]::Zero)
          [CU.W]::mouse_event(0x0004, 0, 0, 0, [System.UIntPtr]::Zero); Start-Sleep -Milliseconds 45
          [CU.W]::mouse_event(0x0002, 0, 0, 0, [System.UIntPtr]::Zero)
          [CU.W]::mouse_event(0x0004, 0, 0, 0, [System.UIntPtr]::Zero)
          [void]$results.Add("dblclick $v")
        }
        'key' {
          Send-Keys $v
          Start-Sleep -Milliseconds 120
          [void]$results.Add("key $v")
        }
        'type' {
          # 含非 ASCII（中文等）时 VK 打不出来 → 走剪贴板，粘完还原用户原剪贴板
          if ($v -match '[^\x00-\x7F]') {
            $saved2 = $null; $had2 = $false
            try { $saved2 = Get-Clipboard -Raw -ErrorAction Stop; $had2 = $true } catch { }
            Set-Clipboard -Value $v
            Start-Sleep -Milliseconds 60
            Send-Keys 'ctrl+v'
            Start-Sleep -Milliseconds 160
            try { if ($had2 -and $null -ne $saved2) { Set-Clipboard -Value $saved2 } else { Set-Clipboard -Value '' } } catch { }
            [void]$results.Add("type(cjk) $($v.Length) chars")
            continue
          }
          # 纯 ASCII：与 typevk 同一套 VK 映射
          $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
          for ($i = 0; $i -lt 26; $i++) {
            $map[[string][char](0x61 + $i)] = @([byte](0x41 + $i), $false)
            $map[[string][char](0x41 + $i)] = @([byte](0x41 + $i), $true)
          }
          for ($i = 0; $i -lt 10; $i++) { $map[[string][char](0x30 + $i)] = @([byte](0x30 + $i), $false) }
          $alt = @{
            ' ' = @(0x20, $false); '-' = @(0xBD, $false); '_' = @(0xBD, $true)
            '=' = @(0xBB, $false); '+' = @(0xBB, $true); '.' = @(0xBE, $false)
            '/' = @(0xBF, $false); ':' = @(0xBA, $true); '?' = @(0xBF, $true)
            '@' = @(0x32, $true); '#' = @(0x33, $true); '&' = @(0x37, $true)
            '%' = @(0x35, $true); '!' = @(0x31, $true); ',' = @(0xBC, $false)
          }
          $SHIFT2 = [byte]0x10
          $n = 0
          foreach ($ch in $v.ToCharArray()) {
            $kk = [string]$ch
            if ($map.ContainsKey($kk)) { $p2 = $map[$kk] } elseif ($alt.ContainsKey($kk)) { $p2 = $alt[$kk] } else { continue }
            $vk2 = [byte]$p2[0]; $sh2 = [bool]$p2[1]
            if ($sh2) { [CU.W]::Key($SHIFT2, $false); Start-Sleep -Milliseconds 8 }
            [CU.W]::Key($vk2, $false); Start-Sleep -Milliseconds 12; [CU.W]::Key($vk2, $true)
            if ($sh2) { Start-Sleep -Milliseconds 8; [CU.W]::Key($SHIFT2, $true) }
            Start-Sleep -Milliseconds 22
            $n++
          }
          Start-Sleep -Milliseconds 50
          [void]$results.Add("type $n chars")
        }
        'shot' {
          $info2 = Save-Shot $v
          [void]$results.Add("shot $v ($info2)")
        }
        default { [void]$results.Add("skip unknown:$k") }
      }
    }
    Set-CuState 'idle'
    Write-Output ("SEQ_OK " + ($results -join ' | '))
    } catch {
      Write-Output ("SEQ_ERR line=" + $_.InvocationInfo.ScriptLineNumber + " " + $_.Exception.Message)
    }
  }

  'typevk' {
    Set-CuState 'typing'
    # 中文输入法会把字母当拼音、把空格当候选确认键（实测：输入 "a b c" 得到 "啊不错"）。
    # 这里检测前台窗口的 IME 转换模式：中文模式就先单按一次 Shift 切英文，输入完再切回。
    $switchedAscii = $false
    try {
      $fgH = [CuWin]::GetForegroundWindow()
      $imc = [CuWin]::ImmGetContext($fgH)
      if ($imc -ne [IntPtr]::Zero) {
        $conv = 0; $sent = 0
        if ([CuWin]::ImmGetConversionStatus($imc, [ref]$conv, [ref]$sent)) {
          if (($conv -band 1) -ne 0) {
            $sh = [byte]0x10
            [CU.W]::Key($sh, $false); Start-Sleep -Milliseconds 25
            [CU.W]::Key($sh, $true); Start-Sleep -Milliseconds 150
            $switchedAscii = $true
          }
        }
        [CuWin]::ImmReleaseContext($fgH, $imc) | Out-Null
      }
    } catch { }
    $SHIFT = [byte]0x10
    # 实测：固定 26ms 间隔时 100 字符要 5.3 秒、1000 字符要 53 秒 —— 长文本不可用。
    # 按长度自适应：<=40 字符保留拟人节奏；更长的压低按键间隔，优先吞吐。
    if ($Text.Length -gt 120) { $downMs = 2; $gapMs = 4 }
    elseif ($Text.Length -gt 40) { $downMs = 4; $gapMs = 8 }
    else { $downMs = 14; $gapMs = 26 }
    # PowerShell 的 @{} 默认大小写不敏感：'a' 与 'A' 是同一个键，后写的大写映射
    # 会覆盖先写的小写映射 → 所有字母都带 Shift，输入全变大写。这里改用 Ordinal 比较器。
    $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    for ($i = 0; $i -lt 26; $i++) {
      $map[[string][char](0x61 + $i)] = @([byte](0x41 + $i), $false)
      $map[[string][char](0x41 + $i)] = @([byte](0x41 + $i), $true)
    }
    for ($i = 0; $i -lt 10; $i++) { $map[[string][char](0x30 + $i)] = @([byte](0x30 + $i), $false) }
    $alt = @{
      ' ' = @(0x20, $false)
      '!' = @(0x31, $true); '@' = @(0x32, $true); '#' = @(0x33, $true); '$' = @(0x34, $true)
      '%' = @(0x35, $true); '^' = @(0x36, $true); '&' = @(0x37, $true); '*' = @(0x38, $true)
      '(' = @(0x39, $true); ')' = @(0x30, $true)
      '-' = @(0xBD, $false); '_' = @(0xBD, $true); '=' = @(0xBB, $false); '+' = @(0xBB, $true)
      '[' = @(0xDB, $false); '{' = @(0xDB, $true); ']' = @(0xDD, $false); '}' = @(0xDD, $true)
      '\' = @(0xDC, $false); '|' = @(0xDC, $true)
      ';' = @(0xBA, $false); ':' = @(0xBA, $true)
      "'" = @(0xDE, $false); '"' = @(0xDE, $true)
      ',' = @(0xBC, $false); '<' = @(0xBC, $true)
      '.' = @(0xBE, $false); '>' = @(0xBE, $true)
      '/' = @(0xBF, $false); '?' = @(0xBF, $true)
      '`' = @(0xC0, $false); '~' = @(0xC0, $true)
      "`n" = @(0x0D, $false); "`t" = @(0x09, $false)
    }
    $n = 0; $bad = New-Object System.Collections.ArrayList
    foreach ($ch in $Text.ToCharArray()) {
      $k = [string]$ch
      if ($k -eq "`r") { continue }
      if ($map.ContainsKey($k)) { $v = $map[$k] } elseif ($alt.ContainsKey($k)) { $v = $alt[$k] } else { [void]$bad.Add($k); continue }
      $vk = [byte]$v[0]; $sh = [bool]$v[1]
      if ($sh) { [CU.W]::Key($SHIFT, $false); Start-Sleep -Milliseconds 8 }
      [CU.W]::Key($vk, $false); Start-Sleep -Milliseconds $downMs; [CU.W]::Key($vk, $true)
      if ($sh) { Start-Sleep -Milliseconds 8; [CU.W]::Key($SHIFT, $true) }
      Start-Sleep -Milliseconds $gapMs
      $n++
    }
    Start-Sleep -Milliseconds 60
    Set-CuState 'idle'
    if ($switchedAscii) {
      $sh = [byte]0x10
      [CU.W]::Key($sh, $false); Start-Sleep -Milliseconds 25
      [CU.W]::Key($sh, $true); Start-Sleep -Milliseconds 80
    }
    if ($bad.Count -gt 0) {
      [Console]::Error.WriteLine('VK_UNSUPPORTED non-ASCII: ' + ($bad -join '') + ' >>> 中文/非 ASCII 请走输入法路线: computer_key 发拼音字母, 再 computer_key space/数字键 上屏')
      Write-Output ('VK_PARTIAL ' + $n + ' chars')
      exit 2
    }
    Write-Output ('VK_TYPED ' + $n + ' chars')
  }
  # uiatype：用 UI Automation 的 ValuePattern 直接写值，绕开键盘布局与输入法。
  # 中文输入法会把 ASCII 字母当拼音（a→啊）、把空格当候选确认键，逐键注入无法保证原样；
  # 对支持 ValuePattern 的编辑控件（记事本正文、浏览器地址栏、各类搜索框）这一路最可靠。
  # 注意语义差异：SetValue 是整体替换，不是追加。
  'uiatype' {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction SilentlyContinue
    $AE = [System.Windows.Automation.AutomationElement]
    try {
      $fe = $AE::FocusedElement
    } catch { $fe = $null }
    if (-not $fe) { Write-Output 'UIA_NO_FOCUS'; exit 0 }
    try {
      $vp = $fe.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
      $vp.SetValue($Text)
      $t = $fe.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
      Write-Output ("UIA_SETVALUE " + $Text.Length + " chars into " + $t + " [" + $fe.Current.Name + "]")
    } catch {
      Write-Output ('UIA_SETVALUE_UNSUPPORTED ' + $_.Exception.Message)
    }
  }
  'keys'  { Set-CuState 'typing'; Send-Keys $Keys; Start-Sleep -Milliseconds 90; Set-CuState 'idle'; Write-Output ("KEYS " + $Keys) }
  'wheel' { [CU.W]::mouse_event(0x0800,0,0,$Wheel,[System.UIntPtr]::Zero); Write-Output ("WHEEL " + $Wheel) }
  'shot'  { $info = Save-Shot $Out; $mode = if ($Hwnd -ne 0) { 'printwindow' } else { 'screen' }; Write-Output ("SHOT " + $Out + " " + $info + " mode=" + $mode) }
  # status：一次进程内取齐 前台窗口 + 光标 + 覆盖层旗标 + 交互状态。
  # 之前 index.js 要分别起两次进程（fg 一次、pos 一次），每次约 450ms。
  'status' {
    $pp = Get-Pos
    $fgH3 = [CuWin]::GetForegroundWindow()
    $fpid3 = [uint32]0
    [void][CuWin]::GetWindowThreadProcessId($fgH3, [ref]$fpid3)
    $pname = ''
    $ptitle = ''
    try {
      $proc3 = Get-Process -Id $fpid3 -ErrorAction Stop
      $pname = $proc3.ProcessName
      $ptitle = $proc3.MainWindowTitle
    } catch { }
    $actVal = ''
    $actPath = Join-Path $FlagDir 'dsh_agent_active.flag'
    if (Test-Path -LiteralPath $actPath) { try { $actVal = ([string](Get-Content -LiteralPath $actPath -Raw)).Trim() } catch { } }
    $cclVal = ''
    $cclPath = Join-Path $FlagDir 'dsh_agent_cancel.flag'
    if (Test-Path -LiteralPath $cclPath) { try { $cclVal = ([string](Get-Content -LiteralPath $cclPath -Raw)).Trim() } catch { } }
    $stVal = ''
    $stPath = Join-Path $FlagDir 'dsh_cu_state.json'
    if (Test-Path -LiteralPath $stPath) { try { $stVal = ([string](Get-Content -LiteralPath $stPath -Raw)).Trim() } catch { } }
    $o = [ordered]@{
      ok        = $true
      fgPid     = [int]$fpid3
      fgName    = [string]$pname
      fgTitle   = [string]$ptitle
      cursorX   = [int]$pp.X
      cursorY   = [int]$pp.Y
      overlayPid = [string]$actVal
      cancel    = [string]$cclVal
      mode      = [string]$stVal
    }
    [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress -Depth 4))
  }

  'clear-cancel' {
    Remove-Item -LiteralPath $cancelFlag -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:TEMP 'dsh_agent_cancel.flag') -Force -ErrorAction SilentlyContinue
    Write-Output 'CANCEL_FLAG_CLEARED'
  }
  default { Write-Output ("UNKNOWN ACTION " + $Action); exit 1 }
}
