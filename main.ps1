# ---------------------------------------------------------
# 1. Load Configurations and Utilities
# ---------------------------------------------------------
. "$PSScriptRoot\powershell\utils\config.ps1"
. "$PSScriptRoot\powershell\utils\common.ps1"

$ErrorActionPreference = "Stop"
$CreateVmScript = Join-Path $PowershellDir "create-vm.ps1"
$ProgressPreference = 'SilentlyContinue'

# --- BANNER ---
Clear-Host
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "          WELCOME TO VM AUTOMATION TOOL" -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "            Created by Alexei Martinez" -ForegroundColor Yellow
Write-Host "==========================================================`n" -ForegroundColor Cyan

# --- Checking infrastructure status---
Write-Host " [i] Checking infrastructure status..." -ForegroundColor Gray
$ZabbixVM = Get-VM -Name "zabbix-server" -ErrorAction SilentlyContinue

if ($ZabbixVM) {
    Write-Host " [+] zabbix-server found in the system." -ForegroundColor Green
    # Intentamos obtener su IP sin el event listener largo, solo una consulta rápida
    $ZabbixIP = $ZabbixVM.NetworkAdapters.IPAddresses | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
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
    Write-Host " 1. Create Zabbix-Server in the system"
    Write-Host " 2. Create VMs"
    Write-Host " 3. Delete VMs"
    Write-Host " 4. Exit"
    
    $Choice = Read-Host "`n -> Choice"

    switch ($Choice) {
        "1" {
            try {
                # Write-SectionHeader -Title "ZABBIX-SERVER: DEPLOY & ANSIBLE (via WSL)"
                # $ZabbixVM = Get-VM -Name "zabbix-server" -ErrorAction SilentlyContinue

                # if ($ZabbixVM) {
                #     Write-Host " [!] zabbix-server ya existe." -ForegroundColor Yellow
                # } else {
                #     # 1. Crear VM
                #     & $CreateVmScript -VMName "zabbix-server" -TemplatesDir $TemplatesDir -TemplatePath $TemplatePath -TemplateUrl $TemplateUrl -VMsDir $VMsDir -CloudInitPath $CloudInitPath -PrivKey $PrivKey -UserDataTemplateScript $UserDataTemplateScript -MetaDataTemplateScript $MetaDataTemplateScript
                
                #     # 2. Obtener IP
                #     $res = Get-VMIPAddress -VMName "zabbix-server"
                
                #     if ($res.Status -eq "Success") {
                #         $serverIP = $res.IP
                        $serverIP = "192.168.1.238"
                #         Write-Host "`n [!] IP Detectada: $serverIP" -ForegroundColor Cyan
                #         Write-Host " [i] Esperando 10s para estabilidad de red y SSH..." -ForegroundColor Gray
                #         Start-Sleep -Seconds 10
                        
                        $AnsibleFile = Join-Path $ProjectRoot "ansible\playbooks\install_zabbix_server.yml"
                        $LinuxPlaybookPath = wsl wslpath -u "$AnsibleFile"

                         
                         
                #         # 4. EJECUTAR ANSIBLE MEDIANTE WSL
                #         Write-Host " [>] Lanzando Ansible desde WSL..." -ForegroundColor Magenta
                        
                        # Ejecutamos el comando dentro de WSL
                        Write-Host "$LinuxPlaybookPath" -ForegroundColor Green
                        wsl ansible-playbook -i "$($serverIP)," "$LinuxPlaybookPath" -e "ansible_user=deploy" --private-key=""$PrivKey""
                        

                #         if ($LASTEXITCODE -eq 0) {
                #             Write-Host "`n [SUCCESS] Zabbix instalado: http://$serverIP/zabbix" -ForegroundColor Green
                #         } else {
                #         Write-Host "`n [X] Error en Ansible mediante WSL." -ForegroundColor Red
                #         }
                #     }
                # }
            }
            catch {
                Write-Host " [!] Error detectado: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host " [!] Iniciando Rollback de emergencia..." -ForegroundColor Yellow
                
                # Invocamos la función Rollback
                Invoke-VMRollback -VMName "zabbix-server" -VHDXPath $VHDXPath -CloudInitPath $CloudInitPath
                
                Write-Host " [OK] Sistema limpio tras error." -ForegroundColor Green
            }
            
        }

        "2" {
            # Lógica original de creación masiva
            $RawInput = Read-Host "`n -> How many VMs do you want to create?"
            if ($RawInput -as [int]) {
                $Count = [int]$RawInput
                $Summary = New-Object System.Collections.Generic.List[PSObject]
                
                for ($i = 1; $i -le $Count; $i++) {
                    $DefaultName = "Zabbix-Node-$i"
                    $ChosenName = Read-Host " -> Enter name for VM #$i (Enter for '$DefaultName')"
                    if ([string]::IsNullOrWhiteSpace($ChosenName)) { $ChosenName = $DefaultName }

                    try {
                        & $CreateVmScript -VMName $ChosenName -TemplatesDir $TemplatesDir -TemplatePath $TemplatePath -TemplateUrl $TemplateUrl -VMsDir $VMsDir -CloudInitPath $CloudInitPath -PrivKey $PrivKey -UserDataTemplateScript $UserDataTemplateScript -MetaDataTemplateScript $MetaDataTemplateScript
                        
                        $resultado = Get-VMIPAddress -VMName $ChosenName
                        
                        $Summary.Add([PSCustomObject]@{ 
                            ID     = $i
                            VMName = $ChosenName
                            IP     = $resultado.IP
                            Result = $resultado.Status
                            Time   = "$($resultado.Time)s"
                        })
                    } catch {
                        Write-Host " [X] Error: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
                Write-SectionHeader -Title "DEPLOYMENT SUMMARY"
                $Summary | Format-Table -AutoSize
            }
        }

        "3" {
            $RemoveVmScript = Join-Path $PowershellDir "remove-vm.ps1"
            & $RemoveVmScript
        }

        "4" {
            Write-Host " Exiting... Goodbye Alexei!" -ForegroundColor Cyan
            break
        }

        Default {
            Write-Host " [!] Invalid option, please try again." -ForegroundColor Yellow
        }
    }
} while ($Choice -ne "4")