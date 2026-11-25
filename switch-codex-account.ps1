# switch-codex-account.ps1 - Portable Windows multi-account switcher for OpenAI Codex CLI.
#
# Keeps all Codex conversation history in the main CODEX_HOME (%USERPROFILE%\.codex)
# while safely swapping only auth.json from a local vault (%USERPROFILE%\.codex-auth-vault).
#
# Safety guarantees:
#   1. Guard: refuses to swap while any interactive Codex (TUI/exec) process is running.
#      Background app-server/exec-server/daemon processes (desktop app, VS Code) may stay.
#   2. Sync-back: before leaving the current account, copies the seat's latest auth.json
#      back to the vault so refreshed tokens are preserved.
#   3. Swap-in: copies the target account's vault auth.json into the seat and updates
#      seat-account.txt.
#   4. Never prints token contents - only sizes, timestamps, 8-char SHA-256 prefixes,
#      email prefixes, and quota snapshots.
#
# Usage:
#   .\switch-codex-account.ps1 -Init                    one-time vault + marker setup
#   .\switch-codex-account.ps1 -Status                  show state, change nothing
#   .\switch-codex-account.ps1 -Quota all               check 5h/7d quota for all accounts
#   .\switch-codex-account.ps1 -Quota acc2              check 5h/7d quota for one account
#   .\switch-codex-account.ps1 -To acc2 -DryRun         preview switch without changes
#   .\switch-codex-account.ps1 -To acc2                 switch active seat to acc2
#   .\switch-codex-account.ps1 -Login acc2              log in new account into vault
#   .\switch-codex-account.ps1 -Login acc2 -DeviceAuth  device-code login (Incognito-friendly)
#   .\switch-codex-account.ps1 -Login acc1 -Overwrite   replace/refresh an existing slot
#   .\switch-codex-account.ps1 -Remove acc3 -DryRun     preview removing a slot
#   .\switch-codex-account.ps1 -Remove acc3             remove an inactive slot from vault
#
# Optional environment overrides (for custom setups or testing):
#   CODEX_SEAT_HOME   (default: %USERPROFILE%\.codex)
#   CODEX_AUTH_VAULT  (default: %USERPROFILE%\.codex-auth-vault)
#Requires -Version 5.1
param(
  [ValidatePattern('^[a-z0-9][a-z0-9_-]{0,31}$')] [string]$To,
  [ValidatePattern('^[a-z0-9][a-z0-9_-]{0,31}$')] [string]$Login,
  [ValidatePattern('^(all|[a-z0-9][a-z0-9_-]{0,31})$')] [string]$Quota,
  [ValidatePattern('^[a-z0-9][a-z0-9_-]{0,31}$')] [string]$Remove,
  [switch]$DeviceAuth,
  [switch]$Overwrite,
  [switch]$DryRun,
  [switch]$Status,
  [switch]$Init
)

$ErrorActionPreference = 'Stop'

$seatHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SEAT_HOME)) {
  $env:CODEX_SEAT_HOME
} else {
  Join-Path $env:USERPROFILE '.codex'
}
$vault = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_AUTH_VAULT)) {
  $env:CODEX_AUTH_VAULT
} else {
  Join-Path $env:USERPROFILE '.codex-auth-vault'
}
$markerPath = Join-Path $seatHome 'seat-account.txt'
$seatAuth   = Join-Path $seatHome 'auth.json'

function Hash8($p) {
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.Substring(0, 8)
  }
  return 'MISSING'
}

function Info($p) {
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    $f = Get-Item -LiteralPath $p
    return ("hash8=" + (Hash8 $p) + " size=" + $f.Length + " mtime=" + $f.LastWriteTime.ToString('MM-dd HH:mm:ss'))
  }
  return 'MISSING'
}

function VaultPath([string]$account) {
  return (Join-Path $vault ("auth." + $account + ".json"))
}

function Get-Cur {
  if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    $v = (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim()
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  }
  return $null
}

