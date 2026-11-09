#!/usr/bin/env bash
set -euo pipefail

FORCE=false

# Check for non-interactive auto-approve flags
if [[ "${1:-}" == "-y" || "${1:-}" == "--force" ]]; then
    FORCE=true
fi

if [ "$FORCE" = false ]; then
    echo "======================================================="
    echo "   WARNING: FULL ENVIRONMENT RESET (CLEAN SLATE)"
    echo "======================================================="
    echo "This script will wipe all non-system users and groups from:"
    echo "  1. PostgreSQL HR Database (Active & Inactive Records)"
    echo "  2. Active Directory (OU=Employees / OU=Users - Disabled / OU=Groups)"
    echo "  3. Authentik Identity Provider"
    echo ""
    read -p "Are you sure you want to proceed? (type YES to confirm): " CONFIRM

    if [ "$CONFIRM" != "YES" ]; then
        echo "Reset aborted."
        exit 0
    fi
fi

echo "[+] Executing high-speed reset playbook..."
ansible-playbook -i /root/ansible/inventory/hosts.ini \
  /root/ansible/playbooks/environment/reset_environment.yml \
  --vault-password-file /root/ansible/vars/.vault_pass

echo "======================================================="
echo "[+] Environment wiped successfully!"
echo "    Run your seed script/pipeline to repopulate."
echo "======================================================="