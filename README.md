# Capstone Project

TODO: 

# Functions

- Staged Deprovisioning
  - Disable user in AD, move them to OU = Disabled Users
  - Keep user object in-tact for 30-day window
  - This would correspond to law/practice to keep user data for 60-90 days before deletion
  - Then would automatically purge the account after this window
 
- Dynamic Password Generation
  - Generate a cryotpgrahically secure random temp password
  - Can also utilize Authentik "invitation/enrollment flow api" to generate one-time magic links to email to new hires
 
- Organizational Hierarchy
  - Manager_id column to database
  - Add to AD, make a managers role with permissions
 
- Real-Time Sync
  - Listen/Notify trigger on database to run the sync when someone is hired/transferred/terminated
  
# QoL

- Email about Conflicts
- Create a --check or audit playbook to check for Identity Drift
- Nginx Dashboard & Control Panel
- Backups of the Database to /backups

# Commands

## Check users on AD

ansible win_dc -i inventory/hosts.ini -m win_shell -a "Get-ADUser -Filter 'SamAccountName -eq \"username\"' -Properties Department,EmailAddress" -e @vars/vault.yml --ask-vault-pass

## How to Use

Run master playbook to create user records

ansible-playbook -i /root/ansible/inventory/hosts.ini   /root/ansible/master_hr_pipeline.yml   --vault-password-file /root/ansible/vars/.vault_pass

After there are too many user records, reset the environment

./wipe_all.sh 