function Get-CodexExe {
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe')
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
  }
  $cmd = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  throw 'codex CLI not found. Install Codex CLI and ensure "codex" is in PATH.'
}

function Remove-DirSafe($dirPath) {
  if (-not $dirPath -or -not (Test-Path -LiteralPath $dirPath)) { return }
  for ($attempt = 0; $attempt -lt 3; $attempt++) {
    try {
      Remove-Item -LiteralPath $dirPath -Recurse -Force -ErrorAction Stop
      return
    }
    catch {
      Start-Sleep -Milliseconds 200
    }
  }
  Remove-Item -LiteralPath $dirPath -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-Procs {
  @(Get-CimInstance Win32_Process -Filter "Name='codex.exe'" -ErrorAction SilentlyContinue)
}

function Get-Blockers {
  @(Get-Procs | Where-Object {
    [string]::IsNullOrWhiteSpace($_.CommandLine) -or ($_.CommandLine -notmatch 'app-server|exec-server|daemon')
  })
}

function Get-Accounts {
  $seen = @{}
  if (Test-Path -LiteralPath $vault -PathType Container) {
    foreach ($f in Get-ChildItem -LiteralPath $vault -Filter 'auth.*.json' -File -ErrorAction SilentlyContinue) {
      if ($f.Name -match '^auth\.([a-z0-9][a-z0-9_-]{0,31})\.json$') {
        $seen[$Matches[1]] = $true
      }
    }
  }
  $cur = Get-Cur
  if ($cur -and $cur -match '^[a-z0-9][a-z0-9_-]{0,31}$') { $seen[$cur] = $true }
  return @($seen.Keys | Sort-Object {
    if ($_ -match '^acc(\d+)$') { [int]$Matches[1] } else { [int]::MaxValue }
  }, { $_ })
}

function Get-JwtPayload($jwt) {
  if ([string]::IsNullOrWhiteSpace($jwt) -or -not $jwt.Contains('.')) { return $null }
  $parts = $jwt.Split('.')
  if ($parts.Count -lt 2) { return $null }
  $seg = $parts[1].Replace('-', '+').Replace('_', '/')
  switch ($seg.Length % 4) { 2 { $seg += '==' } 3 { $seg += '=' } }
  try {
    return ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($seg))) | ConvertFrom-Json
  }
  catch { return $null }
  finally { $seg = $null }
}

function Get-EmailFromAuth($p) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
  $j = $null; $payload = $null
  try {
    $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $j -or -not $j.tokens -or -not $j.tokens.id_token) { return $null }
    $payload = Get-JwtPayload ([string]$j.tokens.id_token)
    if (-not $payload) { return $null }
    $email = [string]$payload.email
    if ([string]::IsNullOrWhiteSpace($email)) { return $null }
    return $email.Trim().ToLowerInvariant()
  }
  catch { return $null }
  finally { $j = $null; $payload = $null }
}

function Get-AccessTokenExpiry($p) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
  $j = $null; $payload = $null
  try {
    $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $j -or -not $j.tokens -or -not $j.tokens.access_token) { return $null }
    $payload = Get-JwtPayload ([string]$j.tokens.access_token)
    if (-not $payload -or $null -eq $payload.exp) { return $null }
    return [DateTimeOffset]::FromUnixTimeSeconds([long]$payload.exp).ToLocalTime()
  }
  catch { return $null }
  finally { $j = $null; $payload = $null }
}

function Format-WindowLabel($windowMins) {
  if ($null -eq $windowMins) { return 'win' }
  $m = [long]$windowMins
  if ($m -eq 300) { return '5h' }
  if ($m -eq 10080) { return '7d' }
  if (($m % 1440) -eq 0) { return ([string]($m / 1440) + 'd') }
  if (($m % 60) -eq 0) { return ([string]($m / 60) + 'h') }
  return ([string]$m + 'm')
}

