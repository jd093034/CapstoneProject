Import-Module ActiveDirectory -ErrorAction Stop

# ==============================================================================
# Configuration & Payload Staging
# ==============================================================================
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

Write-Host "Loaded $($users.Count) active user(s) and $($inactiveUsers.Count) inactive user(s) for K-12 AD sync."

$domain     = "apex.lab"
$domainDN   = (Get-ADDomain).DistinguishedName
$rootOU     = "OU=APEX K12,$domainDN"
$disabledOU = "OU=Users - Disabled,OU=APEX K12,$domainDN"
$groupOU    = "OU=Groups,OU=APEX K12,$domainDN"

# Legacy OUs for automated migration/cleanup
$legacyOUs = @(
    "OU=Departments,OU=APEX Lab,$domainDN",
    "OU=APEX Lab,$domainDN",
    "OU=Users - Disabled,$domainDN",
    "OU=Disabled Users,$domainDN"
)

$secPassword = ConvertTo-SecureString $env:DEFAULT_PASSWORD -AsPlainText -Force

# ==============================================================================
# 1. K-12 Directory Taxonomy Construction & OU Pre-Caching
# ==============================================================================
$K12_OUs = @(
    "OU=APEX K12,$domainDN",
    "OU=Students,OU=APEX K12,$domainDN",
    "OU=Oakridge Elementary,OU=Students,OU=APEX K12,$domainDN",
    "OU=Pinecrest Elementary,OU=Students,OU=APEX K12,$domainDN",
    "OU=Lakeside Middle School,OU=Students,OU=APEX K12,$domainDN",
    "OU=Apex High School,OU=Students,OU=APEX K12,$domainDN",
    "OU=Graduates,OU=Students,OU=APEX K12,$domainDN",
    "OU=Staff,OU=APEX K12,$domainDN",
    "OU=Faculty,OU=Staff,OU=APEX K12,$domainDN",
    "OU=Administration,OU=Staff,OU=APEX K12,$domainDN",
    "OU=Support Staff,OU=Staff,OU=APEX K12,$domainDN",
    "OU=Groups,OU=APEX K12,$domainDN",
    "OU=Users - Disabled,OU=APEX K12,$domainDN"
)

$OUCache = @{}
foreach ($ouPath in $K12_OUs) {
    $OUCache[$ouPath.ToLower()] = $true
    try {
        $null = Get-ADOrganizationalUnit -Identity $ouPath -ErrorAction Stop
    } catch {
        $ouName = ($ouPath -split ',')[0] -replace 'OU=', ''
        $parentPath = ($ouPath -split ',', 2)[1]
        New-ADOrganizationalUnit -Name $ouName -Path $parentPath -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
        Write-Host "[+] CREATED K-12 OU: $ouName at $parentPath"
    }
}

# Migrate legacy corporate accounts if present
foreach ($oldOU in $legacyOUs) {
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$oldOU'" -ErrorAction SilentlyContinue) {
        $legacyUsers = Get-ADUser -Filter * -SearchBase $oldOU -ErrorAction SilentlyContinue
        foreach ($lu in $legacyUsers) {
            Move-ADObject -Identity $lu.DistinguishedName -TargetPath $disabledOU -ErrorAction SilentlyContinue
            Write-Host "[*] MIGRATED LEGACY USER: $($lu.SamAccountName) -> $disabledOU"
        }
    }
}

# Ensure standard GRP_ Security Groups exist (Including GRP_Graduates)
$BaseGroups = @(
    "GRP_District_Students", "GRP_District_Faculty", "GRP_District_Staff", "GRP_Graduates",
    "GRP_Oakridge_ES", "GRP_Pinecrest_ES", "GRP_Lakeside_MS", "GRP_Apex_HS"
)
0..12 | ForEach-Object { $BaseGroups += ("GRP_Grade_{0:D2}" -f $_) }

