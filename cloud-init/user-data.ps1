param(
    [Parameter(Mandatory=$true)]
    [string]$SSHKey, 
    
    [Parameter(Mandatory=$true)]
    [string]$VMName
)

return @"
#cloud-config
event_timeout: 300
hostname: $VMName
manage_etc_hosts: true

# Configuracion de usuario para automatizacion DevOps
users:
  - name: deploy
    groups: [wheel, admin]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - $SSHKey

chpasswd:
  list: |
    deploy:password
  expire: false

ssh_pwauth: true

# Actualizacion y paquetes necesarios
package_update: true
packages:
  - python3
  - tar
  - curl
  - hyperv-daemons

# Instrucciones de ejecucion con verificacion y reinicio
runcmd:
  # 1. Asegurar que los servicios esten habilitados
  - [ systemctl, enable, --now, hypervvssd.service ]
  - [ systemctl, enable, --now, hypervkvpd.service ]
  
  # 2. Script de verificacion de exito y reinicio condicional
  - |
    if rpm -q hyperv-daemons; then
        echo "SUCCESS: Hyper-V Daemons installed. Rebooting..." > /var/log/cloud-init-hv.log
        # Reinicio inmediato para aplicar cambios de kernel/servicios
        shutdown -r now
    else
        echo "ERROR: Hyper-V Daemons NOT found. No reboot issued." > /var/log/cloud-init-hv.log
    fi

  # Este mensaje solo se vera si el reinicio falla o en el MOTD tras el boot
  - echo "VM $VMName lista para recibir configuracion de Ansible" > /etc/motd
"@