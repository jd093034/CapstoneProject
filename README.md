# Capstone Project

# TODO: 
## Function
 
- Users actually have different permissions or more Security Groups assigned to them
  - Like if they were in tech/employee vs a student
  - Microsoft licensing or something 
  - Add to AD, make a managers role with permissions
 
- Real-Time Sync
  - Listen/Notify trigger on database to run the sync when someone is hired/transferred/terminated
  
## QoL

- Email about Conflicts
- Backups of the Database to /backups

# Commands

## Check users on AD

ansible win_dc -i inventory/hosts.ini -m win_shell -a "Get-ADUser -Filter 'SamAccountName -eq \"username\"' -Properties Department,EmailAddress" -e @vars/vault.yml --ask-vault-pass

## How to Use

Run master playbook to create user records

ansible-playbook -i /root/ansible/inventory/hosts.ini   /root/ansible/master_hr_pipeline.yml   --vault-password-file /root/ansible/vars/.vault_pass

After there are too many user records, reset the environment

./wipe_all.sh 

### Retention Purge - >30 Day Accounts after Termination

ansible-playbook -i /root/ansible/inventory/hosts.ini   /root/ansible/playbooks/termination/retention_purge.yml   --vault-password-file /root/ansible/vars/.vault_pass