foreach ($grpName in $BaseGroups) {
    if (-not (Get-ADGroup -Filter "SamAccountName -eq '$grpName'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $grpName -SamAccountName $grpName -GroupCategory Security -GroupScope Global -Path $groupOU -ErrorAction SilentlyContinue
        Write-Host "[+] CREATED K-12 SECURITY GROUP: '$grpName' in $groupOU"
    }
}

# ==============================================================================
# 2. Fast In-Memory Directory Store & Group Pre-Caching
# ==============================================================================
Write-Host "[*] Pre-caching Active Directory user store and security groups..."

$ADUserCache = @{}
Get-ADUser -Filter * -SearchBase "OU=APEX K12,$domainDN" -Properties Enabled, DistinguishedName -ErrorAction SilentlyContinue | ForEach-Object {
    $ADUserCache[$_.SamAccountName.ToLower()] = $_
}

$GroupCache   = @{}
$GroupMembers = @{}

# Fast group member caching via direct 'member' attribute read (avoids LDAP object resolution)
Get-ADGroup -Filter "SamAccountName -like 'GRP_*'" -SearchBase $groupOU -Properties member -ErrorAction SilentlyContinue | ForEach-Object {
    $grpSam = $_.SamAccountName
    $GroupCache[$grpSam] = $_
    
    $memberHash = @{}
    if ($_.member) {
        foreach ($mDN in $_.member) {
            if ($mDN -match "CN=.*?\((.*?)\),") {
                $memberHash[$Matches[1].ToLower()] = $true
            } else {
                $cnVal = ($mDN -split ',')[0] -replace 'CN=', ''
                $memberHash[$cnVal.ToLower()] = $true
            }
        }
    }
    $GroupMembers[$grpSam] = $memberHash
}

$PendingGroupAdds    = @{}
$PendingGroupRemoves = @{}

# Helper function to convert numeric grade to GRP_Grade_XX
function Format-GradeGroup ($gradeStr) {
    if ([string]::IsNullOrWhiteSpace($gradeStr) -or $gradeStr -eq "N/A" -or $gradeStr -eq "GRAD") { return $null }
    $gInt = 0
    if ([int]::TryParse($gradeStr, [ref]$gInt)) {
        return ("GRP_Grade_{0:D2}" -f $gInt)
    }
    return $null
}

# ==============================================================================
# 3. Process Terminated Users (Offboarding & FERPA Retention Protocol)
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

            if ($adUser.DistinguishedName.ToLower() -notlike "*$($disabledOU.ToLower())*") {
                Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $disabledOU -ErrorAction SilentlyContinue
                Write-Host "[*] MOVED TO DISABLED OU: $username -> $disabledOU"
            }

            # Queue removal from all GRP_ security groups
            foreach ($gSam in $GroupMembers.Keys) {
                if ($GroupMembers[$gSam].ContainsKey($uLower)) {
                    if (-not $PendingGroupRemoves.ContainsKey($gSam)) { 
                        $PendingGroupRemoves[$gSam] = [System.Collections.Generic.List[string]]::new()
                    }
                    $PendingGroupRemoves[$gSam].Add($username)
                }
            }
        }
    }
}

