# ---------------------------------------------------------
# CONFIGURATION FILE - Automated Infrastructure Lifecycle
# ---------------------------------------------------------

# 1. Project Paths
$ProjectRoot      = (Get-Item "$PSScriptRoot").Parent.Parent.FullName
$TemplatesDir     = Join-Path $ProjectRoot "templates"
$VMsDir           = Join-Path $ProjectRoot "vms" # Carpeta donde se instalan las VMs

# 2. Virtual Machine Configuration (Hyper-V)
# URL de la imagen Azure VHD (Ubuntu 25.10)
$TemplateUrl      = "https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"
# Archivos de la imagen base
$QcowPath         = Join-Path $TemplatesDir "almalinux-10.qcow2"
$TemplatePath     = Join-Path $TemplatesDir "almalinux-10-base.vhdx"

# Ruta del disco de la nueva VM (Se instala en la carpeta vms)
$VHDXPath         = Join-Path $VMsDir "$VMName.vhdx"

$SwitchName       = "External-Zabbix"

# 3. Cloud-Init & Secrets
$CloudInitPath    = Join-Path $ProjectRoot "cloud-init"
$PowershellDir    = Join-Path $ProjectRoot "powershell"
$KeyDir           = Join-Path $PowershellDir "secrets"
$PrivKey          = Join-Path $KeyDir "deploy_key"
$UserDataTemplateScript = Join-Path $CloudInitPath "user-data.ps1"
$MetaDataTemplateScript = Join-Path $CloudInitPath "meta-data.ps1"
$IsoWindowsPath   = Join-Path $ProjectRoot "seed.iso"

# 5. Network & Ansible Settings
$NetworkAdapterName = "vEthernet ($SwitchName)"
$WslDistroName      = "Ubuntu" 
$AnsiblePlaybook    = "install_zabbix_server.yml"
$AnsibleInventory   = "./hosts"
$env:ANSIBLE_CONFIG_WRITABLE = "ignore"
$AnsiblePath = Join-Path $ProjectRoot "playbooks/install_zabbix_server.yml"
# ---------------------------------------------------------
Write-Host " [V] Configuration loaded. VMs will be installed in: $VMsDir" -ForegroundColor Cyan