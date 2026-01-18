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

                Invoke-Task "Saving VM data in the database" -Task {
                    $content = "zabbix_server_ip: `"$global:serverIP`""
                    $content | Out-File -FilePath "./fake_db.yml" -Encoding UTF8
                }

                Write-SectionHeader -Title "ANSIBLE CONFIGURATIONS"

                # Paso 3: Configurar Ansible
                Invoke-Task "Preparing Ansible Environment" -Task {
                    $AnsibleFile = Join-Path $ProjectRoot "playbooks\install_zabbix_server.yml"
                    $global:LinuxPlaybookPath = wsl wslpath -u "$AnsibleFile"
                }

                # Paso 4: Ejecución de Ansible
                Invoke-Task "Executing Ansible Playbook (Zabbix Installation)" -Task {

                    # debug mode
                    if (-not $global:serverIP ) {
                        $global:serverIP = "192.168.1.77"
                    }

                    if ([string]::IsNullOrWhiteSpace($global:serverIP)) { throw "La IP del servidor es nula o vacía." }
                    if ([string]::IsNullOrWhiteSpace($global:LinuxPlaybookPath)) { throw "Error: Ruta del Playbook no definida." }
                    # Usamos la IP detectada dinámicamente

                    
                    $Inventory = "$($global:serverIP),"

                    $ansibleArgs = @(
                        "ansible-playbook",
                        "-i", "$Inventory",
                        "-e", "ansible_host=$global:serverIP",
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
            # 1. PLANIFICACIÓN (Recoger nombres)
            $RawInput = Read-Host "`n -> How many VMs do you want to create?"
            if ($RawInput -as [int]) {
                $Count = [int]$RawInput
                $PendingVMs = @() # Lista de nombres que aún no tienen IP

                for ($i = 1; $i -le $Count; $i++) {
                    $Name = Read-Host " -> Name for VM #$i"
                    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "Zabbix-Node-$i" }
                    $PendingVMs += $Name
                }

                # 2. CREACIÓN MASIVA
                Write-SectionHeader -Title "PHASE 1: PROVISIONING $Count VMs"
                foreach ($Name in $PendingVMs) {
                
                    Invoke-Task "Creating $Name" -SkipCondition ([bool](Get-VM -Name $Name -ErrorAction SilentlyContinue)) -Task {
                        & $CreateVmScript -VMName $Name `
                            -TemplatesDir $TemplatesDir -TemplatePath $TemplatePath -TemplateUrl $TemplateUrl `
                            -VMsDir $VMsDir -CloudInitPath $CloudInitPath -PrivKey $PrivKey `
                            -UserDataTemplateScript $UserDataTemplateScript -MetaDataTemplateScript $MetaDataTemplateScript

                            if ($LASTEXITCODE -ne 0) { throw "El aprovisionamiento de la VM falló. Abortando despliegue." }
                    }
                
                }

                # 3. BUCLE DE BÚSQUEDA INTELIGENTE (Polling Loop)
                Write-SectionHeader -Title "PHASE 2: ASYNCHRONOUS IP DISCOVERY"
                $CompletedNodes = @() # Lista de objetos {name, ip}

                while ($PendingVMs.Count -gt 0) {
                    $StillPending = @() # Temporal para las que siguen sin IP en esta ronda
            
                    foreach ($VMName in $PendingVMs) {
                        # Intentamos obtener la IP de forma rápida (sin timeout largo)
                        $VM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
                        $IP = $VM.NetworkAdapters.IPAddresses | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1

                        if ($null -ne $IP) {
                            Write-Host " [V] IP Found for $VMName : $IP" -ForegroundColor Green
                            # Guardamos el objeto y lo sacamos de la lista de pendientes
                            $CompletedNodes += [PSCustomObject]@{ Name = $VMName; IP = $IP }
                            Show-NodeBox -VMName $VMName -IP $IP
                        } else {
                            $StillPending += $VMName
                        }
                    }

                    $PendingVMs = $StillPending
            
                    if ($PendingVMs.Count -gt 0) {
                        Invoke-Task "Waiting for Network/IP Assignment" -Task {
                            $res = Get-VMIPAddress -VMName $VMName
                            if ($res.Status -eq "Success") { $global:serverIP = $res.IP } else { throw "No se pudo obtener la IP." }
                        }
                    }
                }

                Write-Host "`n [!] All IPs collected successfully.`n" -ForegroundColor Cyan

                Write-SectionHeader -Title "CONFIGURING ALL NODES WITH ANSIBLE"

                Invoke-Task "Preparing Ansible Environment" -Task {
                    $AnsibleFile = Join-Path $ProjectRoot "playbooks\setup_zabbix_agent.yml"
                    $global:LinuxPlaybookPath = wsl wslpath -u "$AnsibleFile"
                }

                Invoke-Task "Executing Ansible Playbook (Agent Installation)" -Task {
                    # 1. Extraemos solo las IPs de los nodos completados
                    $IPList = $CompletedNodes | ForEach-Object { $_.IP }
                    if (-not $IPList) {
                        $IPList = @("192.168.1.102")
                    }
        

                    # 2. Creamos el inventario dinámico (Ej: "192.168.1.10,192.168.1.11,")
                    $Inventory = ($IPList -join ",") + ","
                
                    # 3. Validaciones de seguridad
                    if ([string]::IsNullOrWhiteSpace($global:LinuxPlaybookPath)) { throw "Error: Ruta del Playbook no definida." }
                    if ([string]::IsNullOrWhiteSpace($Inventory) -or $Inventory -eq ",") { throw "La lista de IPs para los nodos está vacía." }
              
                    # 4. Definición de argumentos (siguiendo tu formato exitoso)
                    $ansibleArgs = @(
                        "ansible-playbook",
                        "-i", "$Inventory",
                        "-e", "VMName=$VMName"
                        "$global:LinuxPlaybookPath"
                    )

                    # 5. Ejecución en WSL
                    & wsl @ansibleArgs

                    $exitCode = $LASTEXITCODE
                    if ($exitCode -ne 0) {
                        throw "Ansible masivo termino con errores (Exit Code: $exitCode)."
                    }
                }

                Write-Host "`n# ---------------------------------------------------------" -ForegroundColor Green
                Write-Host "# DONE: All nodes created and configured successfully!" -ForegroundColor Green
                Write-Host "# ---------------------------------------------------------" -ForegroundColor Green
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