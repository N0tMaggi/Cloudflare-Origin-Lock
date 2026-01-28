$ErrorActionPreference = 'Stop'

# Cloudflare Origin Lock for Windows Server (Windows Defender Firewall)
# Restricts inbound TCP 80/443 to Cloudflare edge IPs. Actions: apply | update | revert | status

$V4Url = 'https://www.cloudflare.com/ips-v4'
$V6Url = 'https://www.cloudflare.com/ips-v6'
$Ports = '80,443'
$GroupName = 'Cloudflare Origin Lock'
$AllowRuleName = 'CF-Origin-Lock-Allow'
$BlockRuleName = 'CF-Origin-Lock-Block'
$StateDir = Join-Path $env:ProgramData 'Cloudflare-Origin-Lock'
$Marker = Join-Path $StateDir 'installed.txt'
$LockName = 'Global\CloudflareOriginLock'

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

function Require-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error 'Run from an elevated PowerShell / Administrator shell.'
        exit 1
    }
}

function Acquire-Lock {
    $script:mutex = New-Object System.Threading.Mutex($false, $LockName)
    if (-not $script:mutex.WaitOne(0)) {
        Write-Error 'Another cloudflare-origin-lock instance is running.'
        exit 1
    }
}

function Release-Lock {
    if ($script:mutex) { $script:mutex.ReleaseMutex() | Out-Null }
}

function Fetch-List {
    param($Url)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (Invoke-WebRequest -UseBasicParsing -Uri $Url).Content -split "`n" |
        Where-Object { $_ -match '\S' } |
        ForEach-Object { $_.Trim() }
}

function Get-CloudflareIps {
    $v4 = Fetch-List $V4Url
    $v6 = Fetch-List $V6Url
    if ($v4.Count -lt 5 -or $v6.Count -lt 5) {
        throw 'Validation failed: Cloudflare lists look too short.'
    }
    [PSCustomObject]@{
        All = $v4 + $v6
        V4  = $v4
        V6  = $v6
    }
}

function Remove-ExistingRules {
    Get-NetFirewallRule -Group $GroupName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

function New-AllowRule {
    param([string[]]$RemoteAddresses)
    New-NetFirewallRule `
        -DisplayName $AllowRuleName `
        -Group $GroupName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Ports `
        -RemoteAddress $RemoteAddresses `
        -Profile Any `
        -Enabled True `
        -OverrideBlockRules $true `
        -PolicyStore ActiveStore | Out-Null
}

function New-BlockRule {
    New-NetFirewallRule `
        -DisplayName $BlockRuleName `
        -Group $GroupName `
        -Direction Inbound `
        -Action Block `
        -Protocol TCP `
        -LocalPort $Ports `
        -RemoteAddress Any `
        -Profile Any `
        -Enabled True `
        -PolicyStore ActiveStore | Out-Null
}

function Write-Marker {
    Get-Date -Format o | Out-File -Encoding ASCII -FilePath $Marker -Force
}

function Apply-Rules {
    Remove-ExistingRules
    $ips = Get-CloudflareIps
    New-AllowRule -RemoteAddresses $ips.All
    New-BlockRule
    Write-Marker
    Write-Host '✅ Apply complete — only Cloudflare IPs can reach TCP 80/443.'
}

function Update-Rules {
    if (-not (Test-Path $Marker)) { throw 'Not installed. Run apply first.' }
    Apply-Rules
}

function Revert-Rules {
    Remove-ExistingRules
    Remove-Item $Marker -ErrorAction SilentlyContinue
    Write-Host '✅ Revert complete — Cloudflare origin lock removed.'
}

function Status-Rules {
    Write-Host '=== Cloudflare Origin Lock Status (Windows Firewall) ==='
    if (Test-Path $Marker) {
        Write-Host ("Installed on: {0}" -f (Get-Content $Marker -Raw).Trim())
    } else {
        Write-Host 'Not installed (no marker).'
    }
    $allow = Get-NetFirewallRule -DisplayName $AllowRuleName -ErrorAction SilentlyContinue
    $block = Get-NetFirewallRule -DisplayName $BlockRuleName -ErrorAction SilentlyContinue
    if (-not $allow -and -not $block) { return }

    if ($allow) {
        $addr = (Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $AllowRuleName -ErrorAction SilentlyContinue).RemoteAddress
        Write-Host ("Allow rule: {0} addresses, ports {1}" -f ($addr.Count), $Ports)
        Write-Host ('First 10 addresses: ' + ($addr | Select-Object -First 10 -Join ', '))
    } else {
        Write-Host 'Allow rule missing.'
    }
    if ($block) {
        Write-Host 'Block rule present for TCP 80/443 (remote: Any).'
    } else {
        Write-Host 'Block rule missing.'
    }
}

function Show-Usage {
    Write-Host @"
Cloudflare Origin Lock (Windows)

Usage:
  cloudflare-origin-lock.bat apply   # create allow/block rules
  cloudflare-origin-lock.bat update  # refresh Cloudflare IP ranges
  cloudflare-origin-lock.bat revert  # remove rules
  cloudflare-origin-lock.bat status  # show current state
"@
}

try {
    Require-Admin
    Acquire-Lock

    if (-not $args.Count) { Show-Usage; exit 1 }
    switch ($args[0].ToLowerInvariant()) {
        'apply'  { Apply-Rules }
        'update' { Update-Rules }
        'revert' { Revert-Rules }
        'status' { Status-Rules }
        'help'   { Show-Usage }
        default  { Show-Usage; exit 1 }
    }
} catch {
    Write-Error $_
    exit 1
} finally {
    Release-Lock
}
