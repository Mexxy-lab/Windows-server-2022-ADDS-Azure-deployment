#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$PROJECT_DIR/azure-ad-lab-terraform"

if [[ ! -f "$TERRAFORM_DIR/versions.tf" ||
      ! -f "$TERRAFORM_DIR/main.tf" ]]; then
    echo "[ERROR] Azure Terraform configuration not found:"
    echo "        $TERRAFORM_DIR"
    exit 1
fi

LOG_DIR="$PROJECT_DIR/logs"
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

LOG_FILE="$LOG_DIR/startupadds-azure-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

TFPLAN_FILE=""
VAULT_PLAIN_FILE=""
PS_SCRIPT_FILE=""
ANSIBLE_INVENTORY=""
BOOTSTRAP_ANSIBLE_VARS_FILE=""
DOMAIN_ANSIBLE_VARS_FILE=""

cleanup() {
    for file in \
        "$TFPLAN_FILE" \
        "$VAULT_PLAIN_FILE" \
        "$PS_SCRIPT_FILE" \
        "$ANSIBLE_INVENTORY" \
        "$BOOTSTRAP_ANSIBLE_VARS_FILE" \
        "$DOMAIN_ANSIBLE_VARS_FILE"
    do
        [[ -z "$file" ]] || rm -f -- "$file"
    done
}
trap cleanup EXIT
trap 'rc=$?; echo "[ERROR] Failed at line $LINENO (exit $rc). Check $LOG_FILE."; exit "$rc"' ERR

echo "=================================================="
echo " Windows Active Directory DEPLOYMENT - AZURE"
echo " Started: $(date)"
echo " Repository: $PROJECT_DIR"
echo " Terraform: $TERRAFORM_DIR"
echo "=================================================="

# ---------------------------------------------------------
# 1. Check required commands and project files.
# ---------------------------------------------------------

for cmd in terraform az ansible-playbook ansible ansible-inventory \
           ansible-vault ansible-galaxy python3; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[ERROR] Required command not found: $cmd"
        exit 1
    }
done

if [[ -f "$PROJECT_DIR/.venv/bin/activate" ]]; then
    # Activate the project Python environment.
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.venv/bin/activate"
fi

for file in \
    ansible.cfg requirements.yml inventory/hosts.ini \
    group_vars/windows.yml group_vars/vault.yml \
    playbooks/connection_test.yml playbooks/domain_controller.yml \
    playbooks/domain_users.yml playbooks/domain_client.yml \
    playbooks/validate_deployment.yml
do
    [[ -f "$PROJECT_DIR/$file" ]] || {
        echo "[ERROR] Required file missing: $PROJECT_DIR/$file"
        exit 1
    }
done

# ---------------------------------------------------------
# 2. Validate and decrypt Ansible Vault.
# ---------------------------------------------------------

VAULT_PASS_FILE="${ANSIBLE_VAULT_PASSWORD_FILE:-$HOME/.ansible_vault_pass}"

[[ -r "$VAULT_PASS_FILE" ]] || {
    echo "[ERROR] Missing Ansible Vault password file: $VAULT_PASS_FILE"
    exit 1
}

ansible-vault view "$PROJECT_DIR/group_vars/vault.yml" \
    --vault-password-file "$VAULT_PASS_FILE" >/dev/null

echo "[OK] Ansible Vault decryption check passed."

VAULT_PLAIN_FILE="$(mktemp)"
chmod 600 "$VAULT_PLAIN_FILE"

ansible-vault view "$PROJECT_DIR/group_vars/vault.yml" \
    --vault-password-file "$VAULT_PASS_FILE" > "$VAULT_PLAIN_FILE"

# Verify all three passwords and their formatting.
python3 - "$VAULT_PLAIN_FILE" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    vault = yaml.safe_load(stream)

if not isinstance(vault, dict):
    raise SystemExit("Vault file must contain a YAML mapping.")

