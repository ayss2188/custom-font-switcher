# 打包刷机包（Windows）：把 module\ 目录里的内容打成 dist\custom-font-switcher.zip
# 用法：powershell -ExecutionPolicy Bypass -File scripts\build.ps1
# 用系统自带的 tar.exe 打 zip（路径分隔符是 /，手机上能正常解压）；
# 不要用 Compress-Archive，Windows PowerShell 5.1 生成的 zip 路径是反斜杠，刷入会失败。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$module = Join-Path $root 'module'
$dist = Join-Path $root 'dist'
$out = Join-Path $dist 'custom-font-switcher.zip'
New-Item -ItemType Directory -Force $dist | Out-Null
if (Test-Path $out) { Remove-Item $out -Force }

# 刷机脚本必须是 LF 换行
$bad = Get-ChildItem $module -Recurse -File | Where-Object {
  $_.Extension -in '.sh', '.prop', '.list', '.html', '.py', '' -and
  ([IO.File]::ReadAllText($_.FullName)).Contains("`r")
}
if ($bad) {
  Write-Host '错误：以下文件含 Windows 换行（CRLF），请转换为 LF：' -ForegroundColor Red
  $bad | ForEach-Object { Write-Host "  $($_.FullName)" }
  exit 1
}

Push-Location $module
try {
  & tar.exe -a -c -f $out *
  if ($LASTEXITCODE -ne 0) { throw 'tar 打包失败' }
} finally { Pop-Location }

$sha = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
Write-Host "已生成：$out"
Write-Host "sha256：$sha"
