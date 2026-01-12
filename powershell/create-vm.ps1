<#
.SYNOPSIS
    Professional VM Provisioning Script - Atomic Architecture for AlmaLinux 10.
#>

Param(
    [Parameter(Mandatory=$true)] [String]$VMName,
    [Parameter(Mandatory=$false)] [Int]$VMCpu = 2,
    [Parameter(Mandatory=$false)] [Int64]$VMMemoryBytes = 2GB,
    [Parameter(Mandatory=$false)] [Int]$VMGeneration = 2,
    [Parameter(Mandatory=$false)] [String]$SwitchName = "External-Zabbix-Network",
    [Parameter(Mandatory=$true)] [String]$TemplatesDir,
    [Parameter(Mandatory=$true)] [String]$TemplatePath,
    [Parameter(Mandatory=$true)] [String]$TemplateUrl,
    [Parameter(Mandatory=$true)] [String]$VMsDir,
    [Parameter(Mandatory=$true)] [String]$CloudInitPath,
    [Parameter(Mandatory=$true)] [String]$PrivKey,
    [Parameter(Mandatory=$true)] [String]$UserDataTemplateScript,
    [Parameter(Mandatory=$true)] [String]$MetaDataTemplateScript
)

. "$PSScriptRoot\utils\common.ps1"
$ErrorActionPreference = "Stop"

# --- RUTAS INTERNAS ---
$QcowPath   = Join-Path $TemplatesDir "almalinux-10-temp.qcow2"
$IsoFile    = Join-Path $CloudInitPath "$VMName-seed.iso"
$VMDir      = Join-Path $VMsDir $VMName
$NewVHDPath = Join-Path $VMDir "$VMName.vhdx"

# ---------------------------------------------------------
# SECTION 1: Template Management
# ---------------------------------------------------------
Write-SectionHeader -Title "1. Template Management"

Invoke-Task "Creating Templates Directory" -SkipCondition (Test-Path $TemplatesDir) -Task {
    New-Item -ItemType Directory -Path $TemplatesDir -Force
}

Invoke-Task "Downloading AlmaLinux 10 Image" -SkipCondition  ((Test-Path $QcowPath) -or (Test-Path $TemplatePath))  -Task {
    Invoke-WebRequest -Uri $TemplateUrl -OutFile $QcowPath
}

Invoke-Task "Checking and Installing QEMU Utilities in WSL" -Task {
    # Verificamos si qemu-img (parte de qemu-utils) existe
    $isInstalled = wsl which qemu-img
    
    if (-not $isInstalled) {
        Write-Host "qemu-utils no encontrado. Instalando..." -ForegroundColor Cyan
        wsl sudo apt-get update -y
        wsl sudo apt-get install qemu-utils -y
    } else {
        Write-Host "qemu-utils ya está instalado. Saltando paso." -ForegroundColor Green
    }
}

Invoke-Task "Converting QCOW2 to VHDX" -SkipCondition (Test-Path $TemplatePath) -Task {
    $wslSrc = wsl wslpath -u "$QcowPath"
    $wslDst = wsl wslpath -u "$TemplatePath"
    wsl qemu-img convert -f qcow2 -O vhdx -o subformat=dynamic "$wslSrc" "$wslDst"
}

Invoke-Task "Cleaning Temporary QCOW2 File" -SkipCondition (-not (Test-Path $QcowPath)) -Task {
    Remove-Item $QcowPath -Force
}

# ---------------------------------------------------------
# SECTION 2: Cloud-Init & Security
# ---------------------------------------------------------
Write-SectionHeader "2. Cloud-Init & Security"

# 1. Aseguramos la existencia de la pareja de llaves en Windows
Invoke-Task "Verifying SSH Key Pair" `
    -SkipCondition ([bool]((Test-Path $PrivKey) -and (Test-Path "$PrivKey.pub"))) `
    -Task {
        ssh-keygen -t ed25519 -N '""' -f "$PrivKey" -q
    }

# 2. Identificar rutas de WSL (Paso preparatorio silencioso)
$wslUser    = wsl whoami
$homeDir    = if ($wslUser -eq "root") { "/root" } else { "/home/$wslUser" }
$wslKeyPath = "$homeDir/.ssh/deploy_key"
$winKeyPathLinuxFormat = wsl wslpath -u "$PrivKey"

