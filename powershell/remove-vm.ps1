Param(
    [Parameter(Mandatory=$false)] [String]$VMName
)

. "$PSScriptRoot\utils\config.ps1"
. "$PSScriptRoot\utils\common.ps1"

Write-Host "--- Gestor de Limpieza Hyper-V & Zabbix (Safe Mode) ---" -ForegroundColor Cyan

# 1. Selección de VM
if ([string]::IsNullOrWhiteSpace($VMName)) {
    $ExistingVMs = Get-VM
    if (-not $ExistingVMs) {
        Write-Host "No quedan VMs en el sistema para eliminar." -ForegroundColor Green
        exit
    }
    $ExistingVMs | Select-Object Name, State, Status | Format-Table
    $targetVM = Read-Host "Escribe el nombre de la VM que quieres ELIMINAR"
    if ([string]::IsNullOrWhiteSpace($targetVM)) { exit }
} else {
    $targetVM = $VMName
}

# 2. Comprobación inicial
$vmToDelete = Get-VM -Name $targetVM -ErrorAction SilentlyContinue
if (-not $vmToDelete) {
    Write-Host "Error: No existe una VM llamada '$targetVM'." -ForegroundColor Red
    exit
}

# ---------------------------------------------------------
#  PASO 1: LIMPIEZA EN ZABBIX VÍA ANSIBLE (WSL)
# ---------------------------------------------------------
Write-Host "Iniciando proceso de eliminacion para: $targetVM" -ForegroundColor Yellow
Write-Host "Llamando a Ansible para eliminar host en Zabbix..." -ForegroundColor Magenta

Invoke-Task "Preparando ruta del Playbook" -Task {
    $AnsibleFile = Join-Path $ProjectRoot "playbooks\remove_host_zabbix.yml"
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
    Write-Host " [X] ERROR CRITICO: No se encontro la IP de Zabbix en fake_db.yml. Abortando." -ForegroundColor Red
    exit # <-- SE DETIENE AQUÍ
}

$Inventory = "$($global:serverIP),"
$ansibleArgs = @(
    "ansible-playbook",
    "-i", "$Inventory",
    "-e", "VMName=$targetVM",
    "$global:LinuxPlaybookPath"
)

& wsl @ansibleArgs

# CONTROL DE ERRORES: Si Ansible falla, NO seguimos borrando la VM
if ($LASTEXITCODE -ne 0) {
    Write-Host " [X] ERROR: El borrado en Zabbix ha fallado. La VM NO sera eliminada para mantener la consistencia." -ForegroundColor Red
    exit # <-- SE DETIENE AQUÍ
}

Write-Host " [+] Zabbix actualizado: Host eliminado." -ForegroundColor Green

# ---------------------------------------------------------
#  PASO 2: LIMPIEZA DE LA VM DE HYPER-V (Solo si Zabbix OK)
# ---------------------------------------------------------
if ($vmToDelete.State -eq 'Running') { 
    Write-Host "Deteniendo VM..." -ForegroundColor Gray
    Stop-VM -Name $targetVM -Force -TurnOff 
}

Remove-VM -Name $targetVM -Force
Write-Host "Configuracion de VM eliminada de Hyper-V." -ForegroundColor Gray

# ---------------------------------------------------------
#  PASO 3: LIMPIEZA DE ARCHIVOS FISICOS
# ---------------------------------------------------------
$vmPath = Join-Path $VMsDir $targetVM
if (Test-Path $vmPath) {
    Remove-Item -Path $vmPath -Recurse -Force
    Write-Host "Carpeta de datos eliminada." -ForegroundColor Green
}

$IsoFile = Join-Path $CloudInitPath "$targetVM-seed.iso"
if (Test-Path $IsoFile) { Remove-Item -Path $IsoFile -Force }

try {
    if (Get-Command Remove-IPFromInventory -ErrorAction SilentlyContinue) {
        Remove-IPFromInventory -VMName $targetVM
        Write-Host "IP liberada en el inventario." -ForegroundColor Green
    }
} catch { }

Write-Host "Limpieza finalizada con exito." -ForegroundColor Cyan