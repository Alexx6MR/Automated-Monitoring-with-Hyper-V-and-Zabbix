# ---------------------------------------------------------
# COMMON UTILITIES - Helper Functions for Infrastructure Tasks
# ---------------------------------------------------------

# 1. UI Formatting Functions
function Write-SectionHeader {
    param ([string]$Title)
    Write-Host "`n# ---------------------------------------------------------" -ForegroundColor Magenta
    Write-Host "# SECTION: $Title" -ForegroundColor Magenta
    Write-Host "# ---------------------------------------------------------" -ForegroundColor Magenta
}

# 2. Main Task Wrapper with smooth output
function Invoke-Task {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)] [String]$Label,
        [Parameter(Mandatory=$true)] [ScriptBlock]$Task,
        [Parameter(Mandatory=$false)] [Bool]$SkipCondition = $false
    )

    $Success = " [V]"
    $Failure = " [X]"
    $Pending = " [ ]"

    if ($SkipCondition) {
        Write-Host "$Success $Label" -ForegroundColor Green
        return
    }

    Write-Host "$Pending $Label..." -NoNewline -ForegroundColor Gray

    try {
        # Out-Null is removed to allow Ansible and other scripts to display progress
        & $Task 
        Write-Host "`r$Success $Label" -ForegroundColor Green
    }
    catch {
        Write-Host "`r$Failure $Label" -ForegroundColor Red
        Write-Host "`n" + ("=" * 60) -ForegroundColor Red
        Write-Host " FATAL ERROR IN STEP: [$Label]" -ForegroundColor Red
        Write-Host " DETAIL: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host ("=" * 60) + "`n" -ForegroundColor Red
        exit 1
    }
}

# 3. Network Utilities
function Get-VMIPAddress {
    param(
        [Parameter(Mandatory=$true)] [string]$VMName,
        [Parameter(Mandatory=$false)] [int]$TimeoutSeconds = 400
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $ip = $null

    while ($null -eq $ip -and $timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ($vm) {
            $ip = $vm.NetworkAdapters.IPAddresses | Where-Object { 
                $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -ne "0.0.0.0" 
            } | Select-Object -First 1
        }

        if ($null -eq $ip) {
            $elapsed = [math]::Round($timer.Elapsed.TotalSeconds)
            Write-Host ("`r [i] Waiting for IP ({0}s / {1}s)... " -f $elapsed, $TimeoutSeconds) -NoNewline -ForegroundColor Gray
            Start-Sleep -Seconds 2
        }
    }

    Write-Host "" 
    $totalTimeSpent = [math]::Round($timer.Elapsed.TotalSeconds)

    if ($null -ne $ip) {
        return [PSCustomObject]@{ Status = "Success"; IP = [string]$ip; Time = $totalTimeSpent }
    } else {
        return [PSCustomObject]@{ Status = "Failed"; IP = $null; Time = $totalTimeSpent }
    }
}

# 4. Credential Box UI
function Show-ZabbixServerBox {
    param (
        [Parameter(Mandatory=$false)] [String]$IP = "192.168.1.0",
        [Parameter(Mandatory=$false)] [String]$WebUser = "Admin",
        [Parameter(Mandatory=$false)] [String]$WebPass = "zabbix"
    )

    $Color = "Cyan"
    $Url = "http://$IP/zabbix"
    $Width = 40

    Write-Host "`n# ---------------------------------------------------------" -ForegroundColor $Color
    Write-Host "# ZABBIX SERVER DASHBOARD" -ForegroundColor $Color
    Write-Host "# ---------------------------------------------------------" -ForegroundColor $Color
    Write-Host "#  URL:      $($Url.PadRight($Width)) #" -ForegroundColor White
    Write-Host "#  User:     $($WebUser.PadRight($Width)) #" -ForegroundColor White
    Write-Host "#  Password: $($WebPass.PadRight($Width)) #" -ForegroundColor White
    Write-Host "# ---------------------------------------------------------" -ForegroundColor $Color
    Write-Host ""
}

function Show-NodeBox {
    param (
        [Parameter(Mandatory=$true)] [String]$VMName,
        [Parameter(Mandatory=$true)] [String]$IP,
        [Parameter(Mandatory=$false)] [String]$SSHUser = "deploy"
    )

    $Color = "Green"
    $Width = 40

    Write-Host "`n# ---------------------------------------------------------" -ForegroundColor $Color
    Write-Host "# NODE: $VMName" -ForegroundColor $Color
    Write-Host "# ---------------------------------------------------------" -ForegroundColor $Color
    Write-Host "#  Management IP: $($IP.PadRight($Width - 9)) #" -ForegroundColor White
    Write-Host "#  SSH User:      $($SSHUser.PadRight($Width - 9)) #" -ForegroundColor White
    Write-Host "#  Auth Method:   SSH Private Key                         #" -ForegroundColor White
    Write-Host "# ---------------------------------------------------------" -ForegroundColor $Color
    Write-Host ""
}