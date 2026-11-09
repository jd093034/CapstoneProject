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

$domain            = "apex.lab"
$parentOU          = "OU=APEX Lab,DC=apex,DC=lab"
$targetOU          = "OU=Departments,OU=APEX Lab,DC=apex,DC=lab"
$disabledOU        = "OU=Users - Disabled,DC=apex,DC=lab"
$legacyDisabledOUs = @("OU=Disabled Users,DC=apex,DC=lab", "OU=Disabled Users,OU=APEX Lab,DC=apex,DC=lab")
$userOU            = "CN=Users,DC=apex,DC=lab"

# ==============================================================================
# 1. Structure & Organizational Unit (OU) Management (No Sub-OUs)
# ==============================================================================

# Ensure Disabled Accounts OU exists
try {
    $null = Get-ADOrganizationalUnit -Identity $disabledOU -ErrorAction Stop
} catch {
    $ouName = ($disabledOU -split ',')[0] -replace 'OU=', ''
    $ouPath = ($disabledOU -split ',', 2)[1]
    New-ADOrganizationalUnit -Name $ouName -Path $ouPath -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
    Write-Host "[+] CREATED OU: $ouName at $ouPath"
}

# Migrate legacy disabled accounts if present
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

# Ensure parent & target department container OUs exist
foreach ($ou in @($parentOU, $targetOU)) {
    try {
        $null = Get-ADOrganizationalUnit -Identity $ou -ErrorAction Stop
    } catch {
        $pName = ($ou -split ',')[0] -replace 'OU=', ''
        $pPath = ($ou -split ',', 2)[1]
        New-ADOrganizationalUnit -Name $pName -Path $pPath -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
        Write-Host "[+] CREATED OU: $pName at $pPath"
    }
}

$secPassword = ConvertTo-SecureString $env:DEFAULT_PASSWORD -AsPlainText -Force

# ==============================================================================
# 2. In-Memory Directory Store & Department Group Pre-Caching
# ==============================================================================
Write-Host "[*] Pre-caching Active Directory user store and department groups..."

# Cache ALL AD user accounts in 1 single LDAP query (Keyed by lowercase sAMAccountName)
$ADUserCache = @{}
Get-ADUser -Filter * -Properties Enabled, DistinguishedName | ForEach-Object {
    $ADUserCache[$_.SamAccountName.ToLower()] = $_
}

# Extract unique departments and pre-cache department Security Groups in $targetOU
$depts        = @($users | Select-Object -ExpandProperty department -Unique | Where-Object { $_ })
$GroupCache   = @{}
$GroupMembers = @{}

foreach ($d in $depts) {
    $groupSam = $d -replace '[\/:*?"<>|]', ''
    $grp = Get-ADGroup -Filter "SamAccountName -eq '$groupSam'" -ErrorAction SilentlyContinue
    if (-not $grp) {
        $grp = New-ADGroup -Name $d -SamAccountName $groupSam -GroupScope Global -GroupCategory Security -Path $targetOU -PassThru -ErrorAction SilentlyContinue
        Write-Host "[+] CREATED AD SECURITY GROUP: '$d' in $targetOU"
    }
    
    if ($grp) {
        $GroupCache[$groupSam] = $grp
        $members = Get-ADGroupMember -Identity $grp.DistinguishedName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName
        $memberHash = @{}
        foreach ($m in $members) { $memberHash[$m.ToLower()] = $true }
        $GroupMembers[$groupSam] = $memberHash
    }
}

# Queues for bulk RPC group operations
$PendingGroupAdds    = @{}
$PendingGroupRemoves = @{}

# ==============================================================================
# 3. Process Terminated Users (Offboarding & Legal Hold Protocol)
# ==============================================================================
foreach ($u in $inactiveUsers) {
    $username = $u.username
    if ([string]::IsNullOrWhiteSpace($username)) { continue }
    $uLower = $username.ToLower()

    if ($ADUserCache.ContainsKey($uLower)) {
        $adUser = $ADUserCache[$uLower]
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

        # Expired Retention Window (> 30 Days)
        if ($daysSinceTerm -gt 30) {
            if ($isLegalHold) {
                Write-Host "[!] LEGAL HOLD ACTIVE: Preserving expired AD account for $username"
            } else {
                Remove-ADUser -Identity $username -Confirm:$false -ErrorAction SilentlyContinue
                $ADUserCache.Remove($uLower)
                Write-Host "[-] PURGED EXPIRED AD USER: $username (Terminated $daysSinceTerm days ago)"
            }
        } 
        # Active Offboarding & Grace Period (0-30 Days)
        else {
            if ($adUser.Enabled) {
                Set-ADUser -Identity $username -Enabled $false -ErrorAction SilentlyContinue
                Write-Host "[-] DISABLED AD USER: $username"
            }

            if ($adUser.DistinguishedName -notlike "*$disabledOU*") {
                Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $disabledOU -ErrorAction SilentlyContinue
                Write-Host "[*] MOVED TO DISABLED OU: $username -> $disabledOU"
            }

            # Queue group removal in memory
            foreach ($gSam in $GroupMembers.Keys) {
                if ($GroupMembers[$gSam].ContainsKey($uLower)) {
                    if (-not $PendingGroupRemoves.ContainsKey($gSam)) { $PendingGroupRemoves[$gSam] = @() }
                    $PendingGroupRemoves[$gSam] += $username
                }
            }
        }
    }
}