function Format-ResetTime($unixSec) {
  if ($null -eq $unixSec) { return $null }
  $dt = [DateTimeOffset]::FromUnixTimeSeconds([long]$unixSec).ToLocalTime()
  $span = $dt - [DateTimeOffset]::Now
  if ($span.TotalHours -lt 24 -and $span.TotalHours -gt -1) {
    return $dt.ToString('HH:mm')
  }
  return $dt.ToString('MM-dd HH:mm')
}

function Format-WindowUsage($win, $fallbackLabel) {
  if ($null -eq $win) { return ($fallbackLabel + ': n/a') }
  $lbl = if ($null -ne $win.windowDurationMins) { Format-WindowLabel $win.windowDurationMins } else { $fallbackLabel }
  $left = [math]::Max(0, 100 - [int]$win.usedPercent)
  $rst = Format-ResetTime $win.resetsAt
  if ($rst) { return ($lbl + ': con ' + $left + '% (reset ' + $rst + ')') }
  return ($lbl + ': con ' + $left + '%')
}

function Read-RpcResponse($proc, [int]$targetId, [int]$timeoutMs = 15000) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    $rem = [int][math]::Max(100, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
    $task = $proc.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($rem)) {
      throw ("Timeout waiting for app-server JSON-RPC response id=" + $targetId)
    }
    $line = $task.Result
    if ($null -eq $line) {
      throw ("codex app-server closed stdout before id=" + $targetId)
    }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $msg = $null
    try { $msg = $line | ConvertFrom-Json } catch { continue }
    if ($null -ne $msg -and $null -ne $msg.id -and ([int]$msg.id -eq $targetId)) {
      return $msg
    }
  }
  throw ("Timeout waiting for app-server JSON-RPC response id=" + $targetId)
}

function Invoke-QuotaProbe([string]$account) {
  $cur = Get-Cur
  $vPath = VaultPath $account
  $srcAuth = if ($account -eq $cur -and (Test-Path -LiteralPath $seatAuth -PathType Leaf)) {
    $seatAuth
  } elseif (Test-Path -LiteralPath $vPath -PathType Leaf) {
    $vPath
  } else {
    $null
  }

  if (-not $srcAuth) {
    Write-Output ($account + ": MISSING auth.json")
    return
  }

  $email = Get-EmailFromAuth $srcAuth
  $prefix = if ($email -and $email.Contains('@')) { $email.Split('@')[0] } else { $account }
  $tag = if ($prefix -ne $account) { $account + " (" + $prefix + ")" } else { $account }

  $exp = Get-AccessTokenExpiry $srcAuth
  if ($exp -and $exp -lt ([DateTimeOffset]::Now.AddMinutes(10)) -and $account -eq $cur -and (Get-Blockers).Count -gt 0) {
    Write-Output ($tag + ": SKIP (access_token expiring while interactive Codex is running on active seat)")
    return
  }

  New-Item -ItemType Directory -Force $vault | Out-Null
  $probeDir = Join-Path $vault ('.probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force $probeDir | Out-Null
  $probeAuth = Join-Path $probeDir 'auth.json'
  Copy-Item -LiteralPath $srcAuth -Destination $probeAuth -Force
  $beforeHash = Hash8 $probeAuth

  $codexExe = Get-CodexExe
  $proc = $null
  $syncedNote = ''
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($codexExe -match '\.(cmd|bat)$') {
      $psi.FileName = 'cmd.exe'
      $psi.Arguments = '/d /c ""' + $codexExe + '" app-server --listen stdio://"'
    } else {
      $psi.FileName = $codexExe
      $psi.Arguments = 'app-server --listen stdio://'
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['CODEX_HOME'] = $probeDir
    $psi.EnvironmentVariables['NO_COLOR'] = '1'

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $proc.BeginErrorReadLine()

    $initReq = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"switch-codex-quota","version":"1.0.0"}}}'
    $proc.StandardInput.WriteLine($initReq)
    $proc.StandardInput.Flush()
    $initResp = Read-RpcResponse $proc 1 15000
    if ($initResp.error) {
      throw ("initialize error: " + $initResp.error.message)
    }

    $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"initialized","params":{}}')
    $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}')
    $proc.StandardInput.Flush()
    $rlResp = Read-RpcResponse $proc 2 15000
    if ($rlResp.error) {
      throw ("rateLimits error: " + $rlResp.error.message)
    }

    $res = $rlResp.result
    $rl = $res.rateLimits
    $plan = if ($rl -and $rl.planType) { [string]$rl.planType } else { 'unknown' }
    $pStr = Format-WindowUsage ($rl.primary) '5h'
    $sStr = Format-WindowUsage ($rl.secondary) '7d'
    $extra = ''
    if ($res.ordinaryUsageAllowed -eq $false) {
      $reason = if ($rl.rateLimitReachedType) { [string]$rl.rateLimitReachedType } else { 'limit_reached' }
      $extra += " [BLOCKED: $reason]"
    }
    if ($rl.credits -and $rl.credits.hasCredits -and -not [string]::IsNullOrWhiteSpace([string]$rl.credits.balance)) {
      $extra += " | credits=$($rl.credits.balance)"
    }
  }
  catch {
    Write-Output ($tag + ": ERROR - " + $_.Exception.Message)
    return
  }
  finally {
    if ($null -ne $proc) {
      try {
        if (-not $proc.HasExited) {
          $proc.Kill()
          [void]$proc.WaitForExit(3000)
        }
      }
      catch {}
      try { $proc.Dispose() } catch {}
    }

    if (Test-Path -LiteralPath $probeAuth -PathType Leaf) {
      $afterHash = Hash8 $probeAuth
      if ($afterHash -ne $beforeHash) {
        Copy-Item -LiteralPath $probeAuth -Destination $vPath -Force
        if ($account -eq $cur -and (Get-Blockers).Count -eq 0) {
          Copy-Item -LiteralPath $probeAuth -Destination $seatAuth -Force
        }
        $syncedNote = ' [token refreshed & synced]'
      }
    }
    Remove-DirSafe $probeDir
  }

  Write-Output ("{0} [{1}]  {2} | {3}{4}{5}" -f $tag, $plan, $pStr, $sStr, $extra, $syncedNote)
}