# 3. Comparar llaves (Determinar si hace falta sincronizar)
$needsSync = $true
Invoke-Task "Checking SSH Key Synchronization" -Task {
    $exists = wsl bash -c "[ -f $wslKeyPath ] && echo 'true' || echo 'false'"
    if ($exists -eq "true") {
        $winHash = (wsl md5sum "$winKeyPathLinuxFormat").Split(' ')[0]
        $wslHash = (wsl md5sum "$wslKeyPath").Split(' ')[0]
        if ($winHash -eq $wslHash) { $script:needsSync = $false }
    }
}

# 4. Sincronizar solo si es necesario
Invoke-Task "Syncing Private Key to WSL" -SkipCondition ([bool](-not $needsSync)) -Task {
    wsl bash -c "mkdir -p ~/.ssh && cp '$winKeyPathLinuxFormat' $wslKeyPath && chmod 600 $wslKeyPath"
    wsl sed -i 's/\r$//' $wslKeyPath
}

# 5. Generar y GUARDAR datos de Cloud-Init
$UserDataPath = Join-Path $CloudInitPath "user-data"
$MetaDataPath = Join-Path $CloudInitPath "meta-data"

Invoke-Task "Generating Cloud-Init YAML Data" -Task {
    $PubKey = (Get-Content "$PrivKey.pub").Trim()
    $UserDataYAML = & $UserDataTemplateScript -SSHKey $PubKey -VMName $VMName
    $MetaDataYAML = & $MetaDataTemplateScript -VMName $VMName
    
    # IMPORTANTE: Guardamos físicamente los archivos para genisoimage
    $UserDataYAML | Out-File -FilePath $UserDataPath -Encoding ASCII -Force
    $MetaDataYAML | Out-File -FilePath $MetaDataPath -Encoding ASCII -Force
}

# 6. Crear el ISO (Se borra y crea siempre para asegurar frescura)
if (Test-Path $IsoFile) { Remove-Item $IsoFile -Force }

Invoke-Task "Building Seed ISO (genisoimage)" -Task {
    $wslSource = wsl wslpath -u "$CloudInitPath"
    $wslTarget = wsl wslpath -u "$IsoFile"
    wsl genisoimage -output "$wslTarget" -volid cidata -joliet -rock -graft-points "user-data=$wslSource/user-data" "meta-data=$wslSource/meta-data"
}

# 7. Limpieza
Invoke-Task "Cleaning Cloud-Init Temp Files" -Task {
    Remove-Item -Path $UserDataPath, $MetaDataPath -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------
# SECTION 3: Infrastructure Deployment
# ---------------------------------------------------------
Write-SectionHeader -Title "3. Hyper-V Provisioning"

Invoke-Task "Stopping existing VM instance" -Task {
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { 
        Stop-VM -Name $VMName -Force -TurnOff -ErrorAction SilentlyContinue 
    }
}

Invoke-Task "Removing old VM registration" -Task {
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { 
        Remove-VM -Name $VMName -Force 
    }
}

Invoke-Task "Recreating VM Directory" -Task {
    if (Test-Path $VMDir) { Remove-Item $VMDir -Recurse -Force }
    New-Item -ItemType Directory -Path $VMDir -Force
}

Invoke-Task "Creating Differential VHDX" -Task {
    New-VHD -ParentPath $TemplatePath -Path $NewVHDPath -Differencing
}

Invoke-Task "Registering Virtual Machine" -Task {
    New-VM -Name $VMName -MemoryStartupBytes $VMMemoryBytes -Generation $VMGeneration -VHDPath $NewVHDPath -SwitchName $SwitchName -Path $VMsDir
}

Invoke-Task "Configuring CPU Cores" -Task {
    Set-VMProcessor -VMName $VMName -Count $VMCpu
}

Invoke-Task "Enabling Secure Boot (UEFI)" -Task {
    Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
}

Invoke-Task "Attaching Seed ISO to DVD Drive" -Task {
    Add-VMDvdDrive -VMName $VMName -Path $IsoFile -ControllerNumber 0 -ControllerLocation 1
}

Invoke-Task "Configuring Boot Order" -Task {
    $vhdDrive = Get-VMHardDiskDrive -VMName $VMName
    $dvdDrive = Get-VMDvdDrive -VMName $VMName
    Set-VMFirmware -VMName $VMName -BootOrder $vhdDrive, $dvdDrive
}

Invoke-Task "Powering On Virtual Machine" -Task {
    Start-VM -Name $VMName
}

Write-Host "`n [SUCCESS] $VMName is deployed and booting." -ForegroundColor Green