# ==============================================================================
# 4. Provision & Synchronize Active Users (Container: CN=Users,DC=apex,DC=lab)
# ==============================================================================
foreach ($u in $users) {
    $username = $u.username
    if ([string]::IsNullOrWhiteSpace($username)) { continue }
    $uLower = $username.ToLower()

    $firstName = $u.first_name
    $lastName  = $u.last_name
    $fullName  = "$firstName $lastName"
    $email     = $u.email
    $dept      = $u.department

    # Create missing account directly in $userOU (CN=Users,DC=apex,DC=lab)
    if (-not $ADUserCache.ContainsKey($uLower)) {
        $cnName = "$fullName ($username)"
        try {
            New-ADUser -Name $cnName `
                       -GivenName $firstName `
                       -Surname $lastName `
                       -UserPrincipalName "$username@$domain" `
                       -SamAccountName $username `
                       -EmailAddress $email `
                       -Path $userOU `
                       -AccountPassword $secPassword `
                       -Enabled $true `
                       -PasswordNeverExpires $true `
                       -ErrorAction Stop
            Write-Host "[+] CREATED AD USER: $username ($cnName) in $userOU"
        } catch {
            Write-Error "[!] AD PROVISIONING ERROR for ${username} in ${userOU}: $($_.Exception.Message)"
        }
    } else {
        $adUser = $ADUserCache[$uLower]
        
        # Re-enable if disabled
        if (-not $adUser.Enabled) {
            Set-ADUser -Identity $username -Enabled $true -ErrorAction SilentlyContinue
            Write-Host "[+] RE-ENABLED AD USER: $username"
        }

        # ONLY execute Move-ADObject if user is coming out of the Disabled OU
        if ($adUser.DistinguishedName -like "*$disabledOU*") {
            try {
                Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $userOU -ErrorAction Stop
                Write-Host "[*] MOVED AD USER: $username -> $userOU"
            } catch {
                Write-Error "[!] ERROR MOVING AD USER ${username}: $($_.Exception.Message)"
            }
        }
    }

    # Department Group Membership Queuing
    if (-not [string]::IsNullOrWhiteSpace($dept)) {
        $targetDeptSam = $dept -replace '[\/:*?"<>|]', ''

        foreach ($gSam in $GroupMembers.Keys) {
            if ($gSam -eq $targetDeptSam) {
                # Add to primary department group if missing
                if (-not $GroupMembers[$gSam].ContainsKey($uLower)) {
                    if (-not $PendingGroupAdds.ContainsKey($gSam)) { $PendingGroupAdds[$gSam] = @() }
                    $PendingGroupAdds[$gSam] += $username
                }
            } else {
                # Strip from stale department groups if present
                if ($GroupMembers[$gSam].ContainsKey($uLower)) {
                    if (-not $PendingGroupRemoves.ContainsKey($gSam)) { $PendingGroupRemoves[$gSam] = @() }
                    $PendingGroupRemoves[$gSam] += $username
                }
            }
        }
    }
}

# ==============================================================================
# 5. Bulk Apply Group Membership Changes (Single-Session RPCs)
# ==============================================================================
foreach ($gSam in $PendingGroupRemoves.Keys) {
    $membersToRemove = $PendingGroupRemoves[$gSam]
    if ($membersToRemove.Count -gt 0) {
        Remove-ADGroupMember -Identity $gSam -Members $membersToRemove -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "[-] BULK STRIPPED $($membersToRemove.Count) account(s) from Group '$gSam'"
    }
}

foreach ($gSam in $PendingGroupAdds.Keys) {
    $membersToAdd = $PendingGroupAdds[$gSam]
    if ($membersToAdd.Count -gt 0) {
        Add-ADGroupMember -Identity $gSam -Members $membersToAdd -ErrorAction SilentlyContinue
        Write-Host "[+] BULK ADDED $($membersToAdd.Count) account(s) to Group '$gSam'"
    }
}

exit 0