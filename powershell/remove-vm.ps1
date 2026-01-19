Param(
    [Parameter(Mandatory=$false)] [String]$VMName,
    [Parameter(Mandatory=$true)] [String]$VMsDir,
    [Parameter(Mandatory=$true)] [String]$ProjectRoot
)

. "$PSScriptRoot\utils\common.ps1"

Write-Host "--- Hyper-V & Zabbix Cleanup Manager (Safe Mode) ---" -ForegroundColor Cyan

# 1. VM Selection
if ([string]::IsNullOrWhiteSpace($VMName)) {
    $ExistingVMs = Get-VM
    if (-not $ExistingVMs) {
        Write-Host "No VMs left in the system to delete." -ForegroundColor Green
        exit
    }
    $ExistingVMs | Select-Object Name, State, Status | Format-Table
    $targetVM = Read-Host "Enter the name of the VM you want to DELETE"
    if ([string]::IsNullOrWhiteSpace($targetVM)) { exit }
} else {
    $targetVM = $VMName
}

# 2. Initial Check
$vmToDelete = Get-VM -Name $targetVM -ErrorAction SilentlyContinue
if (-not $vmToDelete) {
    Write-Host "Error: No VM found named '$targetVM'." -ForegroundColor Red
    exit
}

# ---------------------------------------------------------
#  STEP 1: CLEANUP IN ZABBIX VIA ANSIBLE (WSL)
# ---------------------------------------------------------

if ( $targetVM -ne "zabbix-server"){
    Write-Host "Starting deletion process for: $targetVM" -ForegroundColor Yellow
    Write-Host "Calling Ansible to remove host from Zabbix..." -ForegroundColor Magenta

    Invoke-Task "Preparing Playbook path" -Task {
        $AnsibleFile = Join-Path $ProjectRoot "playbooks\remove_zabbix_server.yml"
        $global:LinuxPlaybookPath = wsl wslpath -u "$AnsibleFile"
    }

    $fakeDbPath = Join-Path $PSScriptRoot "../../fake_db.yml"
    if (Test-Path $fakeDbPath) {
        $content = Get-Content $fakeDbPath -Raw
        if ($content -match 'zabbix_server_ip:\s*"?(\d{1,3}(\.\d{1,3}){3})"?') {
            $global:serverIP = $Matches[1]
        }
    }

    if (-not $global:serverIP) {
        Write-Host " [X] CRITICAL ERROR: Zabbix IP not found in fake_db.yml. Aborting." -ForegroundColor Red
        exit # <-- STOPS HERE
    }

    $Inventory = "$($global:serverIP),"
    $ansibleArgs = @(
        "ansible-playbook",
        "-i", "$Inventory",
        "-e", "VMName=$targetVM",
        "$global:LinuxPlaybookPath"
    )

    & wsl @ansibleArgs

    # ERROR CONTROL: If Ansible fails, we do NOT continue deleting the VM
    if ($LASTEXITCODE -ne 0) {
        Write-Host " [X] ERROR: Zabbix removal failed. The VM will NOT be deleted to maintain consistency." -ForegroundColor Red
        exit # <-- STOPS HERE
    }

    Write-Host " [+] Zabbix updated: Host removed." -ForegroundColor Green
} else {
    Write-Host " [i] Node '$VMName' detected as Server. Skipping infrastructure setup." -ForegroundColor Cyan
}


# ---------------------------------------------------------
#  STEP 2: HYPER-V VM CLEANUP (Only if Zabbix OK)
# ---------------------------------------------------------
if ($vmToDelete.State -eq 'Running') { 
    Write-Host "Stopping VM..." -ForegroundColor Gray
    Stop-VM -Name $targetVM -Force -TurnOff 
}

Remove-VM -Name $targetVM -Force
Write-Host "VM configuration removed from Hyper-V." -ForegroundColor Gray

# ---------------------------------------------------------
#  STEP 3: PHYSICAL FILE CLEANUP
# ---------------------------------------------------------
$vmPath = Join-Path $VMsDir $targetVM
if (Test-Path $vmPath) {
    Remove-Item -Path $vmPath -Recurse -Force
    Write-Host "Data folder deleted." -ForegroundColor Green
}

$IsoFile = Join-Path $CloudInitPath "$targetVM-seed.iso"
if (Test-Path $IsoFile) { Remove-Item -Path $IsoFile -Force }

try {
    if (Get-Command Remove-IPFromInventory -ErrorAction SilentlyContinue) {
        Remove-IPFromInventory -VMName $targetVM
        Write-Host "IP released in the inventory." -ForegroundColor Green
    }
} catch { }

Write-Host "Cleanup finished successfully." -ForegroundColor Cyan