for key in ("bootstrap_password", "domain_admin_password", "dsrm_password"):
    value = vault.get(key)

    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"Required Vault variable is missing: {key}")

    if any(c in value for c in ("\n", "\r", "\x00")):
        raise SystemExit(f"{key} contains an invalid control character.")

print("[OK] Required Vault credentials are present.")
PY

# Validate the domain Administrator password.
python3 - "$VAULT_PLAIN_FILE" <<'PY'
import string
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    vault = yaml.safe_load(stream)

password = vault["domain_admin_password"]

checks = {
    "length": 20 <= len(password) <= 64,
    "uppercase": any(c.isupper() for c in password),
    "lowercase": any(c.islower() for c in password),
    "digit": any(c.isdigit() for c in password),
    "symbol": any(c in string.punctuation for c in password),
    "no_whitespace": password == password.strip()
        and not any(c.isspace() for c in password),
    "ascii_only": password.isascii(),
    "no_account_or_domain_terms": not any(
        term in password.casefold()
        for term in ("administrator", "admin", "pumej", "pumejlab", "password")
    ),
}

failed = [name for name, passed in checks.items() if not passed]

if failed:
    raise SystemExit(
        "Windows domain administrator password preflight failed: "
        + ", ".join(failed)
    )

print("[OK] Domain Administrator password preflight passed.")
PY

# ---------------------------------------------------------
# 3. Create protected Ansible connection credential files.
#
# Azure local labadmin uses bootstrap_password.
# Domain Administrator uses domain_admin_password.
#
# Extra-vars files take precedence over ansible_password
# defined inside individual playbooks.
# ---------------------------------------------------------

BOOTSTRAP_ANSIBLE_VARS_FILE="$(mktemp)"
DOMAIN_ANSIBLE_VARS_FILE="$(mktemp)"

chmod 600 "$BOOTSTRAP_ANSIBLE_VARS_FILE" "$DOMAIN_ANSIBLE_VARS_FILE"

python3 - "$VAULT_PLAIN_FILE" "$BOOTSTRAP_ANSIBLE_VARS_FILE" "$DOMAIN_ANSIBLE_VARS_FILE" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    vault = yaml.safe_load(stream)

bootstrap_vars = {
    # Azure VM WinRM connection credentials.
    "ansible_user": "labadmin",
    "ansible_password": vault["bootstrap_password"],

    # Azure's built-in RID-500 account becomes the domain admin.
    # The domain-join task uses this account after promotion.
    "domain_admin_user": "labadmin@pumejlab.com",
}

# Domain authentication after AD DS promotion.
# Azure's provisioned labadmin account is the built-in RID-500
# Administrator account, which retains the labadmin name after
# AD DS promotion.
domain_vars = {
    # Explicitly override the AWS default domain administrator.
    "domain_admin_user": "PUMEJLAB\\labadmin",

    # Keep ansible_user available for other playbooks that consume
    # the generated domain connection variables.
    "ansible_user": "PUMEJLAB\\labadmin",

    # Retrieve the password from the decrypted Ansible Vault data.
    "ansible_password": vault["domain_admin_password"],
}

for path, variables in (
    (sys.argv[2], bootstrap_vars),
    (sys.argv[3], domain_vars),
):
    with open(path, "w", encoding="utf-8") as stream:
        yaml.safe_dump(variables, stream, default_flow_style=False)
PY

echo "[OK] Separate Ansible connection credentials prepared."

# ---------------------------------------------------------
# 4. Verify Azure CLI authentication.
# ---------------------------------------------------------

echo "[INFO] Checking Azure authentication..."

az account show --output table

AZURE_SUBSCRIPTION_ID="$(
    python3 - "$TERRAFORM_DIR/terraform.tfvars" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])

if not path.is_file():
    raise SystemExit(f"[ERROR] Missing Terraform variables file: {path}")

content = path.read_text()

match = re.search(
    r'(?m)^\s*subscription_id\s*=\s*"([^"]+)"\s*(?:#.*)?$',
    content,
)

if not match or not match.group(1).strip():
    raise SystemExit("[ERROR] subscription_id is missing or empty.")

print(match.group(1).strip())
PY
)"