function Show-State {
  $cur = Get-Cur
  Write-Output ("SEAT_HOME=" + $seatHome)
  Write-Output ("VAULT_DIR=" + $vault)
  Write-Output ("SEAT_ACCOUNT=" + $(if ($cur) { $cur } else { 'unknown (run -Init or -Login acc1)' }))
  Write-Output ("SEAT_AUTH  " + (Info $seatAuth))
  foreach ($a in (Get-Accounts)) {
    $vp = VaultPath $a
    $email = Get-EmailFromAuth $vp
    $prefix = if ($email -and $email.Contains('@')) { " (" + $email.Split('@')[0] + ")" } else { "" }
    Write-Output ($a + $prefix + " VAULT " + (Info $vp))
  }
  $procs = Get-Procs
  Write-Output ("CODEX_PROCESSES=" + $procs.Count + " (interactive blockers: " + (Get-Blockers).Count + ")")
  foreach ($p in $procs) {
    $cmdText = if ([string]::IsNullOrWhiteSpace($p.CommandLine)) { '<elevated/hidden>' } else { $p.CommandLine }
    $kind = if ($p.CommandLine -match 'app-server|exec-server|daemon') { 'background' } else { 'INTERACTIVE' }
    Write-Output ("  [" + $kind + "] pid=" + $p.ProcessId + " cmd=" + $cmdText)
  }
}

if ($Init) {
  if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    Write-Output 'Marker already exists - refusing to re-init.'
    Show-State
    return
  }
  if (-not (Test-Path -LiteralPath $seatAuth -PathType Leaf)) {
    Write-Output ("ABORT: no existing auth.json found at " + $seatAuth + ". Run 'codex login' first or use -Login acc1.")
    return
  }
  New-Item -ItemType Directory -Force $seatHome | Out-Null
  New-Item -ItemType Directory -Force $vault | Out-Null
  Copy-Item -LiteralPath $seatAuth -Destination (VaultPath 'acc1') -Force
  Set-Content -LiteralPath $markerPath -Value 'acc1' -NoNewline -Encoding UTF8
  Write-Output 'INIT DONE: vault created from live seat auth; seat account = acc1.'
  Show-State
  return
}

