# Генерация иконки и splash-логотипа из текста через System.Drawing.
# Запуск из корня проекта:
#   powershell -ExecutionPolicy Bypass -File scripts/generate_brand_assets.ps1
#
# Результат:
#   mobile/assets/icon/icon.png           — 1024x1024, solid background, для launcher_icons
#   mobile/assets/icon/icon_fg.png        — 1024x1024, прозрачный фон, для adaptive icon foreground
#   mobile/assets/splash/splash.png       — 512x512, прозрачный фон, для native_splash image

Add-Type -AssemblyName System.Drawing

function New-AppIcon {
    param(
        [string]$Path,
        [System.Drawing.Color]$BgColor,
        [System.Drawing.Color]$FgColor,
        [int]$Size,
        [string]$Text,
        [int]$FontSize,
        [bool]$TransparentBg = $false
    )
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    if ($TransparentBg) {
        $g.Clear([System.Drawing.Color]::Transparent)
        # Круг как форма иконки
        $brush = New-Object System.Drawing.SolidBrush($BgColor)
        $g.FillEllipse($brush, 0, 0, $Size, $Size)
        $brush.Dispose()
    } else {
        $g.Clear($BgColor)
    }
    $font = New-Object System.Drawing.Font('Segoe UI', $FontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $textBrush = New-Object System.Drawing.SolidBrush($FgColor)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $sf.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $sf.Trimming = [System.Drawing.StringTrimming]::None
    $rect = New-Object System.Drawing.RectangleF(0, 0, $Size, $Size)
    $g.DrawString($Text, $font, $textBrush, $rect, $sf)
    $font.Dispose()
    $textBrush.Dispose()
    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output "wrote $Path"
}

$darkGreen   = [System.Drawing.Color]::FromArgb(255, 27, 94, 32)   # 0xFF1B5E20 (splash bg / icon bg)
$mediumGreen = [System.Drawing.Color]::FromArgb(255, 76, 175, 80)  # 0xFF4CAF50 (foreground круг)
$white       = [System.Drawing.Color]::White

$root = Split-Path -Parent $PSScriptRoot
$iconDir   = Join-Path $root 'mobile\assets\icon'
$splashDir = Join-Path $root 'mobile\assets\splash'

New-AppIcon -Path (Join-Path $iconDir 'icon.png')      -BgColor $darkGreen   -FgColor $white -Size 1024 -Text 'AM' -FontSize 420 -TransparentBg $false
New-AppIcon -Path (Join-Path $iconDir 'icon_fg.png')   -BgColor $mediumGreen -FgColor $white -Size 1024 -Text 'AM' -FontSize 360 -TransparentBg $true
New-AppIcon -Path (Join-Path $splashDir 'splash.png')  -BgColor $mediumGreen -FgColor $white -Size 512  -Text 'AM' -FontSize 200 -TransparentBg $true