az account set --subscription "$AZURE_SUBSCRIPTION_ID"

az account show \
    --query '{name:name,id:id,tenantId:tenantId}' \
    --output table

# ---------------------------------------------------------
# 5. Initialize, validate and plan Terraform.
# ---------------------------------------------------------

cd "$TERRAFORM_DIR"

terraform init
terraform fmt -check -recursive
terraform validate

TFPLAN_FILE="$(mktemp "$TERRAFORM_DIR/tfplan.XXXXXX")"

# Retrieve only the Azure local VM bootstrap password.
# Pass it to Terraform for the plan operation.
BOOTSTRAP_PASSWORD="$(
    python3 - "$VAULT_PLAIN_FILE" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    vault = yaml.safe_load(stream)

password = vault["bootstrap_password"]

if not isinstance(password, str) or not password:
    raise SystemExit("bootstrap_password is missing.")

sys.stdout.write(password)
PY
)"

if [[ -z "$BOOTSTRAP_PASSWORD" ]]; then
    echo "[ERROR] bootstrap_password is empty."
    exit 1
fi

TF_VAR_admin_password="$BOOTSTRAP_PASSWORD" \
    terraform plan -out="$TFPLAN_FILE"

unset BOOTSTRAP_PASSWORD

echo
echo "[WARNING] This plan may create billable Azure resources."

if [[ "${JENKINS_AUTO_APPROVE:-false}" == "true" ]]; then
    echo "[INFO] Jenkins deployment approval received."
    CONFIRM="YES"
else
    read -r -p "Apply this Azure plan? Type YES to continue: " CONFIRM
fi

if [[ "$CONFIRM" != "YES" ]]; then
    echo "[INFO] Cancelled before Terraform apply."
    exit 0
fi

terraform apply "$TFPLAN_FILE"

rm -f -- "$TFPLAN_FILE"
TFPLAN_FILE=""

# ---------------------------------------------------------
# 6. Read Azure Terraform outputs.
# ---------------------------------------------------------

RESOURCE_GROUP="$(terraform output -raw resource_group_name)"
DC_PRIVATE_IP="$(terraform output -raw dc01_private_ip)"
DC_PUBLIC_IP="$(terraform output -raw dc01_public_ip)"
CLIENT_PRIVATE_IP="$(terraform output -raw client_private_ip)"
CLIENT_PUBLIC_IP="$(terraform output -raw client_public_ip)"

[[ "$CLIENT_PRIVATE_IP" == "null" ]] && CLIENT_PRIVATE_IP=""
[[ "$CLIENT_PUBLIC_IP" == "null" ]] && CLIENT_PUBLIC_IP=""

DOMAIN_NAME="$(terraform output -raw domain_name)"
NETBIOS_NAME="$(terraform output -raw netbios_name)"

echo "[OK] Azure resource group: $RESOURCE_GROUP"
echo "[OK] Domain: $DOMAIN_NAME"
echo "[OK] NetBIOS name: $NETBIOS_NAME"
echo "[OK] DC01 private IP: $DC_PRIVATE_IP"
echo "[OK] DC01 public IP: $DC_PUBLIC_IP"

if [[ -n "$CLIENT_PUBLIC_IP" ]]; then
    echo "[OK] Windows client private IP: $CLIENT_PRIVATE_IP"
    echo "[OK] Windows client public IP:  $CLIENT_PUBLIC_IP"
else
    echo "[INFO] Optional Windows client is not deployed."
fi

# Verify the expected domain identity before generating credentials.
if [[ "$NETBIOS_NAME" != "PUMEJLAB" ||
      "$DOMAIN_NAME" != "pumejlab.com" ]]; then
    echo "[ERROR] Unexpected AD domain identity."
    echo "[ERROR] Expected PUMEJLAB / pumejlab.com."
    exit 1
fi

# ---------------------------------------------------------
# 7. Generate the temporary PowerShell bootstrap script.
#
# labadmin receives bootstrap_password.
# The built-in Administrator receives domain_admin_password
# ONLY on DC01, before AD DS promotion.
#
# The client keeps its own local Administrator account.
# ---------------------------------------------------------

