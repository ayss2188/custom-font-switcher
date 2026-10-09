# 把仓库里所有的 __REPO__ 占位符替换成你的 GitHub 仓库（只需要运行一次）
# 用法：双击仓库根目录的「设置仓库地址.bat」，按提示输入即可
# 或：powershell -ExecutionPolicy Bypass -File scripts\set-repo.ps1 你的用户名/custom-font-switcher
param([string]$Repo)
$ErrorActionPreference = 'Stop'
if (-not $Repo) {
  Write-Host ''
  Write-Host '请输入你的 GitHub 用户名和仓库名，格式：用户名/仓库名'
  Write-Host '例如：zhangsan/custom-font-switcher'
  $Repo = (Read-Host '仓库').Trim()
}
if ($Repo -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') {
  Write-Host "格式不对：$Repo（应为 用户名/仓库名，只能有字母、数字、- _ .）" -ForegroundColor Red
  exit 1
}
$root = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object Text.UTF8Encoding $false
$changed = 0
foreach ($rel in 'module/module.prop', 'update.json', 'README.md', 'docs/酷安帖子.md') {
  $p = Join-Path $root $rel
  if (-not (Test-Path $p)) { continue }
  $t = [IO.File]::ReadAllText($p)
  if ($t.Contains('__REPO__')) {
    [IO.File]::WriteAllText($p, $t.Replace('__REPO__', $Repo), $utf8)
    Write-Host "已更新 $rel"
    $changed++
  }
}
if ($changed -eq 0) { Write-Host '没有找到 __REPO__ 占位符（可能已经设置过了）' }
else { Write-Host "完成！仓库地址已设置为 https://github.com/$Repo" -ForegroundColor Green }
