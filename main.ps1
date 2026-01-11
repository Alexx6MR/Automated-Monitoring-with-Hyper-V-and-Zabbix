# ---------------------------------------------------------
# 1. Load Configurations and Utilities
# ---------------------------------------------------------
$ProjectRoot = Get-Location

# IMPORTANTE: Dot Sourcing (. espacio ruta)
# Esto "copia y pega" las funciones en la memoria del script actual
. "$PSScriptRoot\powershell\utils\common.ps1"
. "$PSScriptRoot\powershell\utils\config.ps1"

$ErrorActionPreference = "Stop"
$CreateVmScript = Join-Path $PowershellDir "create-vm.ps1"
$ProgressPreference = 'SilentlyContinue'

# --- BANNER ---
Clear-Host
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "          WELCOME TO VM AUTOMATION TOOL" -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "            Created by Alexei Martinez" -ForegroundColor Yellow
Write-Host "==========================================================`n" -ForegroundColor Cyan

# --- Initial Infrastructure Check ---
Invoke-Task "Checking Zabbix-Server Status" -SkipCondition ([bool](Get-VM -Name "zabbix-server" -ErrorAction SilentlyContinue)) -Task {
    $global:ZabbixVM = Get-VM -Name "zabbix-server" -ErrorAction SilentlyContinue
}

if ($global:ZabbixVM) {
    Write-Host " [+] zabbix-server found in the system." -ForegroundColor Green
    # Intentamos obtener su IP sin el event listener largo, solo una consulta rápida
    $ZabbixIP = $global:ZabbixVM.NetworkAdapters.IPAddresses | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
    if ($ZabbixIP) {
        Write-Host " [>] Management IP: $ZabbixIP" -ForegroundColor Cyan
    } else {
        Write-Host " [!] VM is present but IP is not yet assigned." -ForegroundColor Yellow
    }
} else {
    Write-Host " [-] zabbix-server is not installed in this system." -ForegroundColor DarkYellow
}
Write-Host "`n----------------------------------------------------------"