PS_SCRIPT_FILE="$(mktemp)"
chmod 600 "$PS_SCRIPT_FILE"

python3 - "$VAULT_PLAIN_FILE" "$PS_SCRIPT_FILE" <<'PY'
import base64
import sys
from pathlib import Path
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    vault = yaml.safe_load(stream)

# Base64 avoids quoting and escaping problems when inserting
# special characters into a PowerShell script.
bootstrap_b64 = base64.b64encode(
    vault["bootstrap_password"].encode("utf-8")
).decode("ascii")

domain_admin_b64 = base64.b64encode(
    vault["domain_admin_password"].encode("utf-8")
).decode("ascii")

script = r'''
$ErrorActionPreference = 'Stop'

try {
    # Decode the Azure local administrator password.
    $bootstrapPassword = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__BOOTSTRAP_PASSWORD_B64__')
    )

    $secureBootstrapPassword = ConvertTo-SecureString `
        $bootstrapPassword -AsPlainText -Force

    # Configure the Azure-created local account.
    Set-LocalUser -Name 'labadmin' -Password $secureBootstrapPassword
    Enable-LocalUser -Name 'labadmin'

    # Only the Domain Controller needs the built-in Administrator
    # password configured for the AD DS forest promotion.
    if ($env:COMPUTERNAME -ieq 'DC01') {

        $domainAdminPassword = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String('__DOMAIN_ADMIN_PASSWORD_B64__')
        )

        $secureDomainAdminPassword = ConvertTo-SecureString `
            $domainAdminPassword -AsPlainText -Force

        # Locate the built-in Administrator using its RID-500 SID.
        $builtinAdmin = Get-LocalUser |
            Where-Object { $_.SID.Value -match '-500$' }

        if (-not $builtinAdmin) {
            throw "Could not locate the built-in Administrator account."
        }

        # Set the password that will become the domain Administrator
        # password after AD DS promotion.
        Set-LocalUser `
            -Name $builtinAdmin.Name `
            -Password $secureDomainAdminPassword

        Enable-LocalUser -Name $builtinAdmin.Name
    }

    # Configure WinRM.
    Enable-PSRemoting -Force -SkipNetworkProfileCheck

    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM

    # Enforce secure WinRM settings.
    Set-Item WSMan:\localhost\Service\Auth\Basic $false
    Set-Item WSMan:\localhost\Service\Auth\Negotiate $true
    Set-Item WSMan:\localhost\Service\AllowUnencrypted $false

    # Check whether an HTTPS listener already exists.
    $listener = Get-WSManInstance `
        -ResourceURI winrm/config/Listener -Enumerate |
        Where-Object {
            $_.Transport -eq 'HTTPS' -and $_.Address -eq '*'
        } |
        Select-Object -First 1

    if (-not $listener) {

        # Create a self-signed certificate for WinRM HTTPS.
        $cert = New-SelfSignedCertificate `
            -DnsName $env:COMPUTERNAME `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -NotAfter (Get-Date).AddYears(2)

        New-WSManInstance `
            -ResourceURI winrm/config/Listener `
            -SelectorSet @{ Address='*'; Transport='HTTPS' } `
            -ValueSet @{
                Hostname = $env:COMPUTERNAME
                CertificateThumbprint = $cert.Thumbprint
            } | Out-Null
    }

    # Allow WinRM HTTPS through Windows Firewall.
    if (-not (Get-NetFirewallRule `
        -Name 'WinRM-HTTPS-In-TCP' `
        -ErrorAction SilentlyContinue)) {

        New-NetFirewallRule `
            -Name 'WinRM-HTTPS-In-TCP' `
            -DisplayName 'WinRM HTTPS inbound' `
            -Enabled True `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort 5986 `
            -Action Allow `
            -Profile Any | Out-Null
    }

    # Clear password variables from the PowerShell session.
    $bootstrapPassword = $null
    $domainAdminPassword = $null
    $secureBootstrapPassword = $null
    $secureDomainAdminPassword = $null

    Write-Output 'AZURE_WINRM_BOOTSTRAP_OK'

} catch {
    Write-Error $_
    exit 1
}
'''

