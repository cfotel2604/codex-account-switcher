# switch-codex-menu.ps1 - Portable interactive menu wrapper for switch-codex-account.ps1.
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Switch Codex Account'

$sw = Join-Path $PSScriptRoot 'switch-codex-account.ps1'
$seatHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SEAT_HOME)) {
    $env:CODEX_SEAT_HOME
} else {
    Join-Path $env:USERPROFILE '.codex'
}
$vaultDir = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_AUTH_VAULT)) {
    $env:CODEX_AUTH_VAULT
} else {
    Join-Path $env:USERPROFILE '.codex-auth-vault'
}
$markerPath = Join-Path $seatHome 'seat-account.txt'
$seatAuth   = Join-Path $seatHome 'auth.json'

# Tuy chon dat ten hien thi thu cong (de trong se tu dong lay phan truoc '@' trong email cua auth.json):
# Vi du: $CustomLabels = @{ acc1 = "plus-chinh"; acc2 = "plus-phu" }
$CustomLabels = @{}

function Get-EmailPrefixFromAuth {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $j = $null
    $jwt = $null
    $seg = $null
    $payload = $null
    try {
        $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $j -or -not $j.tokens) { return $null }
        $jwt = [string]$j.tokens.id_token
        if ([string]::IsNullOrWhiteSpace($jwt) -or -not $jwt.Contains('.')) { return $null }
        $parts = $jwt.Split('.')
        if ($parts.Count -lt 2) { return $null }

        $seg = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($seg.Length % 4) {
            2 { $seg += '==' }
            3 { $seg += '=' }
        }
        $jsonText = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($seg))
        $payload = $jsonText | ConvertFrom-Json
        $email = [string]$payload.email
        if ([string]::IsNullOrWhiteSpace($email) -or -not $email.Contains('@')) { return $null }
        return $email.Split('@')[0].Trim()
    }
    catch {
        return $null
    }
    finally {
        $j = $null
        $jwt = $null
        $seg = $null
        $payload = $null
    }
}

function Get-VaultAccounts {
    $seen = @{}
    if (Test-Path -LiteralPath $vaultDir -PathType Container) {
        foreach ($f in Get-ChildItem -LiteralPath $vaultDir -Filter 'auth.*.json' -File -ErrorAction SilentlyContinue) {
            if ($f.Name -match '^auth\.([a-z0-9][a-z0-9_-]{0,31})\.json$') {
                $seen[$Matches[1]] = $true
            }
        }
    }
    $cur = if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim()
    } else {
        $null
    }
    if ($cur -and $cur -match '^[a-z0-9][a-z0-9_-]{0,31}$') {
        $seen[$cur] = $true
    }
    return @($seen.Keys | Sort-Object {
        if ($_ -match '^acc(\d+)$') { [int]$Matches[1] } else { [int]::MaxValue }
    }, { $_ })
}

function Get-NextAccountName {
    param([string[]]$Existing = @())

    $n = 1
    while ($Existing -contains ("acc" + $n)) {
        $n++
    }
    return ("acc" + $n)
}

function Get-AccountLabel {
    param([Parameter(Mandatory = $true)][string]$Account)

    if ($CustomLabels.ContainsKey($Account) -and -not [string]::IsNullOrWhiteSpace($CustomLabels[$Account])) {
        return $CustomLabels[$Account].Trim()
    }

    $curSeat = if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim()
    } else {
        $null
    }

    $candidates = @()
    if ($curSeat -eq $Account) {
        $candidates += $seatAuth
    }
    $candidates += (Join-Path $vaultDir ("auth." + $Account + ".json"))

    $files = @(foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) {
            Get-Item -LiteralPath $c
        }
    }) | Sort-Object LastWriteTime -Descending

    foreach ($f in $files) {
        $prefix = Get-EmailPrefixFromAuth -Path $f.FullName
        if (-not [string]::IsNullOrWhiteSpace($prefix)) {
            return $prefix
        }
    }

    return $Account
}