if ($Quota) {
  if ($Quota -eq 'all') {
    foreach ($acc in (Get-Accounts)) {
      Invoke-QuotaProbe $acc
    }
  } else {
    Invoke-QuotaProbe $Quota
  }
  return
}

if ($Remove) {
  $cur = Get-Cur
  $vPath = VaultPath $Remove
  if (-not (Test-Path -LiteralPath $vPath -PathType Leaf)) {
    Write-Output ("ABORT: account '" + $Remove + "' not found in vault (" + $vPath + ").")
    return
  }
  if ($Remove -eq $cur) {
    Write-Output ("ABORT: '" + $Remove + "' is currently active on the main seat. Switch to another account first, then remove '" + $Remove + "'.")
    return
  }
  $email = Get-EmailFromAuth $vPath
  $prefix = if ($email -and $email.Contains('@')) { " (" + $email.Split('@')[0] + ")" } else { "" }
  if ($DryRun) {
    Show-State
    Write-Output ("PLAN: remove vault token for '" + $Remove + "'" + $prefix + " -> " + $vPath + " (main seat sessions untouched).")
    Write-Output 'DRYRUN: no files changed.'
    return
  }
  Remove-Item -LiteralPath $vPath -Force
  Write-Output ("REMOVED account '" + $Remove + "'" + $prefix + " from vault (" + $vPath + ").")
  Show-State
  return
}