script = script.replace(
    "__BOOTSTRAP_PASSWORD_B64__",
    bootstrap_b64
)

script = script.replace(
    "__DOMAIN_ADMIN_PASSWORD_B64__",
    domain_admin_b64
)

Path(sys.argv[2]).write_text(script, encoding="utf-8")
PY

# ---------------------------------------------------------
# 8. Bootstrap Windows VMs using Azure Run Command.
# ---------------------------------------------------------

bootstrap_vm() {
    local vm_name="$1"
    local output_file
    local rc

    output_file="$(mktemp)"
    chmod 600 "$output_file"

    echo "[INFO] Configuring local labadmin and WinRM HTTPS on $vm_name..."

    if az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$vm_name" \
        --command-id RunPowerShellScript \
        --scripts "$(cat "$PS_SCRIPT_FILE")" \
        --output json > "$output_file"; then

        if grep -q "AZURE_WINRM_BOOTSTRAP_OK" "$output_file"; then
            echo "[OK] WinRM bootstrap succeeded on $vm_name."
            rm -f -- "$output_file"
            return 0
        fi

        echo "[WARN] Bootstrap returned without the expected success marker."
        cat "$output_file"
    else
        rc=$?
        echo "[WARN] Azure Run Command failed on $vm_name (exit $rc)."
        cat "$output_file"
    fi

    rm -f -- "$output_file"
    return 1
}

wait_for_winrm() {
    local host="$1"
    local label="$2"
    local attempt

    echo "[INFO] Waiting for WinRM HTTPS at ${host}:5986 ($label)..."

    for attempt in $(seq 1 60); do

        if python3 - "$host" 5986 <<'PY'
import socket
import sys

try:
    with socket.create_connection(
        (sys.argv[1], int(sys.argv[2])), timeout=5
    ):
        raise SystemExit(0)
except OSError:
    raise SystemExit(1)
PY
        then
            echo "[OK] TCP 5986 reachable for $label."
            return 0
        fi

        echo "[INFO] $label WinRM not ready ($attempt/60)."
        sleep 10
    done

    echo "[ERROR] WinRM HTTPS did not become reachable for $label."
    return 1
}

bootstrap_vm "DC01"

if [[ -n "$CLIENT_PUBLIC_IP" ]]; then
    bootstrap_vm "WIN-CLIENT-01"
fi

rm -f -- "$PS_SCRIPT_FILE"
PS_SCRIPT_FILE=""

# ---------------------------------------------------------
# 9. Generate temporary Ansible inventory.
#
# Inventory is intentionally temporary.
# Initial connections use local labadmin.
# Passwords are supplied through protected extra-vars files.
# ---------------------------------------------------------

ANSIBLE_INVENTORY="$(mktemp)"
chmod 600 "$ANSIBLE_INVENTORY"

cat > "$ANSIBLE_INVENTORY" <<EOF
[domain_controller]
dc01 ansible_host=$DC_PUBLIC_IP

[windows_clients]
EOF

if [[ -n "$CLIENT_PUBLIC_IP" ]]; then
    echo "windowsclient_01 ansible_host=$CLIENT_PUBLIC_IP" \
        >> "$ANSIBLE_INVENTORY"
fi

cat >> "$ANSIBLE_INVENTORY" <<'EOF'

[windows:children]
domain_controller
windows_clients

[windows:vars]
ansible_connection=winrm
ansible_port=5986
ansible_winrm_transport=ntlm
ansible_winrm_server_cert_validation=ignore
ansible_user=labadmin
EOF

cd "$PROJECT_DIR"

echo "[INFO] Installing required Ansible collections..."

ansible-galaxy collection install -r requirements.yml

inventory_graph="$(
    ansible-inventory -i "$ANSIBLE_INVENTORY" --graph
)" || {
    echo "[ERROR] Could not parse the generated Azure inventory."
    exit 1
}

