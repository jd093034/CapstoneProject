#!/usr/bin/env bash
# The "#!" (shebang) tells Linux to run this file using the Bash shell

# Safety mode for Bash scripts:
# -e: stop immediately if any command fails (instead of blindly continuing)
# -u: stop if we accidentally use a variable that hasn't been set
# -o pipefail: if a piped command (cmd1 | cmd2) fails in the middle, still catch the error
set -euo pipefail

# Default flag: require a human to type "YES" before wiping anything
FORCE=false

# Check if the user ran the script with "-y" or "--force" (for automated benchmark runs).
# $1 is the first argument typed after the script name; "${1:-}" defaults to empty text if nothing
# was typed so "set -u" doesn't complain. "||" means "OR", and "fi" is "if" spelled backwards to close the block.
if [[ "${1:-}" == "-y" || "${1:-}" == "--force" ]]; then
    FORCE=true
fi

# If "-y" or "--force" was NOT passed, show a big warning banner and ask for confirmation
if [ "$FORCE" = false ]; then
    # "echo" prints each line of text to the terminal screen
    echo "========================================================================="
    echo "   WARNING: APEX K12 DISTRICT ENVIRONMENT RESET (CLEAN SLATE)"
    echo "========================================================================="
    echo "This script will purge all non-system Student, Faculty, and Staff accounts:"
    echo "  1. PostgreSQL SIS Database (Active & Inactive Student/Staff Records)"
    echo "  2. Active Directory (OU=APEX K12: Students, Staff, Faculty & Graduates)"
    echo "  3. Authentik District SSO (GRP_* Security Groups & User Directory)"
    echo ""
    # "read -p" pauses the script, prints the prompt message, and saves whatever the user types into CONFIRM
    read -p "Are you sure you want to proceed? (type YES to confirm): " CONFIRM

    # "!=" means "not equal": if they typed anything other than exact capital "YES", cancel safely (exit 0)
    if [ "$CONFIRM" != "YES" ]; then
        echo "Reset aborted."
        exit 0
    fi
fi

echo "[+] Executing high-speed district reset playbook..."
# Launch our 3-play Ansible reset playbook. The backslashes "\" just let one long command wrap across 3 lines.
# -i: points to our inventory file listing localhost and our Windows Domain Controller (win_dc)
# --vault-password-file: reads the vault password automatically so Ansible can decrypt vault.yml without asking
ansible-playbook -i /root/ansible/inventory/hosts.ini \
  /root/ansible/playbooks/environment/reset_environment.yml \
  --vault-password-file /root/ansible/vars/.vault_pass

echo "========================================================================="
echo "[+] District environment wiped successfully!"
echo "    Run your SIS seed script/pipeline to repopulate."
echo "========================================================================="