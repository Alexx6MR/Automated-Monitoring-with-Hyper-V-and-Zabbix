. ".\powershell\utils\common.ps1"

$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------
# Variables
# ---------------------------------------------------------
$ProjectRoot = Get-Location
$TemplatesDir = Join-Path $ProjectRoot "templates"
$TemplateUrl      = "https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"
$TemplatePath     = Join-Path $TemplatesDir "almalinux-10-base.vhdx"
$CloudInitPath    = Join-Path $ProjectRoot "cloud-init"
$PowershellDir    = Join-Path $ProjectRoot "powershell"
$CreateVmScript = Join-Path $PowershellDir "create-vm.ps1"
$PrivKey           = "./powershell/secrets/deploy_key"
$UserDataTemplateScript = Join-Path $CloudInitPath "user-data.ps1"
$MetaDataTemplateScript = Join-Path $CloudInitPath "meta-data.ps1"
$VMsDir           = Join-Path $ProjectRoot "vms"

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

Invoke-Task "Ensuring fake_db existence" -Task {
    $dbPath = Join-Path $PSScriptRoot "fake_db.yml"
    
    if (-not (Test-Path $dbPath)) {
        Write-Host " [i] File not found. Creating new fake_db.yml..." -ForegroundColor Gray
        $content = "zabbix_server_ip: `"`"" 
        $content | Out-File -FilePath $dbPath -Encoding UTF8 -Force
    } else {
        Write-Host " [i] fake_db.yml already exists. Skipping creation." -ForegroundColor Green
    }
}

if ($global:ZabbixVM) {
    Write-Host " [+] zabbix-server found in the system." -ForegroundColor Green
    # We try to get its IP without the long event listener, just a quick query
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
                # --- SCENARIO A: VM ALREADY EXISTS ---
                Write-Host " [+] zabbix-server already exists. Fetching connection details..." -ForegroundColor Cyan
        
                # Attempt to get the current IP of the VM
                $ZabbixIP = $existingVM.NetworkAdapters.IPAddresses | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
        
                if ($ZabbixIP) {
                    $global:serverIP = $ZabbixIP
                } else {
                    # If it has no IP (off or loading), we run the wait task
                    Invoke-Task "Waiting for Network/IP Assignment" -Task {
                        $res = Get-VMIPAddress -VMName "zabbix-server"
                        if ($res.Status -eq "Success") { $global:serverIP = $res.IP } else { throw "Could not retrieve IP address." }
                    }
                }   
                if ($null -ne $global:serverIP) {
                    Invoke-Task "Updating VM data in the database" -Task {
                        $content = "zabbix_server_ip: `"$global:serverIP`""
                        $content | Out-File -FilePath "./fake_db.yml" -Encoding UTF8
                    }
                    Show-ZabbixServerBox -IP $global:serverIP
                } else {
                    Write-Host " [X] Error: Could not determine Zabbix server IP." -ForegroundColor Red
                }
                
            } else {

                # Step 1: Run the atomic creation script
                Invoke-Task "Provisioning Virtual Machine" -SkipCondition ([bool](Get-VM -Name "zabbix-server" -ErrorAction SilentlyContinue)) -Task {
                    & $CreateVmScript -VMName "zabbix-server" -Size "large" `
                        -TemplatesDir $TemplatesDir -TemplatePath $TemplatePath -TemplateUrl $TemplateUrl `
                        -VMsDir $VMsDir -CloudInitPath $CloudInitPath -PrivKey $PrivKey `
                        -UserDataTemplateScript $UserDataTemplateScript -MetaDataTemplateScript $MetaDataTemplateScript

                        if ($LASTEXITCODE -ne 0) { throw "VM provisioning failed. Aborting deployment." }
                }

                # Step 2: Obtain IP (with internal retries)
                Invoke-Task "Waiting for Network/IP Assignment" -Task {
                    $res = Get-VMIPAddress -VMName "zabbix-server"
                    if ($res.Status -eq "Success") { $global:serverIP = $res.IP } else { throw "Could not retrieve IP address." }
                }

                Invoke-Task "Saving VM data in the database" -Task {
                    $content = "zabbix_server_ip: `"$global:serverIP`""
                    $content | Out-File -FilePath "./fake_db.yml" -Encoding UTF8
                }

                Write-SectionHeader -Title "ANSIBLE CONFIGURATIONS"

                # Step 3: Configure Ansible
                Invoke-Task "Preparing Ansible Environment" -Task {
                    $AnsibleFile = Join-Path $ProjectRoot "playbooks\install_zabbix_server.yml"
                    $global:LinuxPlaybookPath = wsl wslpath -u "$AnsibleFile"
                }

                # Step 4: Execute Ansible
                Invoke-Task "Executing Ansible Playbook (Zabbix Installation)" -Task {

                    # debug mode
                    if (-not $global:serverIP ) {
                        $global:serverIP = "192.168.1.113"
                    }

                    if ([string]::IsNullOrWhiteSpace($global:serverIP)) { throw "Server IP is null or empty." }
                    if ([string]::IsNullOrWhiteSpace($global:LinuxPlaybookPath)) { throw "Error: Playbook path not defined." }
                    
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
                        throw "Ansible finished with errors (Exit Code: $exitCode)."
                    }
                }

                # Final step: Show credentials in a box
                [Console]::ResetColor()
                Show-ZabbixServerBox -IP $global:serverIP
                
            }
        }
        "2" {
            # 1. PLANNING (Collect names and individual sizes)
            $RawInput = Read-Host "`n -> How many VMs do you want to create?"
            if ($RawInput -as [int]) {
                $Count = [int]$RawInput
                $PendingVMs = @() # We will store objects containing { Name, Size }

                for ($i = 1; $i -le $Count; $i++) {
                    Write-Host "`n--- Configuring VM #$i ---" -ForegroundColor Yellow
                    
                    # Get the Name
                    $Name = Read-Host " -> Name for VM #$i"
                    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "Zabbix-Node-$i" }

                    # Get the Size for THIS specific VM
                    Write-Host " SELECT HARDWARE SIZE for $Name :" -ForegroundColor White
                    Write-Host " 1. Small  (1 vCPU, 1GB RAM)"
                    Write-Host " 2. Medium (2 vCPU, 2GB RAM)"
                    Write-Host " 3. Large  (4 vCPU, 4GB RAM)"
                    
                    $SizeChoice = Read-Host " -> Choice [1-3] (Default: 1)"
                    
                    $SelectedSize = switch ($SizeChoice) {
                        "2"     { "medium" }
                        "3"     { "large" }
                        Default { "small" }
                    }

                    # Add an object with both properties to our list
                    $PendingVMs += [PSCustomObject]@{
                        Name = $Name
                        Size = $SelectedSize
                    }
                }

                # 2. BULK CREATION
                Write-SectionHeader -Title "PHASE 1: PROVISIONING $Count VMs"
                foreach ($VM in $PendingVMs) {
                
                    Invoke-Task "Creating $($VM.Name) ($($VM.Size))" -SkipCondition ([bool](Get-VM -Name $VM.Name -ErrorAction SilentlyContinue)) -Task {
                        # We pass $VM.Size specifically for this VM
                        & $CreateVmScript -VMName $VM.Name -Size $VM.Size `
                            -TemplatesDir $TemplatesDir -TemplatePath $TemplatePath -TemplateUrl $TemplateUrl `
                            -VMsDir $VMsDir -CloudInitPath $CloudInitPath -PrivKey $PrivKey `
                            -UserDataTemplateScript $UserDataTemplateScript -MetaDataTemplateScript $MetaDataTemplateScript

                        if ($LASTEXITCODE -ne 0) { throw "VM provisioning failed for $($VM.Name)." }
                    }
                }

                # 3. SMART POLLING LOOP
                Write-SectionHeader -Title "PHASE 2: ASYNCHRONOUS IP DISCOVERY"
                $CompletedNodes = @() 
                $DiscoveryList = $PendingVMs.Name # List of names to look for

                while ($DiscoveryList.Count -gt 0) {
                    $StillPending = @() 
            
                    foreach ($VMName in $DiscoveryList) {
                        $VMObj = Get-VM -Name $VMName -ErrorAction SilentlyContinue
                        $global:IP = $VMObj.NetworkAdapters.IPAddresses | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1

                        Invoke-Task "Waiting for Network/IP Assignment" -Task {
                            $res = Get-VMIPAddress -VMName "zabbix-server"
                            if ($res.Status -eq "Success") { $global:IP = $res.IP } else { throw "Could not retrieve IP address." }
                        }

                        if ($null -ne $global:IP) {
                            Write-Host " [V] IP Found for $VMName : $global:IP" -ForegroundColor Green
                            $CompletedNodes += [PSCustomObject]@{ Name = $VMName; IP = $global:IP }
                            Show-NodeBox -VMName $VMName -IP $global:IP
                        } else {
                            $StillPending += $VMName
                        }
                    }

                    $DiscoveryList = $StillPending
            
                    if ($DiscoveryList.Count -gt 0) {
                        Start-Sleep -Seconds 2 # Small pause to avoid CPU spiking
                    }
                }

                Write-Host "`n [!] All IPs collected successfully.`n" -ForegroundColor Cyan

                Write-SectionHeader -Title "CONFIGURING ALL NODES WITH ANSIBLE"

                Invoke-Task "Preparing Ansible Environment" -Task {
                    $AnsibleFile = Join-Path $ProjectRoot "playbooks\setup_zabbix_agent.yml"
                    $global:LinuxPlaybookPath = wsl wslpath -u "$AnsibleFile"
                }

                Invoke-Task "Executing Ansible Playbook (Agent Installation)" -Task {
                    # 1. Extract only the IPs from completed nodes
                    $IPList = $CompletedNodes | ForEach-Object { $_.IP }
                    if (-not $IPList) {
                        $IPList = @("192.168.1.102")
                    }
        
                    # 2. Create dynamic inventory (Ex: "192.168.1.10,192.168.1.11,")
                    $Inventory = ($IPList -join ",") + ","
                
                    # 3. Security validations
                    if ([string]::IsNullOrWhiteSpace($global:LinuxPlaybookPath)) { throw "Error: Playbook path not defined." }
                    if ([string]::IsNullOrWhiteSpace($Inventory) -or $Inventory -eq ",") { throw "Node IP list is empty." }
              
                    # 4. Argument definition
                    $ansibleArgs = @(
                        "ansible-playbook",
                        "-i", "$Inventory",
                        "-e", "VMName=$VMName"
                        "$global:LinuxPlaybookPath"
                    )

                    # 5. Execute in WSL
                    & wsl @ansibleArgs

                    $exitCode = $LASTEXITCODE
                    if ($exitCode -ne 0) {
                        throw "Bulk Ansible execution finished with errors (Exit Code: $exitCode)."
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
            & $RemoveVmScript -VMsDir $VMsDir -ProjectRoot $ProjectRoot
            
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