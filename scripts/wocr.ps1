param(
  [string]$Path = '',
  [switch]$Boxes,
  [double]$Scale = 2.0
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Drawing, System.Runtime.WindowsRuntime
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime] | Out-Null

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]
function Await($WinRtTask, $ResultType) {
  $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
  $netTask = $asTask.Invoke($null, @($WinRtTask))
  $netTask.Wait(-1) | Out-Null
  $netTask.Result
}
function Scale-Image([string]$src, [string]$dst, [double]$f) {
  $img = [System.Drawing.Image]::FromFile($src)
  $w = [int]($img.Width * $f); $h = [int]($img.Height * $f)
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.DrawImage($img, 0, 0, $w, $h)
  $bmp.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose(); $img.Dispose()
  return $dst
}
if (-not $Path) {
  $Path = Join-Path $env:TEMP ('wocr_cap_' + (Get-Random) + '.png')
  Add-Type -AssemblyName System.Windows.Forms
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size)
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  Write-Output ("CAPTURED " + $Path)
}
if (-not (Test-Path -LiteralPath $Path)) { Write-Output 'FILE_NOT_FOUND'; exit 1 }

$ocrPath = $Path
if ($Scale -ne 1.0) { $ocrPath = Scale-Image $Path (Join-Path $env:TEMP ('wocr_up_' + (Get-Random) + '.png')) $Scale }

$stream = [System.IO.File]::OpenRead($ocrPath)
$ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($stream)
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($ras)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if (-not $engine) {
  $lang = New-Object Windows.Globalization.Language 'zh-Hans-CN'
  $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
}
if (-not $engine) { Write-Output 'NO_OCR_ENGINE'; exit 1 }
Write-Output ("ENGINE: " + $engine.RecognizerLanguage.LanguageTag + "  IMG: " + $bitmap.PixelWidth + "x" + $bitmap.PixelHeight)

$result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
$lines = @($result.Lines)
Write-Output ("LINES: " + $lines.Count)
if ($Boxes) {
  foreach ($line in $lines) {
    $x1 = [double]::MaxValue; $y1 = [double]::MaxValue; $x2 = 0.0; $y2 = 0.0
    foreach ($w in $line.Words) {
      $r = $w.BoundingRect
      if ($r.X -lt $x1) { $x1 = $r.X }
      if ($r.Y -lt $y1) { $y1 = $r.Y }
      if (($r.X + $r.Width) -gt $x2) { $x2 = $r.X + $r.Width }
      if (($r.Y + $r.Height) -gt $y2) { $y2 = $r.Y + $r.Height }
    }
    $sx = [int]($x1 / $Scale); $sy = [int]($y1 / $Scale)
    Write-Output ("BOX " + $sx + "," + $sy + " " + [int](($x2-$x1)/$Scale) + "x" + [int](($y2-$y1)/$Scale) + " | " + $line.Text)
  }
} else {
  foreach ($line in $lines) { Write-Output ("L| " + $line.Text) }
}
$stream.Dispose()