if ($Login) {
  New-Item -ItemType Directory -Force $seatHome | Out-Null
  New-Item -ItemType Directory -Force $vault | Out-Null
  $dstVault = VaultPath $Login
  if ((Test-Path -LiteralPath $dstVault -PathType Leaf) -and -not $Overwrite) {
    Write-Output ("ABORT: account '" + $Login + "' already exists in vault. Pass -Overwrite to replace/refresh its token.")
    return
  }
  $cur = Get-Cur
  if ($Login -eq $cur -and (Get-Blockers).Count -gt 0) {
    Write-Output 'ABORT: interactive Codex processes are running on the active seat. Exit Codex first, then re-run.'
    return
  }
  $codexExe = Get-CodexExe

  $stagingDir = Join-Path $vault ('.staging-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force $stagingDir | Out-Null
  $hadPrevHome = Test-Path Env:CODEX_HOME
  $prevHome = $env:CODEX_HOME
  $hadPrevNoColor = Test-Path Env:NO_COLOR
  $prevNoColor = $env:NO_COLOR
  try {
    $env:CODEX_HOME = $stagingDir
    $env:NO_COLOR = '1'
    $loginArgs = @('login')
    if ($DeviceAuth) { $loginArgs += '--device-auth' }
    & $codexExe @loginArgs
    if ($LASTEXITCODE -ne 0) {
      Write-Output ("ABORT: codex login exited with code " + $LASTEXITCODE + ".")
      return
    }
    $stagingAuth = Join-Path $stagingDir 'auth.json'
    if (-not (Test-Path -LiteralPath $stagingAuth -PathType Leaf)) {
      Write-Output 'ABORT: login completed without writing auth.json.'
      return
    }
    $parsed = $null
    try { $parsed = Get-Content -LiteralPath $stagingAuth -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $parsed = $null }
    if (-not $parsed -or (-not $parsed.tokens -and -not $parsed.OPENAI_API_KEY)) {
      $parsed = $null
      Write-Output 'ABORT: staged auth.json is invalid or missing credentials.'
      return
    }
    $parsed = $null

    $newEmail = Get-EmailFromAuth $stagingAuth
    if ($newEmail) {
      foreach ($existing in (Get-Accounts)) {
        if ($existing -eq $Login) { continue }
        $otherFile = VaultPath $existing
        if (Test-Path -LiteralPath $otherFile -PathType Leaf) {
          $otherEmail = Get-EmailFromAuth $otherFile
          if ($otherEmail -and $otherEmail -eq $newEmail) {
            if (-not $Overwrite) {
              Write-Output ("ABORT: logged-in email already belongs to '" + $existing + "'. Use -Login " + $existing + " -Overwrite to refresh it instead.")
              return
            }
            Write-Output ("WARNING: this email already matches existing slot '" + $existing + "'.")
          }
        }
      }
    }

    Copy-Item -LiteralPath $stagingAuth -Destination $dstVault -Force
    if (-not $cur -and -not (Test-Path -LiteralPath $seatAuth -PathType Leaf)) {
      Copy-Item -LiteralPath $stagingAuth -Destination $seatAuth -Force
      Set-Content -LiteralPath $markerPath -Value $Login -NoNewline -Encoding UTF8
      Write-Output ("BOOTSTRAPPED active seat with '" + $Login + "'.")
    }
    elseif ($Login -eq $cur) {
      Copy-Item -LiteralPath $stagingAuth -Destination $seatAuth -Force
    }
    Write-Output ("SAVED account '" + $Login + "' -> " + $dstVault + " (" + (Info $dstVault) + ")")
    Show-State
  }
  finally {
    if ($hadPrevHome) { $env:CODEX_HOME = $prevHome } else { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    if ($hadPrevNoColor) { $env:NO_COLOR = $prevNoColor } else { Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue }
    Remove-DirSafe $stagingDir
  }
  return
}

if ($Status) { Show-State; return }

if (-not $To) {
  Write-Output 'Specify -To <account>, -Login <account>, -Quota all|<account>, -Remove <account>, or -Status / -Init.'
  return
}

$cur = Get-Cur
if (-not $cur) {
  Write-Output 'ABORT: no seat marker found - run -Init first (or -Login acc1 if fresh).'
  return
}
if ($cur -eq $To) {
  Write-Output ("Seat already runs " + $To + " - nothing to do.")
  Show-State
  return
}
$src = VaultPath $To
if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
  Write-Output ("ABORT: no vault auth copy found for '" + $To + "' (" + $src + ").")
  return
}
$blockers = Get-Blockers
if ($DryRun) {
  Show-State
  Write-Output ("PLAN: sync-back seat auth as " + $cur + " -> vault; swap-in " + $To + " from " + $src + "; marker -> " + $To + ".")
  if ($blockers.Count -gt 0) {
    Write-Output 'GUARD: a real run would ABORT now (interactive Codex still running - exit Codex in all terminals first).'
  } else {
    Write-Output 'GUARD: clear (no interactive Codex running; background app-servers may stay).'
  }
  Write-Output 'DRYRUN: no files changed.'
  return
}
if ($blockers.Count -gt 0) {
  Write-Output 'ABORT: interactive Codex processes are still running. Exit Codex in all terminals, then re-run.'
  foreach ($p in $blockers) {
    $cmdText = if ([string]::IsNullOrWhiteSpace($p.CommandLine)) { '<elevated/hidden>' } else { $p.CommandLine }
    Write-Output ("  pid=" + $p.ProcessId + " cmd=" + $cmdText)
  }
  return
}

New-Item -ItemType Directory -Force $vault | Out-Null
if (Test-Path -LiteralPath $seatAuth -PathType Leaf) {
  $curVault = VaultPath $cur
  if (-not [System.String]::Equals([System.IO.Path]::GetFullPath($seatAuth), [System.IO.Path]::GetFullPath($curVault), [System.StringComparison]::OrdinalIgnoreCase)) {
    Copy-Item -LiteralPath $seatAuth -Destination $curVault -Force
  }
}
Copy-Item -LiteralPath $src -Destination $seatAuth -Force
Set-Content -LiteralPath $markerPath -Value $To -NoNewline -Encoding UTF8
Write-Output ("SWITCHED seat account: " + $cur + " -> " + $To + " (vault source: " + $src + ")")
Show-State
