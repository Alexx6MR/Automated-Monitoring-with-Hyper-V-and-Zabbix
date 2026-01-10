Param(
    [Parameter(Mandatory=$false)] [String]$VMName
)

. "$PSScriptRoot\utils\config.ps1"
. "$PSScriptRoot\utils\common.ps1"

Write-Host "--- Gestor de Limpieza Hyper-V ---" -ForegroundColor Cyan

# 1. Lógica de selección de VM
if ([string]::IsNullOrWhiteSpace($VMName)) {
    # MODO INTERACTIVO: No se pasó parámetro, preguntamos al usuario
    $ExistingVMs = Get-VM
    if (-not $ExistingVMs) {
        Write-Host "No quedan VMs en el sistema para eliminar." -ForegroundColor Green
        exit
    }
    
    Write-Host "`nEstado actual de las VMs:" -ForegroundColor White
    $ExistingVMs | Select-Object Name, State, Status | Format-Table
    
    $targetVM = Read-Host "Escribe el nombre de la VM que quieres ELIMINAR (o presiona Enter para salir)"
    if ([string]::IsNullOrWhiteSpace($targetVM)) { exit }
} else {
    # MODO AUTOMÁTICO: Se recibió el parámetro (útil para el rollback)
    $targetVM = $VMName
}

# 2. Proceso de eliminación
$vmToDelete = Get-VM -Name $targetVM -ErrorAction SilentlyContinue

if ($vmToDelete) {
    Write-Host "Iniciando proceso de eliminacion para: $targetVM" -ForegroundColor Yellow
    
    # Detener si esta corriendo
    if ($vmToDelete.State -eq 'Running') { 
        Write-Host "Deteniendo VM..." -ForegroundColor Gray
        Stop-VM -Name $targetVM -Force -TurnOff 
    }

    # Capturar rutas de carpetas (Configuración y Discos)
    $pathsToDelete = @()
    # Usamos la carpeta principal de la VM
    $pathsToDelete += Join-Path $VMsDir $targetVM
    $uniquePaths = $pathsToDelete | Select-Object -Unique

    # Eliminar de Hyper-V
    Remove-VM -Name $targetVM -Force
    Write-Host "Configuracion de VM eliminada de Hyper-V." -ForegroundColor Gray
    
    # Limpieza fisica de archivos
    Start-Sleep -Seconds 2
    foreach ($path in $uniquePaths) {
        if (Test-Path $path) {
            try {
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                Write-Host "Carpeta de datos eliminada: $path" -ForegroundColor Green
            } catch {
                Write-Host "Aviso: No se pudo borrar la carpeta $path. Puede que algún archivo esté bloqueado." -ForegroundColor Yellow
            }
        }
    }

    # Limpieza de ISO CLOUD-INIT
    $IsoFile = Join-Path $CloudInitPath "$targetVM-seed.iso"
    if (Test-Path $IsoFile) {
        try {
            Remove-Item -Path $IsoFile -Force -ErrorAction Stop
            Write-Host "Archivo ISO eliminado: $IsoFile" -ForegroundColor Green
        } catch {
            Write-Host "Aviso: No se pudo eliminar el archivo ISO." -ForegroundColor Yellow
        }
    }

    # Limpieza de inventario de IP
    try {
        if (Get-Command Remove-IPFromInventory -ErrorAction SilentlyContinue) {
            Remove-IPFromInventory -VMName $targetVM
            Write-Host "IP liberada en el inventario para: $targetVM" -ForegroundColor Green
        }
    } catch {
        Write-Host "Aviso: No se pudo limpiar la IP del inventario." -ForegroundColor Yellow
    }

} else {
    Write-Host "Error: No existe una VM llamada '$targetVM'." -ForegroundColor Red
}

Write-Host "Limpieza finalizada." -ForegroundColor Cyan