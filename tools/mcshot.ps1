# Screenshot of the Minecraft window (works while it is behind other windows).
#   pwsh tools/mcshot.ps1 [-Out logs/mc.png] [-Crop x,y,w,h] [-Scale 0.5]
# Uses PrintWindow with PW_RENDERFULLCONTENT, which captures OpenGL windows
# on Windows 10+. Minimised windows come out black.
param(
  [string]$Out = "logs/mc.png",
  [string]$Crop,
  [double]$Scale = 1
)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class McShot {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[McShot]::SetProcessDPIAware() | Out-Null
$p = Get-Process javaw -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -ne "" } | Select-Object -First 1
if (-not $p) { Write-Error "Minecraft is not running"; exit 1 }
$r = New-Object McShot+RECT
[McShot]::GetClientRect($p.MainWindowHandle, [ref]$r) | Out-Null
$w = $r.R - $r.L; $h = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc()
# 1 = client area only, 2 = render full content (DirectX/OpenGL)
[McShot]::PrintWindow($p.MainWindowHandle, $dc, 3) | Out-Null
$g.ReleaseHdc($dc); $g.Dispose()
if ($Crop) {
  $cr = [int[]]($Crop -split ",")
  $c = $bmp.Clone((New-Object System.Drawing.Rectangle $cr[0], $cr[1], $cr[2], $cr[3]), $bmp.PixelFormat)
  $bmp.Dispose(); $bmp = $c
}
if ($Scale -ne 1) {
  $s = New-Object System.Drawing.Bitmap ([int]($bmp.Width * $Scale)), ([int]($bmp.Height * $Scale))
  $g = [System.Drawing.Graphics]::FromImage($s)
  $g.InterpolationMode = "NearestNeighbor"
  $g.DrawImage($bmp, 0, 0, $s.Width, $s.Height); $g.Dispose()
  $bmp.Dispose(); $bmp = $s
}
$full = [System.IO.Path]::GetFullPath($Out)
$bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
"$full $($bmp.Width)x$($bmp.Height) (window ${w}x$h)"
