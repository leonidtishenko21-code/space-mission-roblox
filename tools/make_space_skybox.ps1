# Генерує 6 граней зоряного скайбоксу (1024×1024 PNG) у RobloxSpaceGame\assets\skybox.
# Зорі різної яскравості й кольору (біло-блакитні, жовті, помаранчеві) + кілька слабких туманностей
# у центрі граней (не біля країв, щоб не було видно швів між гранями).
Add-Type -AssemblyName System.Drawing
$out = Join-Path (Split-Path -Parent $PSScriptRoot) "assets\skybox"
New-Item -ItemType Directory -Force $out | Out-Null
$size = 1024
$faces = @("Bk", "Dn", "Ft", "Lf", "Rt", "Up")
$seed = 2026
foreach ($face in $faces) {
	$seed += 17
	$rnd = [System.Random]::new($seed)
	$bmp = [System.Drawing.Bitmap]::new($size, $size)
	$g = [System.Drawing.Graphics]::FromImage($bmp)
	$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
	$g.Clear([System.Drawing.Color]::FromArgb(255, 2, 3, 8))

	# туманності: м'які кольорові плями з радіальним градієнтом (лише на бічних гранях і зверху)
	if ($face -ne "Dn") {
		$palette = @(@(90, 40, 140), @(30, 70, 150), @(140, 50, 90), @(40, 110, 130))
		$count = $rnd.Next(1, 3)
		for ($i = 0; $i -lt $count; $i++) {
			$c = $palette[$rnd.Next(0, $palette.Count)]
			$r = $rnd.Next(180, 320)
			$cx = $rnd.Next(320, $size - 320)
			$cy = $rnd.Next(320, $size - 320)
			$path = [System.Drawing.Drawing2D.GraphicsPath]::new()
			$path.AddEllipse($cx - $r, $cy - [int]($r * 0.6), 2 * $r, [int](1.2 * $r))
			$brush = [System.Drawing.Drawing2D.PathGradientBrush]::new($path)
			$brush.CenterColor = [System.Drawing.Color]::FromArgb(62, $c[0], $c[1], $c[2])
			$brush.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $c[0], $c[1], $c[2]))
			$g.FillPath($brush, $path)
			$brush.Dispose()
			$path.Dispose()
		}
	}

	# зорі
	$tints = @(@(255, 255, 255), @(200, 220, 255), @(255, 240, 210), @(255, 210, 170), @(180, 200, 255))
	$n = if ($face -eq "Dn") { 900 } else { 2600 }
	for ($i = 0; $i -lt $n; $i++) {
		$x = $rnd.NextDouble() * $size
		$y = $rnd.NextDouble() * $size
		$t = $tints[$rnd.Next(0, $tints.Count)]
		$roll = $rnd.NextDouble()
		if ($roll -lt 0.80) {
			$a = $rnd.Next(60, 170); $d = 1.2
		} elseif ($roll -lt 0.97) {
			$a = $rnd.Next(150, 230); $d = 2.0
		} else {
			$a = 255; $d = 3.2
			# яскрава зоря з м'яким ореолом
			$glow = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(40, $t[0], $t[1], $t[2]))
			$g.FillEllipse($glow, [single]($x - 5), [single]($y - 5), 10, 10)
			$glow.Dispose()
		}
		$b = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($a, $t[0], $t[1], $t[2]))
		$g.FillEllipse($b, [single]($x - $d / 2), [single]($y - $d / 2), [single]$d, [single]$d)
		$b.Dispose()
	}
	$g.Dispose()
	$file = Join-Path $out ("space_" + $face + ".png")
	$bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
	$bmp.Dispose()
	Write-Output ("saved " + $file)
}
