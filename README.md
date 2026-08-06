# Capstone Project


# Check users on AD

ansible win_dc -i inventory/hosts.ini -m win_shell -a "Get-ADUser -Filter 'SamAccountName -eq \"username\"' -Properties Department,EmailAddress" -e @vars/vault.yml --ask-vault-pass