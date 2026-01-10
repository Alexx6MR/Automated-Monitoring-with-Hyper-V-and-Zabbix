<#
.SYNOPSIS
    Professional VM Provisioning Script - Fully Parameterized for AlmaLinux 10.
#>

Param(
    # --- VM Hardware Specs ---
    [Parameter(Mandatory=$true)] [String]$VMName,
    [Parameter(Mandatory=$false)] [Int]$VMCpu = 2,
    [Parameter(Mandatory=$false)] [Int64]$VMMemoryBytes = 2GB,
    [Parameter(Mandatory=$false)] [Int]$VMGeneration = 2,
    [Parameter(Mandatory=$false)] [String]$SwitchName = "External-Zabbix-Network",

    # --- Infrastructure Paths ---
    [Parameter(Mandatory=$true)] [String]$TemplatesDir,
    [Parameter(Mandatory=$true)] [String]$TemplatePath,   # El .vhdx final
    [Parameter(Mandatory=$true)] [String]$TemplateUrl,    # La URL del .qcow2
    [Parameter(Mandatory=$true)] [String]$VMsDir,
    [Parameter(Mandatory=$true)] [String]$CloudInitPath,
    [Parameter(Mandatory=$true)] [String]$PrivKey,
    [Parameter(Mandatory=$true)] [String]$UserDataTemplateScript,
    [Parameter(Mandatory=$true)] [String]$MetaDataTemplateScript
)

. "$PSScriptRoot\utils\common.ps1"
$ErrorActionPreference = "Stop"

# --- DEFINICIÓN DE RUTAS INTERNAS (CORRECCIÓN AQUÍ) ---
$QcowPath = Join-Path $TemplatesDir "almalinux-10-temp.qcow2" # Definimos la variable que faltaba
$IsoFile  = Join-Path $CloudInitPath "$VMName-seed.iso"

try {

    # ---------------------------------------------------------
    # SECTION 0: Validations
    # ---------------------------------------------------------

    
    
    # ---------------------------------------------------------
    # SECTION 1: Template Management (Auto-Download & Convert)
    # ---------------------------------------------------------
    Write-SectionHeader -Title "Template Management (via WSL)"

    if (-not (Test-Path $TemplatePath)) {
    Invoke-Task "Processing AlmaLinux 10 Image via WSL" {
        if (-not (Test-Path $TemplatesDir)) { New-Item -ItemType Directory -Path $TemplatesDir -Force | Out-Null }

        # 1. Descarga del QCOW2
        if (-not (Test-Path $QcowPath)) {
            Write-Host " [>] Downloading QCOW2..." -ForegroundColor Gray
            Invoke-WebRequest -Uri $TemplateUrl -OutFile $QcowPath -ErrorAction Stop
        }

        # 2. Asegurar que WSL tenga qemu-utils
        Write-Host " [>] Preparing WSL environment..." -ForegroundColor Gray
        wsl sudo apt-get update -y | Out-Null
        wsl sudo apt-get install qemu-utils -y | Out-Null

        # 3. Conversión usando rutas de WSL
        Write-Host " [>] Converting QCOW2 to VHDX via WSL..." -ForegroundColor Gray
        
        # Convertimos las rutas de Windows (C:\...) a rutas de Linux (/mnt/c/...)
        $wslSource = wsl wslpath "$QcowPath"
        $wslDest   = wsl wslpath "$TemplatePath"

        # Ejecutamos la conversión dentro de WSL
        wsl qemu-img convert -f qcow2 -O vhdx -o subformat=dynamic "$wslSource" "$wslDest"

        if ($LASTEXITCODE -ne 0) {
            throw "Error: La conversión en WSL falló."
        }

        # 4. Limpieza
        Remove-Item $QcowPath -Force
        Write-Host " [>] Template ready: $TemplatePath" -ForegroundColor Green
    }
}

    # ---------------------------------------------------------
    # SECTION 2: Cloud-Init (Cambiado a usuario almalinux)
    # ---------------------------------------------------------
    Write-SectionHeader -Title "Cloud-Init Generation"

    Invoke-Task "Generating SSH Keys & Seed ISO" {
        if (-not (Test-Path $PrivKey)) { 
            ssh-keygen -t ed25519 -N '""' -f "$PrivKey" -q 
        }
        $PubKeyContent = (Get-Content "$PrivKey.pub").Trim()
        
        $UserDataYAML = & $UserDataTemplateScript -SSHKey $PubKeyContent -VMName $VMName
        $MetaDataYAML = & $MetaDataTemplateScript -VMName $VMName
        
        $TempUserData = Join-Path $CloudInitPath "user-data"
        $TempMetaData = Join-Path $CloudInitPath "meta-data"
        
        $UserDataYAML | Out-File -FilePath $TempUserData -Encoding ASCII -Force
        $MetaDataYAML | Out-File -FilePath $TempMetaData -Encoding ASCII -Force

        # ISO vía WSL
        $wslSource = wsl wslpath "$CloudInitPath"
        $wslTarget = wsl wslpath "$IsoFile"
        wsl genisoimage -output "$wslTarget" -volid cidata -joliet -rock -graft-points "user-data=$wslSource/user-data" "meta-data=$wslSource/meta-data"
        
        Remove-Item $TempUserData, $TempMetaData -Force
    }

    # ---------------------------------------------------------
    # SECTION 3: Infrastructure & Deployment
    # ---------------------------------------------------------
    Write-SectionHeader -Title "Deploying VM: $VMName"
    $VMDir = Join-Path $VMsDir $VMName
    $NewVHDPath = Join-Path $VMDir "$VMName.vhdx"

    Invoke-Task "Creating Virtual Machine" {
        if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { 
            Stop-VM -Name $VMName -Force -TurnOff -ErrorAction SilentlyContinue
            Remove-VM -Name $VMName -Force
        }
        if (Test-Path $VMDir) { Remove-Item $VMDir -Recurse -Force }
        New-Item -ItemType Directory -Path $VMDir -Force | Out-Null

        # Disco Diferencial
        New-VHD -ParentPath $TemplatePath -Path $NewVHDPath -Differencing | Out-Null

        $vm = New-VM -Name $VMName -MemoryStartupBytes $VMMemoryBytes -Generation $VMGeneration -VHDPath $NewVHDPath -SwitchName $SwitchName -Path $VMsDir
        
        Set-VMProcessor -VMName $VMName -Count $VMCpu
        # IMPORTANTE: Para AlmaLinux 10 en Hyper-V local, a veces es mejor usar el template de Microsoft
        Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

        Add-VMDvdDrive -VM $vm -Path $IsoFile -ControllerNumber 0 -ControllerLocation 1
        
        $vhdDrive = Get-VMHardDiskDrive -VMName $VMName
        $dvdDrive = Get-VMDvdDrive -VMName $VMName
        Set-VMFirmware -VM $vm -BootOrder $vhdDrive, $dvdDrive
        
        Start-VM -Name $VMName
    }
}
catch {
    Write-Host " [!] Error detectado: $($_.Exception.Message)" -ForegroundColor Red
    # Invoke-VMRollback ... (tu función de limpieza)
    exit
}

# --- NOTA FINAL ---
# Recuerda que el usuario es ALMALINUX, no ubuntu.
Write-Host "`n [SUCCESS] VM desplegada" -ForegroundColor Green