echo "$inventory_graph"

grep -Eq 'dc01' <<< "$inventory_graph" || {
    echo "[ERROR] Inventory does not contain dc01."
    exit 1
}

if [[ -n "$CLIENT_PUBLIC_IP" ]] &&
   ! grep -Eq 'windowsclient_01' <<< "$inventory_graph"; then
    echo "[ERROR] Inventory does not contain windowsclient_01."
    exit 1
fi

# ---------------------------------------------------------
# 10. Verify initial local WinRM authentication.
# ---------------------------------------------------------

wait_for_winrm "$DC_PUBLIC_IP" "DC01"

if [[ -n "$CLIENT_PUBLIC_IP" ]]; then
    wait_for_winrm "$CLIENT_PUBLIC_IP" "Windows client"
fi

echo "[INFO] Testing initial local WinRM authentication..."

ansible-playbook -i "$ANSIBLE_INVENTORY" \
    playbooks/connection_test.yml \
    --extra-vars "@$BOOTSTRAP_ANSIBLE_VARS_FILE" \
    --vault-password-file "$VAULT_PASS_FILE"

# ---------------------------------------------------------
# 11. Promote DC01 to a domain controller.
#
# The playbook's DSRM password remains independently supplied
# through Ansible Vault.
# ---------------------------------------------------------

echo "[INFO] Configuring Active Directory Domain Services..."

ansible-playbook -i "$ANSIBLE_INVENTORY" \
    playbooks/domain_controller.yml \
    --extra-vars "@$BOOTSTRAP_ANSIBLE_VARS_FILE" \
    --vault-password-file "$VAULT_PASS_FILE"

# ---------------------------------------------------------
# 12. Restart DC01 and wait for it to return.
# ---------------------------------------------------------

echo "[INFO] Restarting DC01 through Azure..."

az vm restart \
    --resource-group "$RESOURCE_GROUP" \
    --name "DC01"

echo "[INFO] Waiting for DC01 to return to the running state..."

vm_ready=0

for attempt in $(seq 1 60); do

    power_state="$(
        az vm get-instance-view \
            --resource-group "$RESOURCE_GROUP" \
            --name "DC01" \
            --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" \
            --output tsv 2>/dev/null || true
    )"

    if [[ "$power_state" == "VM running" ]]; then
        vm_ready=1
        echo "[OK] DC01 is running."
        break
    fi

    echo "[INFO] DC01 state: ${power_state:-unknown} ($attempt/60)."
    sleep 10
done

if [[ "$vm_ready" -ne 1 ]]; then
    echo "[ERROR] DC01 did not return to the running state."
    exit 1
fi

wait_for_winrm "$DC_PUBLIC_IP" "DC01 after reboot"

# ---------------------------------------------------------
# 13. Wait for Active Directory and DNS readiness.
# ---------------------------------------------------------

echo "[INFO] Waiting for AD DS, DNS, and the domain to become ready..."

ad_ready=0

for attempt in $(seq 1 30); do

    readiness_script="$(cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'

try {
    Import-Module ActiveDirectory -ErrorAction Stop

    $domain = Get-ADDomain -ErrorAction Stop

    $services = Get-Service -Name NTDS, DNS, ADWS -ErrorAction Stop

    $stopped = @(
        $services | Where-Object { $_.Status -ne 'Running' }
    )

    if ($stopped.Count -eq 0) {
        Write-Output 'AZURE_AD_READY'
    } else {
        Write-Output 'AZURE_AD_WAIT'
    }

} catch {
    Write-Output 'AZURE_AD_WAIT'
}
POWERSHELL
)"

    readiness_output="$(
        az vm run-command invoke \
            --resource-group "$RESOURCE_GROUP" \
            --name "DC01" \
            --command-id RunPowerShellScript \
            --scripts "$readiness_script" \
            --query "value[0].message" \
            --output tsv 2>/dev/null || true
    )"

    if grep -q "AZURE_AD_READY" <<< "$readiness_output"; then
        ad_ready=1
        echo "[OK] AD DS and DNS are ready."
        break
    fi

    echo "[INFO] AD services are not ready yet ($attempt/30)."
    sleep 15
