# Capstone Project

TODO: 

- Email about Conflicts
- Upload a CSV, parse the CSV with SQL and feed it to AD

# Commands

## Run master playbook

ansible-playbook -i inventory/hosts.ini site.yml --ask-vault-pass


## Check users on AD

ansible win_dc -i inventory/hosts.ini -m win_shell -a "Get-ADUser -Filter 'SamAccountName -eq \"username\"' -Properties Department,EmailAddress" -e @vars/vault.yml --ask-vault-pass

## How to Use

Run master playbook to create user records

ansible-playbook -i /root/ansible/inventory/hosts.ini   /root/ansible/master_hr_pipeline.yml   --vault-password-file /root/ansible/vars/.vault_pass

After there are too many user records, reset the environment

./wipe_all.sh 
