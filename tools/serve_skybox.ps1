# Тимчасово віддає PNG з assets\skybox на http://localhost:8766/<file>.png (для завантаження в Roblox).
# Зупиняється через 180 с.
$dir = Join-Path (Split-Path -Parent $PSScriptRoot) "assets\skybox"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:8766/")
$listener.Start()
$deadline = (Get-Date).AddSeconds(180)
try {
	while ((Get-Date) -lt $deadline) {
		$task = $listener.GetContextAsync()
		while (-not $task.AsyncWaitHandle.WaitOne(500)) { if ((Get-Date) -ge $deadline) { break } }
		if (-not $task.IsCompleted) { break }
		$ctx = $task.Result
		$name = $ctx.Request.Url.AbsolutePath.TrimStart("/")
		$file = Join-Path $dir $name
		if ($name -match '^[A-Za-z0-9_]+\.png$' -and (Test-Path $file)) {
			$bytes = [System.IO.File]::ReadAllBytes($file)
			$ctx.Response.ContentType = "image/png"
			$ctx.Response.ContentLength64 = $bytes.Length
			$ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
			Write-Output ("served " + $name)
		} else {
			$ctx.Response.StatusCode = 404
		}
		$ctx.Response.Close()
	}
} finally { $listener.Stop() }
