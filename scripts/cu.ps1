param(
  [Parameter(Mandatory=$true)][string]$Action,
  [int]$X = -1, [int]$Y = -1,
  [string]$Text = '',
  [int]$Steps = 12,
  [int]$DelayMs = 6,
  [int]$JitterMs = 30,
  [string]$Keys = '',
  [int]$Wheel = 0,
  [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
# ---- flag 目录：由插件通过 DSH_VISION_FLAG_DIR 传入（Windows 原生 = %TEMP%，WSL = \\wsl.localhost\<distro>\tmp）----
$FlagDir = if ($env:DSH_VISION_FLAG_DIR) { $env:DSH_VISION_FLAG_DIR } else { $env:TEMP }
# ---- ESC cancel guard: 用户在覆盖层按 Esc 后，所有动作拒动 ----
$cancelFlag = Join-Path $FlagDir 'dsh_agent_cancel.flag'
if ($Action -ne 'clear-cancel') {
  if (Test-Path -LiteralPath $cancelFlag) {
    Write-Output 'CANCELLED: 用户按下了 Esc，本操作已中止（恢复用 -Action clear-cancel）'
    exit 9
  }
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
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
function Save-Shot([string]$path) {
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size)
  $p = Get-Pos
  $cur = [System.Windows.Forms.Cursor]::Current
  $cur.Draw($g, (New-Object System.Drawing.Rectangle(($p.X - $vs.X), ($p.Y - $vs.Y), $cur.Size.Width, $cur.Size.Height)))
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}
switch ($Action) {
  'pos'   { $p = Get-Pos; Write-Output ("POS " + $p.X + "," + $p.Y) }
  'fg'    { $h = [CU.W]::GetForegroundWindow(); $pid2 = 0; [CU.W]::GetWindowThreadProcessId($h, [ref]$pid2) | Out-Null; $pr = Get-Process -Id $pid2 -ErrorAction SilentlyContinue; Write-Output ("FG pid=" + $pid2 + " name=" + $pr.ProcessName + " title=" + $pr.MainWindowTitle) }
  'move'  { Set-CuState 'moving'; Move-Smooth $X $Y $Steps $DelayMs; $p = Get-Pos; Set-CuState 'idle'; Write-Output ("POS " + $p.X + "," + $p.Y) }
  'click' { if ($X -ge 0) { Move-Smooth $X $Y $Steps $DelayMs }; $pp = Get-Pos; Set-CuState 'clicking' $pp.X $pp.Y; [CU.W]::mouse_event(0x0002,0,0,0,[System.UIntPtr]::Zero); Start-Sleep -Milliseconds 35; [CU.W]::mouse_event(0x0004,0,0,0,[System.UIntPtr]::Zero); Start-Sleep -Milliseconds 120; Set-CuState 'idle'; Write-Output 'CLICK' }
  'dblclick' { if ($X -ge 0) { Move-Smooth $X $Y $Steps $DelayMs }; [CU.W]::mouse_event(0x0002,0,0,0,[System.UIntPtr]::Zero); [CU.W]::mouse_event(0x0004,0,0,0,[System.UIntPtr]::Zero); Start-Sleep -Milliseconds 45; [CU.W]::mouse_event(0x0002,0,0,0,[System.UIntPtr]::Zero); [CU.W]::mouse_event(0x0004,0,0,0,[System.UIntPtr]::Zero); Write-Output 'DBLCLICK' }
  'rclick' { if ($X -ge 0) { Move-Smooth $X $Y $Steps $DelayMs }; [CU.W]::mouse_event(0x0008,0,0,0,[System.UIntPtr]::Zero); Start-Sleep -Milliseconds 35; [CU.W]::mouse_event(0x0010,0,0,0,[System.UIntPtr]::Zero); Write-Output 'RCLICK' }
  'type'  { Set-CuState 'typing'; Set-Clipboard -Value $Text; Start-Sleep -Milliseconds 50; Send-Keys 'ctrl+v'; Start-Sleep -Milliseconds 70; Start-Sleep -Milliseconds 100; Set-CuState 'idle'; Write-Output ("TYPED " + $Text.Length + " chars") }
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
  'keys'  { Set-CuState 'typing'; Send-Keys $Keys; Start-Sleep -Milliseconds 90; Set-CuState 'idle'; Write-Output ("KEYS " + $Keys) }
  'wheel' { [CU.W]::mouse_event(0x0800,0,0,$Wheel,[System.UIntPtr]::Zero); Write-Output ("WHEEL " + $Wheel) }
  'shot'  { Save-Shot $Out; Write-Output ("SHOT " + $Out) }
  'clear-cancel' {
    Remove-Item -LiteralPath $cancelFlag -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:TEMP 'dsh_agent_cancel.flag') -Force -ErrorAction SilentlyContinue
    Write-Output 'CANCEL_FLAG_CLEARED'
  }
  default { Write-Output ("UNKNOWN ACTION " + $Action); exit 1 }
}