# ==============================================================================
# 4. Provision & Synchronize Active K-12 Identities
# ==============================================================================
foreach ($u in $users) {
    $username = $u.username
    if ([string]::IsNullOrWhiteSpace($username)) { continue }
    $uLower = $username.ToLower()

    $firstName = $u.first_name
    $lastName  = $u.last_name
    $fullName  = "$firstName $lastName"
    $email     = $u.email
    $uType     = $u.user_type
    $school    = $u.school
    $grade     = [string]$u.grade_level

    # Determine Target Campus/Division OU (Including Graduates OU Routing)
    if ($uType -eq "STUDENT") {
        if ($grade -eq "GRAD" -or $school -like "*Graduates*") {
            $targetOU = "OU=Graduates,OU=Students,OU=APEX K12,$domainDN"
        } else {
            $targetOU = "OU=$school,OU=Students,OU=APEX K12,$domainDN"
        }
    } elseif ($uType -eq "FACULTY") {
        $targetOU = "OU=Faculty,OU=Staff,OU=APEX K12,$domainDN"
    } elseif ($uType -eq "ADMIN") {
        $targetOU = "OU=Administration,OU=Staff,OU=APEX K12,$domainDN"
    } else {
        $targetOU = "OU=Support Staff,OU=Staff,OU=APEX K12,$domainDN"
    }

    # Fast in-memory check to ensure target OU exists (eliminates 1,000 LDAP ADSI calls)
    $targetOULower = $targetOU.ToLower()
    if (-not $OUCache.ContainsKey($targetOULower)) {
        if (-not ([adsi]::Exists("LDAP://$targetOU"))) {
            $ouName = ($targetOU -split ',')[0] -replace 'OU=', ''
            $parentPath = ($targetOU -split ',', 2)[1]
            New-ADOrganizationalUnit -Name $ouName -Path $parentPath -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
        }
        $OUCache[$targetOULower] = $true
    }

    # Create missing account directly in assigned K-12 OU
    if (-not $ADUserCache.ContainsKey($uLower)) {
        $cnName = "$fullName ($username)"
        try {
            New-ADUser -Name $cnName `
                       -GivenName $firstName `
                       -Surname $lastName `
                       -DisplayName $fullName `
                       -UserPrincipalName "$username@$domain" `
                       -SamAccountName $username `
                       -EmailAddress $email `
                       -Path $targetOU `
                       -AccountPassword $secPassword `
                       -Enabled $true `
                       -PasswordNeverExpires $true `
                       -ErrorAction Stop
            Write-Host "[+] CREATED K-12 AD USER: $username ($cnName) in $targetOU"
        } catch {
            Write-Error "[!] AD PROVISIONING ERROR for ${username} in ${targetOU}: $($_.Exception.Message)"
        }
    } else {
        $adUser = $ADUserCache[$uLower]
        
        # Re-enable if currently disabled
        if (-not $adUser.Enabled) {
            Set-ADUser -Identity $username -Enabled $true -ErrorAction SilentlyContinue
            Write-Host "[+] RE-ENABLED AD USER: $username"
        }

        # Relocate account if Grade Promotion / Graduation / School Transfer moved target OU (case-insensitive)
        if ($adUser.DistinguishedName.ToLower() -notlike "*$targetOULower*") {
            try {
                Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $targetOU -ErrorAction Stop
                Write-Host "[*] RELOCATED AD USER: $username -> $targetOU"
            } catch {
                Write-Error "[!] ERROR MOVING AD USER ${username}: $($_.Exception.Message)"
            }
        }
    }

    # Dynamic K-12 RBAC Security Group Membership Reconciliation
    $TargetGroupsForUser = @{}
    if ($uType -eq "STUDENT") {
        if ($grade -eq "GRAD" -or $school -like "*Graduates*") {
            $TargetGroupsForUser["GRP_Graduates"] = $true
        } else {
            $TargetGroupsForUser["GRP_District_Students"] = $true
            
            $gradeGrp = Format-GradeGroup $grade
            if ($gradeGrp) { $TargetGroupsForUser[$gradeGrp] = $true }

            if ($school -like "*Oakridge*") { $TargetGroupsForUser["GRP_Oakridge_ES"] = $true }
            elseif ($school -like "*Pinecrest*") { $TargetGroupsForUser["GRP_Pinecrest_ES"] = $true }
            elseif ($school -like "*Lakeside*") { $TargetGroupsForUser["GRP_Lakeside_MS"] = $true }
            elseif ($school -like "*Apex High*") { $TargetGroupsForUser["GRP_Apex_HS"] = $true }
        }
    } elseif ($uType -eq "FACULTY") {
        $TargetGroupsForUser["GRP_District_Faculty"] = $true
    } else {
        $TargetGroupsForUser["GRP_District_Staff"] = $true
    }

    # Reconcile membership against all GRP_ groups
    foreach ($gSam in $GroupMembers.Keys) {
        if ($TargetGroupsForUser.ContainsKey($gSam)) {
            if (-not $GroupMembers[$gSam].ContainsKey($uLower)) {
                if (-not $PendingGroupAdds.ContainsKey($gSam)) { 
                    $PendingGroupAdds[$gSam] = [System.Collections.Generic.List[string]]::new()
                }
                $PendingGroupAdds[$gSam].Add($username)
            }
        } else {
            if ($GroupMembers[$gSam].ContainsKey($uLower)) {
                if (-not $PendingGroupRemoves.ContainsKey($gSam)) { 
                    $PendingGroupRemoves[$gSam] = [System.Collections.Generic.List[string]]::new()
                }
                $PendingGroupRemoves[$gSam].Add($username)
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
        Remove-ADGroupMember -Identity $gSam -Members $membersToRemove.ToArray() -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "[-] BULK STRIPPED $($membersToRemove.Count) account(s) from Group '$gSam'"
    }
}

foreach ($gSam in $PendingGroupAdds.Keys) {
    $membersToAdd = $PendingGroupAdds[$gSam]
    if ($membersToAdd.Count -gt 0) {
        Add-ADGroupMember -Identity $gSam -Members $membersToAdd.ToArray() -ErrorAction SilentlyContinue
        Write-Host "[+] BULK ADDED $($membersToAdd.Count) account(s) to Group '$gSam'"
    }
}

exit 0