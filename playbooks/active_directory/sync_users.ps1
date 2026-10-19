Import-Module ActiveDirectory -ErrorAction Stop

$jsonPath         = "C:\Windows\Temp\dynamic_ad_users.json"
$inactiveJsonPath = "C:\Windows\Temp\dynamic_inactive_users.json"

# Load Active Users Payload
$users = @()
if (Test-Path $jsonPath) {
    $raw = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json
    if ($null -ne $raw.dynamic_ad_users) {
        $users = @($raw.dynamic_ad_users)
    } elseif ($raw -is [System.Array]) {
        $users = $raw
    } else {
        $users = @($raw)
    }
}

# Load Inactive/Terminated Users Payload
$inactiveUsers = @()
if (Test-Path $inactiveJsonPath) {
    $inactiveRaw = Get-Content -Path $inactiveJsonPath -Raw | ConvertFrom-Json
    if ($null -ne $inactiveRaw.dynamic_inactive_users) {
        $inactiveUsers = @($inactiveRaw.dynamic_inactive_users)
    } elseif ($inactiveRaw -is [System.Array]) {
        $inactiveUsers = $inactiveRaw
    } else {
        $inactiveUsers = @($inactiveRaw)
    }
}

Write-Host "Loaded $($users.Count) active user(s) and $($inactiveUsers.Count) inactive user(s) for AD sync."

$domain           = "apex.lab"
$parentOU         = "OU=APEX Lab,DC=apex,DC=lab"
$targetOU         = "OU=Departments,OU=APEX Lab,DC=apex,DC=lab"
$disabledOU       = "OU=Users - Disabled,DC=apex,DC=lab"
$legacyDisabledOUs = @("OU=Disabled Users,DC=apex,DC=lab", "OU=Disabled Users,OU=APEX Lab,DC=apex,DC=lab")
$userOU           = "CN=Users,DC=apex,DC=lab"

# 1. Ensure new target 'Users - Disabled' OU exists
$ouName = ($disabledOU -split ',')[0] -replace 'OU=', ''
$ouPath = ($disabledOU -split ',', 2)[1]
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$disabledOU'" -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name $ouName -Path $ouPath -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
    Write-Host "[+] CREATED OU: $ouName at $ouPath"
}

# 2. Migrate legacy disabled accounts from old OUs & clean them up
foreach ($oldOU in $legacyDisabledOUs) {
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$oldOU'" -ErrorAction SilentlyContinue) {
        $legacyUsers = Get-ADUser -Filter * -SearchBase $oldOU -ErrorAction SilentlyContinue
        foreach ($lu in $legacyUsers) {
            Move-ADObject -Identity $lu.DistinguishedName -TargetPath $disabledOU -ErrorAction SilentlyContinue
            Write-Host "[*] MIGRATED LEGACY DISABLED USER: $($lu.SamAccountName) -> $disabledOU"
        }
        Set-ADOrganizationalUnit -Identity $oldOU -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
        Remove-ADOrganizationalUnit -Identity $oldOU -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "[-] REMOVED LEGACY OU: $oldOU"
    }
}

# 3. Ensure required parent OUs exist
foreach ($ou in @($parentOU, $targetOU)) {
    $pName = ($ou -split ',')[0] -replace 'OU=', ''
    $pPath = ($ou -split ',', 2)[1]
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ou'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $pName -Path $pPath -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
        Write-Host "[+] CREATED OU: $pName at $pPath"
    }
}

$secPassword = ConvertTo-SecureString $env:DEFAULT_PASSWORD -AsPlainText -Force

