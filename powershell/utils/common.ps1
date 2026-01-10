# ---------------------------------------------------------
# COMMON UTILITIES - Helper Functions for Infrastructure Tasks
# ---------------------------------------------------------

# 1. UI Formatting Functions
function Write-SectionHeader {
    param ([string]$Title)
    # Prints a formatted header for major script sections
    Write-Host "`n# ---------------------------------------------------------" -ForegroundColor Magenta
    Write-Host "# SECTION: $Title" -ForegroundColor Magenta
    Write-Host "# ---------------------------------------------------------" -ForegroundColor Magenta
}

# 2. Main Task Wrapper with Error Handling
function Invoke-Task {
    param (
        [string]$Label,
        [scriptblock]$Task
    )
    # Display task starting status
    Write-Host " [ ] $Label... " -NoNewline -ForegroundColor Yellow
    try {
        # Execute the provided script block
        $result = &$Task
        
        # Overwrite yellow line with Green Success mark
        Write-Host "`r [V] $Label   " -ForegroundColor Green
        return $result
    } catch {
        # Overwrite yellow line with Red Failure mark
        Write-Host "`r [X] $Label   " -ForegroundColor Red
        Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
        
        # Stop execution and wait for user input to prevent window closing
        Invoke-VMRollback -VMName $VMName -VMDir $VMDir -ScriptRoot $PSScriptRoot
    }
}

# 3. Environment Check Helpers
function Test-IsAdministrator {
    # Check if the current session has Elevated (Admin) privileges
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-VMExternalIP {
    param ([string]$VMName)
    # Attempt to retrieve the IPv4 address assigned to the VM via Hyper-V KVP
    $networkData = (Get-VM -Name $VMName).NetworkAdapters.IpAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
    return $networkData[0]
}

# ---------------------------------------------------------
Write-Host " [V] Common utilities loaded successfully." -ForegroundColor Cyan

# ---------------------------------------------------------
# NETWORK UTILITIES - common.ps1
# ---------------------------------------------------------

function Get-VMIPAddress {
    param(
        [Parameter(Mandatory=$true)] [string]$VMName,
        [Parameter(Mandatory=$false)] [int]$TimeoutSeconds = 400
    )

    
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $ip = $null

        while ($null -eq $ip -and $timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            # Consultamos el adaptador de red de Hyper-V
            $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        
            if ($vm) {
                # Filtramos: debe ser IPv4, no ser 0.0.0.0 y no estar vacía
                $ip = $vm.NetworkAdapters.IPAddresses | Where-Object { 
                    $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -ne "0.0.0.0" 
                } | Select-Object -First 1
            }

            if ($null -eq $ip) {
                $elapsed = [math]::Round($timer.Elapsed.TotalSeconds)
                Write-Host ("`r [i] Esperando IP ({0}s / {1}s)... " -f $elapsed, $TimeoutSeconds) -NoNewline -ForegroundColor Gray
                Start-Sleep -Seconds 2
            }
        }

        Write-Host "" # Salto de línea tras el contador

        if ($null -ne $ip) {
        $objetoSalida = [PSCustomObject]@{
            Status = "Success"
            IP     = [string]$ip
            Time   = $totalTime
        }
    } else {
        $objetoSalida = [PSCustomObject]@{
            Status = "Failed"
            IP     = $null
            Time   = $totalTime
        }
    }

    Write-Host "" 
    return $objetoSalida
    }
    



function Invoke-VMRollback {
    param(
        [Parameter(Mandatory=$true)] [string]$VMName,
        [Parameter(Mandatory=$false)] [string]$VMDir,
        [Parameter(Mandatory=$false)] [string]$ScriptRoot
    )

    # Usamos tu estilo visual para anunciar el fallo
    Write-Host "`n [X] DESPLIEGUE FALLIDO" -ForegroundColor Red
    Write-Host " [!] Iniciando limpieza automática... " -ForegroundColor Yellow

    $RemoveScript = Join-Path $ScriptRoot "remove-vm.ps1"

    if (Test-Path $RemoveScript) {
        # Ejecutamos el script de remoción
        & $RemoveScript -VMName $VMName
        Write-Host " [V] Rollback completado mediante script. " -ForegroundColor Green
    } else {
        # Fallback manual con tu diseño
        Write-Host " [!] Script de remoción no encontrado. Limpiando manualmente... " -ForegroundColor Yellow
        
        if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
            Stop-VM -Name $VMName -Force -TurnOff -ErrorAction SilentlyContinue
            Remove-VM -Name $VMName -Force -Confirm:$false
        }
        if ($VMDir -and (Test-Path $VMDir)) {
            Remove-Item $VMDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host " [V] Limpieza manual finalizada. " -ForegroundColor Green
    }
    
    # Terminamos la ejecución para que no intente seguir con el main.ps1
    exit
}