# install-shortcut.ps1 - Unblock scripts, create Desktop shortcut, and run first-time init if needed.
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$scriptDir  = $PSScriptRoot
$menuScript = Join-Path $scriptDir 'switch-codex-menu.ps1'
$coreScript = Join-Path $scriptDir 'switch-codex-account.ps1'

if (-not (Test-Path -LiteralPath $menuScript -PathType Leaf) -or -not (Test-Path -LiteralPath $coreScript -PathType Leaf)) {
    Write-Host "LOI: Khong tim thay switch-codex-menu.ps1 / switch-codex-account.ps1 trong $scriptDir" -ForegroundColor Red
    exit 1
}

Write-Host "=== Cai dat Switch Codex Account ===" -ForegroundColor Cyan
Write-Host "Thu muc cai dat: $scriptDir"

# Go chan Zone.Identifier (neu file duoc tai tu Internet / giai nen ZIP)
Get-ChildItem -LiteralPath $scriptDir -File | Where-Object { $_.Extension -in '.ps1', '.bat' } | ForEach-Object {
    try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch {}
}

# Kiem tra Codex CLI
$codexDefault = Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'
$codexCmd = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (Test-Path -LiteralPath $codexDefault -PathType Leaf) {
    Write-Host "Codex CLI: $codexDefault" -ForegroundColor Green
} elseif ($codexCmd -and $codexCmd.Source) {
    Write-Host "Codex CLI: $($codexCmd.Source)" -ForegroundColor Green
} else {
    Write-Host "CANH BAO: Chua tim thay lenh 'codex' trong PATH hoac AppData. Hay cai OpenAI Codex CLI truoc khi dung." -ForegroundColor Yellow
}

# Hoi tuy chon Run as Administrator
Write-Host ""
Write-Host "Neu ban chay Codex trong terminal thuong -> chon N (khong hoi UAC)."
Write-Host "Neu ban hay chay Codex bang quyen Administrator (vi du Herdr Admin) -> chon Y."
$adminAns = (Read-Host "Bat 'Run as Administrator' cho shortcut Desktop? [y/N]").Trim()
$runAsAdmin = ($adminAns -match '^[Yy]$')

# Tao shortcut ngoai Desktop
$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop 'Switch Codex Account.lnk'

$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnkPath)
$sc.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$menuScript`""
$sc.WorkingDirectory = $scriptDir
$sc.IconLocation = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
$sc.Description = 'Switch Codex CLI Account (Multi-Account Vault)'
$sc.Save()

if ($runAsAdmin) {
    $bytes = [System.IO.File]::ReadAllBytes($lnkPath)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes($lnkPath, $bytes)
}

Write-Host ""
Write-Host "Da tao shortcut: $lnkPath (RunAsAdmin=$runAsAdmin)" -ForegroundColor Green

# Khoi tao vault lan dau neu da co san ~/.codex/auth.json
$seatHome   = Join-Path $env:USERPROFILE '.codex'
$seatAuth   = Join-Path $seatHome 'auth.json'
$markerPath = Join-Path $seatHome 'seat-account.txt'
if ((Test-Path -LiteralPath $seatAuth -PathType Leaf) -and -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    Write-Host ""
    Write-Host "Phat hien tai khoan Codex hien tai -> tu dong luu vao vault thanh acc1..." -ForegroundColor Cyan
    & $coreScript -Init
}

Write-Host ""
Write-Host "Hoan tat! Tu gio ban chi can mo 'Switch Codex Account' ngoai Desktop." -ForegroundColor Green