done

if [[ "$ad_ready" -ne 1 ]]; then
    echo "[ERROR] AD DS readiness check failed."
    echo "[ERROR] Check Azure Run Command output and DC01 Windows event logs."
    exit 1
fi

# ---------------------------------------------------------
# 14. Verify domain Administrator authentication.
#
# Azure's built-in RID-500 Administrator account is named
# labadmin. After AD DS promotion, authenticate using:
# PUMEJLAB\labadmin
#
# The account uses domain_admin_password at this stage.
# ---------------------------------------------------------

echo "[INFO] Verifying domain Administrator WinRM authentication..."

ansible_ok=0

for attempt in $(seq 1 12); do

    if ansible-playbook -i "$ANSIBLE_INVENTORY" \
        playbooks/connection_test.yml \
        --limit dc01 \
        --extra-vars "@$DOMAIN_ANSIBLE_VARS_FILE" \
        --vault-password-file "$VAULT_PASS_FILE"; then

        ansible_ok=1
        break
    fi

    echo "[WARN] Domain Administrator WinRM check failed ($attempt/12)."
    sleep 20
done

if [[ "$ansible_ok" -ne 1 ]]; then
    echo "[ERROR] Domain Administrator authentication did not recover."
    exit 1
fi

echo "[OK] Domain Administrator WinRM authentication succeeded."

# ---------------------------------------------------------
# 15. Create OUs and import domain users.
#
# All domain-level administrative tasks use the Azure
# domain administrator account: PUMEJLAB\labadmin.
# ---------------------------------------------------------

echo "[INFO] Creating OUs and importing domain users..."

ansible-playbook -i "$ANSIBLE_INVENTORY" \
    playbooks/domain_users.yml \
    --extra-vars "@$DOMAIN_ANSIBLE_VARS_FILE" \
    --vault-password-file "$VAULT_PASS_FILE"

# ---------------------------------------------------------
# 16. Join the optional Windows client.
#
# WinRM connection:
#   labadmin / bootstrap_password
#
# Domain membership:
#   labadmin@pumejlab.com / domain_admin_password
#
# The domain_client playbook receives both credentials through
# the protected connection vars file and Ansible Vault.
# ---------------------------------------------------------

if [[ -n "$CLIENT_PUBLIC_IP" ]]; then

    echo "[INFO] Joining the Windows client to the domain..."

    ansible-playbook -i "$ANSIBLE_INVENTORY" \
        playbooks/domain_client.yml \
        --extra-vars "@$BOOTSTRAP_ANSIBLE_VARS_FILE" \
        --vault-password-file "$VAULT_PASS_FILE"

else
    echo "[INFO] Skipping client join; no client VM was deployed."
fi

# ---------------------------------------------------------
# 17. Run final Active Directory validation.
# ---------------------------------------------------------

echo "[INFO] Running final Active Directory validation..."

ansible-playbook -i "$ANSIBLE_INVENTORY" \
    playbooks/validate_deployment.yml \
    --extra-vars "@$DOMAIN_ANSIBLE_VARS_FILE" \
    --vault-password-file "$VAULT_PASS_FILE"

# ---------------------------------------------------------
# 18. Deployment summary.
# ---------------------------------------------------------

echo "=================================================="
echo "[SUCCESS] Azure deployment stages completed."
echo "Domain: $DOMAIN_NAME"
echo "Domain Controller private IP: $DC_PRIVATE_IP"
echo "Domain Controller public IP:  $DC_PUBLIC_IP"
echo "Windows Client private IP:    ${CLIENT_PRIVATE_IP:-not deployed}"
echo "Windows Client public IP:     ${CLIENT_PUBLIC_IP:-not deployed}"
echo "Resource group: $RESOURCE_GROUP"
echo "Log file: $LOG_FILE"
echo "Completed: $(date)"
echo "=================================================="