# 4. Process Terminated Users (Staged Offboarding & Legal Hold Checks)
foreach ($u in $inactiveUsers) {
    $username = $u.username
    if ([string]::IsNullOrWhiteSpace($username)) { continue }

    $adUser = Get-ADUser -Filter "SamAccountName -eq '$username'" -ErrorAction SilentlyContinue
    if ($adUser) {
        $daysSinceTerm = 0
        $rawTermAt = [string]$u.terminated_at
        if (-not [string]::IsNullOrWhiteSpace($rawTermAt) -and $rawTermAt -ne "null" -and $rawTermAt -ne "None") {
            try {
                $termDate = [DateTime]::Parse($rawTermAt)
                $daysSinceTerm = [Math]::Max(0, (([DateTime]::Now) - $termDate).Days)
            } catch {
                $daysSinceTerm = 0
            }
        }

        $isLegalHold = [bool]$u.legal_hold

        # STAGE 3: Expired Retention Window (> 30 Days)
        if ($daysSinceTerm -gt 30) {
            if ($isLegalHold) {
                Write-Host "[!] LEGAL HOLD ACTIVE: Preserving expired AD account for $username"
            } else {
                Remove-ADUser -Identity $username -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "[-] PURGED EXPIRED AD USER: $username (Terminated $daysSinceTerm days ago)"
            }
        }
        # STAGE 1: Day 0 Immediate Cut-Off & Grace Period (0-30 Days)
        else {
            # Disable Account
            Set-ADUser -Identity $username -Enabled $false -ErrorAction SilentlyContinue

            # Move to Users - Disabled OU
            if ($adUser.DistinguishedName -notlike "*$disabledOU*") {
                Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $disabledOU -ErrorAction SilentlyContinue
                Write-Host "[*] MOVED TO DISABLED OU: $username -> $disabledOU"
            }

            # Strip department security group memberships
            $currentDeptGroups = Get-ADPrincipalGroupMembership -Identity $username -ErrorAction SilentlyContinue | Where-Object { $_.DistinguishedName -like "*$targetOU*" }

            foreach ($g in $currentDeptGroups) {
                Remove-ADGroupMember -Identity $g.DistinguishedName -Members $username -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "[-] STRIPPED GROUP '$($g.Name)' from $username"
            }
        }
    }
}

# 5. Ensure Department Security Groups exist inside Departments OU for Active Users
$depts = @($users | Select-Object -ExpandProperty department -Unique | Where-Object { $_ })
foreach ($d in $depts) {
    $groupSam = $d -replace '[\/:*?"<>|]', ''
    $grp = Get-ADGroup -Filter "SamAccountName -eq '$groupSam'" -ErrorAction SilentlyContinue
    if (-not $grp) {
        New-ADGroup -Name $d -SamAccountName $groupSam -GroupScope Global -GroupCategory Security -Path $targetOU -ErrorAction SilentlyContinue
        Write-Host "[+] CREATED AD GROUP: '$d'"
    } else {
        Write-Host "[=] AD GROUP EXISTS: '$d'"
    }
}

# 6. Provision & Sync Active Users
foreach ($u in $users) {
    $username = $u.username
    if ([string]::IsNullOrWhiteSpace($username)) { continue }

    $firstName = $u.first_name
    $lastName  = $u.last_name
    $fullName  = "$firstName $lastName"
    $email     = $u.email
    $dept      = $u.department

    $adUser = Get-ADUser -Filter "SamAccountName -eq '$username'" -ErrorAction SilentlyContinue

    if (-not $adUser) {
        New-ADUser -Name $fullName -GivenName $firstName -Surname $lastName -UserPrincipalName "$username@$domain" -SamAccountName $username -EmailAddress $email -Path $userOU -AccountPassword $secPassword -Enabled $true -PasswordNeverExpires $true -ErrorAction SilentlyContinue
        Write-Host "[+] CREATED AD USER: $username ($fullName)"
    } else {
        if (-not $adUser.Enabled) {
            Set-ADUser -Identity $username -Enabled $true -ErrorAction SilentlyContinue
            Write-Host "[+] RE-ENABLED AD USER: $username"
        }

        if ($adUser.DistinguishedName -notlike "*$userOU*") {
            Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $userOU -ErrorAction SilentlyContinue
            Write-Host "[*] MOVED AD USER: $username -> $userOU"
        } else {
            Write-Host "[=] AD USER EXISTS: $username"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($dept)) {
        $deptSam = $dept -replace '[\/:*?"<>|]', ''

        $currentDeptGroups = Get-ADPrincipalGroupMembership -Identity $username -ErrorAction SilentlyContinue | Where-Object { $_.DistinguishedName -like "*$targetOU*" }

        foreach ($g in $currentDeptGroups) {
            if ($g.SamAccountName -ne $deptSam -and $g.Name -ne $dept) {
                Remove-ADGroupMember -Identity $g.DistinguishedName -Members $username -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "[-] REMOVED $username from stale group '$($g.Name)'"
            }
        }

        Add-ADGroupMember -Identity $deptSam -Members $username -ErrorAction SilentlyContinue
        Write-Host "[+] BOUND $username -> Group '$dept'"
    }
}
exit 0