try {
    if (-not (Test-Path -LiteralPath $sw -PathType Leaf)) {
        Write-Host "Khong tim thay script: $sw" -ForegroundColor Red
        [void](Read-Host "Nhan Enter de dong")
        exit 1
    }

    # Tu dong khoi tao vault lan dau neu may da dang nhap san Codex nhung chua co marker
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -and (Test-Path -LiteralPath $seatAuth -PathType Leaf)) {
        Write-Host "Phat hien Codex da dang nhap san nhung chua khoi tao vault. Dang tu dong chay -Init (luu thanh acc1)..." -ForegroundColor Cyan
        & $sw -Init
        Write-Host ""
        [void](Read-Host "Nhan Enter de vao menu")
    }

    while ($true) {
        $curSeat = if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim()
        } else {
            $null
        }
        $accounts = @(Get-VaultAccounts)
        $labels = @{}
        foreach ($acc in $accounts) {
            $labels[$acc] = Get-AccountLabel -Account $acc
        }
        $curLabel = if ($curSeat) { Get-AccountLabel -Account $curSeat } else { 'chua khoi tao' }

        Clear-Host
        Write-Host "=== Switch Codex Account (Main Seat: $seatHome) ===" -ForegroundColor Cyan
        Write-Host "Tai khoan dang dung: $curLabel ($(if ($curSeat) { $curSeat } else { 'none' }))" -ForegroundColor Green
        Write-Host ""
        & $sw -Status
        Write-Host ""
        Write-Host "Menu:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $accounts.Count; $i++) {
            $acc = $accounts[$i]
            $mark = if ($acc -eq $curSeat) { " *" } else { "" }
            Write-Host ("  [{0}] Chuyen sang {1} ({2}){3}" -f ($i + 1), $labels[$acc], $acc, $mark)
        }
        Write-Host "  [S] Xem quota /status (1 acc hoac tat ca)"
        Write-Host "  [A] Them tai khoan moi (mo trinh duyet)"
        Write-Host "  [D] Them tai khoan moi (device-auth / dung tab An danh)"
        Write-Host "  [L] Dang nhap lai / thay the tai khoan cho 1 slot"
        Write-Host "  [X] Xoa tai khoan khoi vault"
        Write-Host "  [R] Lam moi trang thai"
        Write-Host "  [Q] Thoat"
        Write-Host ""

        $choice = (Read-Host "Chon").Trim()
        if ($choice -match '^[Qq]$') {
            break
        }
        if ($choice -eq '' -or $choice -match '^[Rr]$') {
            continue
        }

        if ($choice -match '^[Ss]$') {
            if ($accounts.Count -eq 0) {
                Write-Host "Chua co tai khoan nao trong vault." -ForegroundColor Red
                [void](Read-Host "Nhan Enter de quay lai menu")
                continue
            }
            $pick = (Read-Host ("Chon so acc [1-{0}] hoac Enter de xem TAT CA" -f $accounts.Count)).Trim()
            Write-Host ""
            if ([string]::IsNullOrWhiteSpace($pick)) {
                Write-Host "--- Dang kiem tra quota /status cho tat ca tai khoan ---" -ForegroundColor Cyan
                & $sw -Quota all
            }
            elseif ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $accounts.Count) {
                $slot = $accounts[[int]$pick - 1]
                Write-Host ("--- Dang kiem tra quota /status cho {0} ({1}) ---" -f $labels[$slot], $slot) -ForegroundColor Cyan
                & $sw -Quota $slot
            }
            else {
                Write-Host "Lua chon khong hop le." -ForegroundColor Red
            }
            Write-Host ""
            [void](Read-Host "Nhan Enter de quay lai menu")
            continue
        }

        if ($choice -match '^[AaDd]$') {
            $useDevice = ($choice -match '^[Dd]$')
            $defaultName = Get-NextAccountName -Existing $accounts
            $rawName = (Read-Host "Ten slot moi (Enter de dung '$defaultName')").Trim()
            $newName = if ([string]::IsNullOrWhiteSpace($rawName)) { $defaultName } else { $rawName }
            if ($newName -notmatch '^[a-z0-9][a-z0-9_-]{0,31}$') {
                Write-Host "Ten slot khong hop le (chi dung a-z, 0-9, -, _)." -ForegroundColor Red
                [void](Read-Host "Nhan Enter de quay lai menu")
                continue
            }
            if ($accounts -contains $newName) {
                Write-Host "Slot '$newName' da ton tai - hay dung [L] de thay the/refresh hoac chon ten khac." -ForegroundColor Yellow
                [void](Read-Host "Nhan Enter de quay lai menu")
                continue
            }
            Write-Host ""
            if ($useDevice) {
                Write-Host "Dang mo dang nhap device-auth cho '$newName' (hay copy link/ma vao tab An danh dung tai khoan moi)..." -ForegroundColor Cyan
                & $sw -Login $newName -DeviceAuth
            } else {
                Write-Host "Dang mo trinh duyet dang nhap cho '$newName'..." -ForegroundColor Cyan
                & $sw -Login $newName
            }
            Write-Host ""
            [void](Read-Host "Nhan Enter de quay lai menu")
            continue
        }

        if ($choice -match '^[Ll]$') {
            if ($accounts.Count -eq 0) {
                Write-Host "Chua co slot nao trong vault." -ForegroundColor Red
                [void](Read-Host "Nhan Enter de quay lai menu")
                continue
            }
            $pick = (Read-Host ("Chon so tai khoan can dang nhap lai / thay the [1-{0}] (Enter de huy)" -f $accounts.Count)).Trim()
            if ([string]::IsNullOrWhiteSpace($pick)) {
                continue
            }
            if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $accounts.Count) {
                Write-Host "Lua chon khong hop le." -ForegroundColor Red
                [void](Read-Host "Nhan Enter de quay lai menu")
                continue
            }
            $slot = $accounts[[int]$pick - 1]
            $slotLabel = $labels[$slot]
            $devAns = (Read-Host "Dung device-auth (tien cho tab An danh)? [y/N]").Trim()
            $confirm = (Read-Host "Xac nhan dang nhap lai cho $slotLabel ($slot)? Go y de tiep tuc (Enter de huy)").Trim()
            if ($confirm -match '^[Yy]$') {
                Write-Host ""
                if ($devAns -match '^[Yy]$') {
                    & $sw -Login $slot -Overwrite -DeviceAuth
                } else {
                    & $sw -Login $slot -Overwrite
                }
            } else {
                Write-Host "Da huy thao tac." -ForegroundColor DarkGray
            }
            Write-Host ""
            [void](Read-Host "Nhan Enter de quay lai menu")
            continue
        }

        if ($choice -match '^[Xx]$') {
            if ($accounts.Count -eq 0) {
                Write-Host "Chua co tai khoan nao trong vault." -ForegroundColor Red
                [void](Read-Host "Nhan Enter de quay lai menu")
                continue
            }
            $pick = (Read-Host ("Chon so tai khoan can XOA khoi vault [1-{0}] (Enter de huy)" -f $accounts.Count)).Trim()
            if ([string]::IsNullOrWhiteSpace($pick)) {
                continue
            }
            if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $accounts.Count) {
                Write-Host "Lua chon khong hop le." -ForegroundColor Red
                [void](Read-Host "Nhan Enter de quay lai menu")
                continue
            }
            $slot = $accounts[[int]$pick - 1]
            $slotLabel = $labels[$slot]
            if ($slot -eq $curSeat) {
                Write-Host "Khong the xoa '$slotLabel ($slot)' vi dang la tai khoan active tren ghe chinh." -ForegroundColor Red
                Write-Host "Hay chuyen sang tai khoan khac truoc, roi quay lai xoa slot nay." -ForegroundColor Yellow
                [void](Read-Host "Nhan Enter de quay lai menu")
                continue
            }
            Write-Host ""
            Write-Host "--- Xem truoc (-DryRun) xoa $slotLabel ($slot) ---" -ForegroundColor Cyan
            & $sw -Remove $slot -DryRun
            Write-Host ""
            $confirm = (Read-Host "Xac nhan XOA vinh vien token cua $slotLabel ($slot) khoi vault? Go '$slot' de xac nhan (Enter de huy)").Trim()
            if ($confirm -eq $slot) {
                Write-Host ""
                & $sw -Remove $slot
            } else {
                Write-Host "Da huy xoa." -ForegroundColor DarkGray
            }
            Write-Host ""
            [void](Read-Host "Nhan Enter de quay lai menu")
            continue
        }

        $selectedNum = 0
        if (-not [int]::TryParse($choice, [ref]$selectedNum) -or $selectedNum -lt 1 -or $selectedNum -gt $accounts.Count) {
            Write-Host "Lua chon khong hop le." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }

        $target = $accounts[$selectedNum - 1]
        $targetLabel = $labels[$target]
        Write-Host ""
        Write-Host "--- Xem truoc (-DryRun) cho $targetLabel ($target) ---" -ForegroundColor Cyan
        & $sw -To $target -DryRun
        Write-Host ""

        $confirm = (Read-Host "Xac nhan chuyen sang $targetLabel ($target)? Go y de thuc hien (Enter de huy)").Trim()
        if ($confirm -match '^[Yy]$') {
            Write-Host ""
            & $sw -To $target
        } else {
            Write-Host "Da huy thao tac." -ForegroundColor DarkGray
        }

        Write-Host ""
        [void](Read-Host "Nhan Enter de quay lai menu")
    }
}
catch {
    Write-Host ""
    Write-Host "LOI: $($_.Exception.Message)" -ForegroundColor Red
    [void](Read-Host "Nhan Enter de dong")
    exit 1
}
