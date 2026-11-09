#!/usr/bin/env bash
set -euo pipefail

FORCE=false

# Check for non-interactive auto-approve flags (-y or --force)
if [[ "${1:-}" == "-y" || "${1:-}" == "--force" ]]; then
    FORCE=true
fi

if [ "$FORCE" = false ]; then
    echo "========================================================================="
    echo "   WARNING: APEX K12 DISTRICT ENVIRONMENT RESET (CLEAN SLATE)"
    echo "========================================================================="
    echo "This script will purge all non-system Student, Faculty, and Staff accounts:"
    echo "  1. PostgreSQL SIS Database (Active & Inactive Student/Staff Records)"
    echo "  2. Active Directory (OU=APEX K12: Students, Staff, Faculty & Graduates)"
    echo "  3. Authentik District SSO (GRP_* Security Groups & User Directory)"
    echo ""
    read -p "Are you sure you want to proceed? (type YES to confirm): " CONFIRM

    if [ "$CONFIRM" != "YES" ]; then
        echo "Reset aborted."
        exit 0
    fi
fi

echo "[+] Executing high-speed district reset playbook..."
ansible-playbook -i /root/ansible/inventory/hosts.ini \
  /root/ansible/playbooks/environment/reset_environment.yml \
  --vault-password-file /root/ansible/vars/.vault_pass

echo "========================================================================="
echo "[+] District environment wiped successfully!"
echo "    Run your SIS seed script/pipeline to repopulate."
echo "========================================================================="