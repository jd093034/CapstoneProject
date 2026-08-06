#!/usr/bin/env bash
set -e

echo "=== Step 1: Generating Synthetic HR Lifecycle Events ==="
python3 scripts/generate_hr_data.py

echo "=== Step 2: Executing Identity Sync Pipeline ==="
ansible-playbook -i inventory/hosts.ini site.yml --vault-password-file .vault_pass

echo "=== Pipeline Sync Complete ==="