# ---------------------------------------------------------
# MENU LOOP
# ---------------------------------------------------------
do {
    Write-Host "`n SELECT AN OPTION:" -ForegroundColor White
    Write-Host " 1. Deploy Zabbix-Server (VM + Ansible)"
    Write-Host " 2. Create Node VMs"
    Write-Host " 3. Delete VMs"
    Write-Host " 4. Exit"
    
    $Choice = Read-Host "`n -> Choice"

    switch ($Choice) {
        "1" {
            Write-SectionHeader -Title "DEPLOYING ZABBIX-SERVER"

            $existingVM = Get-VM -Name "zabbix-server" -ErrorAction SilentlyContinue

            if ($existingVM) {
                # --- ESCENARIO A: LA VM YA EXISTE ---
                Write-Host " [+] zabbix-server already exists. Fetching connection details..." -ForegroundColor Cyan
        
                # Intentamos obtener la IP actual de la VM
                $ZabbixIP = $existingVM.NetworkAdapters.IPAddresses | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
        
                if ($ZabbixIP) {
                    $global:serverIP = $ZabbixIP
                } else {
                    # Si no tiene IP (está apagada o cargando), ejecutamos la tarea de espera
                    Invoke-Task "Waiting for Network/IP Assignment" -Task {
                        $res = Get-VMIPAddress -VMName "zabbix-server"
                        if ($res.Status -eq "Success") { $global:serverIP = $res.IP } else { throw "No se pudo obtener la IP." }
                    }
                }   
                if ($null -ne $global:serverIP) {
                  &  Show-ZabbixServerBox -IP $global:serverIP
                } else {
                    Write-Host " [X] Error: No se pudo determinar la IP del servidor Zabbix." -ForegroundColor Red
                }
                
            }else{

                #Paso 1: Ejecutar el script de creación atómica
                Invoke-Task "Provisioning Virtual Machine" -SkipCondition ([bool](Get-VM -Name "zabbix-server" -ErrorAction SilentlyContinue)) -Task {
                    & $CreateVmScript -VMName "zabbix-server" `
                        -TemplatesDir $TemplatesDir -TemplatePath $TemplatePath -TemplateUrl $TemplateUrl `
                        -VMsDir $VMsDir -CloudInitPath $CloudInitPath -PrivKey $PrivKey `
                        -UserDataTemplateScript $UserDataTemplateScript -MetaDataTemplateScript $MetaDataTemplateScript

                        if ($LASTEXITCODE -ne 0) { throw "El aprovisionamiento de la VM falló. Abortando despliegue." }
                }

                #Paso 2: Obtener IP (con reintentos internos)
                Invoke-Task "Waiting for Network/IP Assignment" -Task {
                    $res = Get-VMIPAddress -VMName "zabbix-server"
                    if ($res.Status -eq "Success") { $global:serverIP = $res.IP } else { throw "No se pudo obtener la IP." }
                }

                Write-SectionHeader -Title "ANSIBLE CONFIGURATIONS"

                # Paso 3: Configurar Ansible
                Invoke-Task "Preparing Ansible Environment" -Task {
                    $AnsibleFile = Join-Path $ProjectRoot "ansible\playbooks\install_zabbix_server.yml"
                    $global:LinuxPlaybookPath = wsl wslpath -u "$AnsibleFile"
                    $global:LinuxInventoryPath = wsl wslpath -u "$ProjectRoot\ansible\hosts"
                }

                # Paso 4: Ejecución de Ansible
                Invoke-Task "Executing Ansible Playbook (Zabbix Installation)" -Task {

                    if ([string]::IsNullOrWhiteSpace($global:serverIP)) { throw "La IP del servidor es nula o vacía." }
                    if ([string]::IsNullOrWhiteSpace($global:LinuxPlaybookPath)) { throw "Error: Ruta del Playbook no definida." }
                    # Usamos la IP detectada dinámicamente

                    $Inventory = "$($global:serverIP),"

                    $ansibleArgs = @(
                        "ansible-playbook",
                        "-i", "$Inventory",
                        "-e", "ansible_host=$global:serverIP",
                        "-e", "ansible_user=deploy",
                        "-e", "ansible_ssh_private_key_file=~/.ssh/deploy_key",
                        "-e", "ansible_ssh_common_args='-o StrictHostKeyChecking=no'",
                        "-e", "target_hosts=all",
                        "$global:LinuxPlaybookPath"
                    )
                
                    & wsl @ansibleArgs
                
                    $exitCode = $LASTEXITCODE

                    if ($exitCode -ne 0) {
                        throw "Ansible terminó con errores (Exit Code: $exitCode)."
                    }
                }

                # Paso final: Mostrar credenciales en una caja
                [Console]::ResetColor()
                Show-ZabbixServerBox -IP $global:serverIP
                
            }
        }
        "2" {
            $RawInput = Read-Host "`n -> How many VMs do you want to create?"
            if ($RawInput -as [int]) {
                $Count = [int]$RawInput
                for ($i = 1; $i -le $Count; $i++) {
                    $ChosenName = "Zabbix-Node-$i"
                    Write-SectionHeader -Title "Deploying $ChosenName"
                    
                    Invoke-Task "Creating VM: $ChosenName" -Task {
                        & $CreateVmScript -VMName $ChosenName -TemplatesDir $TemplatesDir -TemplatePath $TemplatePath -TemplateUrl $TemplateUrl -VMsDir $VMsDir -CloudInitPath $CloudInitPath -PrivKey $PrivKey -UserDataTemplateScript $UserDataTemplateScript -MetaDataTemplateScript $MetaDataTemplateScript
                    }
                    
                    Invoke-Task "Verifying Network for $ChosenName" -Task {
                        Get-VMIPAddress -VMName $ChosenName
                    }
                }
            }
        }

        "3" {
            Write-SectionHeader -Title "CLEANUP INFRASTRUCTURE"
          
            $RemoveVmScript = Join-Path $PowershellDir "remove-vm.ps1"
            & $RemoveVmScript
            
        }

        "4" {
            Write-Host " Exiting... Goodbye Alexei!" -ForegroundColor Cyan
            break
        }

        Default {
            Write-Host " [!] Invalid option." -ForegroundColor Yellow
        }
    }
} while ($Choice -ne "4")