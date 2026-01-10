# cloud-init – First Boot Configuration

This directory contains the **cloud-init configuration templates** used to initialize
virtual machines on first boot.

Each user **must generate their own `seed.iso`**.
The `seed.iso` contains **user-specific identity data** and **must not be shared**.

---

## Why `seed.iso` is User-Specific

The cloud-init `seed.iso` contains:

* SSH public key
* Initial user configuration
* Hostname
* Network bootstrap configuration

For security and correctness reasons:

* ❌ `seed.iso` must **not** be committed to Git
* ❌ `seed.iso` must **not** be shared between users
* ✔ Each user must generate their own

This ensures:

* Unique identity per VM
* Secure access
* Correct Ansible and Zabbix behavior

---

## Files in This Directory

```
cloud-init/
├── user-data.exempel
├── meta-data
├── README.md
└── seed.iso   (generated locally, NOT committed)
```

remove the `.exempel` extention from `user-data.exempel` and use it.

---

## Step 1 – Generate an SSH Key (on your local machine)

Each user must have their own SSH key pair.

On Windows (PowerShell):

```powershell
ssh-keygen
```

Accept the default location:

```
C:\Users\<user>\.ssh\id_ed25519
```

This creates:

* `id_ed25519` (private key – keep it secret)
* `id_ed25519.pub` (public key – used by cloud-init)

---

## Step 2 – Configure `user-data`

Open `cloud-init/user-data` and replace the SSH key:

```yaml
ssh-authorized-keys:
  - ssh-rsa AAAA...REPLACE_WITH_YOUR_PUBLIC_KEY...
```

You can view your public key with:

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub
```

Paste the **entire line** into `user-data`.

⚠️ Do not modify other settings unless you understand cloud-init.

---

## Step 3 – Configure `meta-data`

Edit `cloud-init/meta-data` if needed.

Example:

```yaml
instance-id: iid-local01
local-hostname: ubuntu
```

You may change `local-hostname` if desired.
Each VM created from this seed will use this hostname.

---

## Step 4 – Generate `seed.iso`

The `seed.iso` must be generated on a **Linux environment**.

Recommended options:

* WSL (Windows Subsystem for Linux)
* Linux VM

From inside the `cloud-init/` directory:

```bash
genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data
```

### Important

* The volume label **must be exactly `cidata`**
* File names **must be `user-data` and `meta-data`**
* No file extensions are allowed

---

## Step 5 – Verify the ISO (Optional but Recommended)

```bash
isoinfo -d -i seed.iso | grep Volume
```

Expected output:

```
Volume id: cidata
```

---

## Step 6 – Usage in Automation

The generated `seed.iso` is automatically attached to the VM
by the PowerShell provisioning script:

```powershell
Add-VMDvdDrive -VMName <vm> -Path cloud-init\seed.iso
```

On first boot, cloud-init will:

* Bring up networking (DHCP)
* Create the user
* Install the SSH key
* Set the hostname

---

## Common Errors

| Problem                       | Cause                           |
| ----------------------------- | ------------------------------- |
| Cannot SSH into VM            | SSH key mismatch                |
| `cloud-init status: disabled` | Template not prepared correctly |
| No IP address                 | Invalid or missing `seed.iso`   |
| Hostname always `ubuntu`      | Defined in `meta-data`          |

---

## Summary

* The repository provides a **cloud-init template**
* Each user injects their own identity
* This is intentional and required
* This design reflects real-world DevOps practices
