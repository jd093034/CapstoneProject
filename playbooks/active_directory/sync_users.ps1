Import-Module ActiveDirectory -ErrorAction Stop

# ==============================================================================
# Configuration & Payload Staging
# ==============================================================================
$jsonPath         = "C:\Windows\Temp\dynamic_ad_users.json"
$inactiveJsonPath = "C:\Windows\Temp\dynamic_inactive_users.json"

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

$domain        = "apex.lab"
$domainDN      = (Get-ADDomain).DistinguishedName
$disabledOU    = "OU=Users - Disabled,OU=APEX K12,$domainDN"
$groupOU       = "OU=Groups,OU=APEX K12,$domainDN"
$plainPassword = if ($env:DEFAULT_PASSWORD) { $env:DEFAULT_PASSWORD } else { "StudentPass2026!" }

# Legacy OUs for automated migration/cleanup
$legacyOUs = @(
    "OU=Departments,OU=APEX Lab,$domainDN",
    "OU=APEX Lab,$domainDN",
    "OU=Users - Disabled,$domainDN",
    "OU=Disabled Users,$domainDN"
)

# ==============================================================================
# 1. K-12 Directory Taxonomy Construction & Full Grade-Level OU Pre-Caching
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

0..5  | ForEach-Object { $K12_OUs += ("OU=Grade {0:D2},OU=Oakridge Elementary,OU=Students,OU=APEX K12,$domainDN" -f $_) }
0..5  | ForEach-Object { $K12_OUs += ("OU=Grade {0:D2},OU=Pinecrest Elementary,OU=Students,OU=APEX K12,$domainDN" -f $_) }
6..8  | ForEach-Object { $K12_OUs += ("OU=Grade {0:D2},OU=Lakeside Middle School,OU=Students,OU=APEX K12,$domainDN" -f $_) }
9..12 | ForEach-Object { $K12_OUs += ("OU=Grade {0:D2},OU=Apex High School,OU=Students,OU=APEX K12,$domainDN" -f $_) }

foreach ($ouPath in $K12_OUs) {
    if (-not [DirectoryServices.DirectoryEntry]::Exists("LDAP://$ouPath")) {
        $ouName = ($ouPath -split ',')[0] -replace 'OU=', ''
        $parentPath = ($ouPath -split ',', 2)[1]
        New-ADOrganizationalUnit -Name $ouName -Path $parentPath -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
    }
}

# Ensure standard GRP_ Security Groups exist
$ExistingGroupsHash = @{}
Get-ADGroup -Filter "SamAccountName -like 'GRP_*'" -SearchBase $groupOU -ErrorAction SilentlyContinue | ForEach-Object {
    $ExistingGroupsHash[$_.SamAccountName.ToLower()] = $_
}

$BaseGroups = @(
    "GRP_District_Students", "GRP_District_Faculty", "GRP_District_Staff", "GRP_Graduates",
    "GRP_Oakridge_ES", "GRP_Pinecrest_ES", "GRP_Lakeside_MS", "GRP_Apex_HS"
)
0..12 | ForEach-Object { $BaseGroups += ("GRP_Grade_{0:D2}" -f $_) }

foreach ($grpName in $BaseGroups) {
    if (-not $ExistingGroupsHash.ContainsKey($grpName.ToLower())) {
        New-ADGroup -Name $grpName -SamAccountName $grpName -GroupCategory Security -GroupScope Global -Path $groupOU -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 2. Fast In-Memory Directory Store & Group Pre-Caching
# ==============================================================================
Write-Host "[*] Pre-caching Active Directory user store and security groups..."

$ADUserCache = @{}
$ADUserDNMap = @{}

Get-ADUser -Filter * -SearchBase "OU=APEX K12,$domainDN" -Properties Enabled, DistinguishedName -ErrorAction SilentlyContinue | ForEach-Object {
    $uLower = $_.SamAccountName.ToLower()
    $ADUserCache[$uLower] = $_
    $ADUserDNMap[$uLower] = $_.DistinguishedName
}

$GroupMembers = @{}
Get-ADGroup -Filter "SamAccountName -like 'GRP_*'" -SearchBase $groupOU -Properties member -ErrorAction SilentlyContinue | ForEach-Object {
    $grpSam = $_.SamAccountName
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

$PendingGroupAddsDN    = @{}
$PendingGroupRemovesDN = @{}

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

        if ($daysSinceTerm -gt 30 -and -not [bool]$u.legal_hold) {
            Remove-ADUser -Identity $username -Confirm:$false -ErrorAction SilentlyContinue
            $ADUserCache.Remove($uLower)
            $ADUserDNMap.Remove($uLower)
        } else {
            if ($adUser.Enabled) {
                Set-ADUser -Identity $username -Enabled $false -ErrorAction SilentlyContinue
            }
            if ($adUser.DistinguishedName.ToLower() -notlike "*$($disabledOU.ToLower())*") {
                Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $disabledOU -ErrorAction SilentlyContinue
            }
            foreach ($gSam in $GroupMembers.Keys) {
                if ($GroupMembers[$gSam].ContainsKey($uLower)) {
                    if (-not $PendingGroupRemovesDN.ContainsKey($gSam)) { 
                        $PendingGroupRemovesDN[$gSam] = [System.Collections.Generic.List[string]]::new()
                    }
                    $PendingGroupRemovesDN[$gSam].Add($adUser.DistinguishedName)
                }
            }
        }
    }
}

# ==============================================================================
# 4. Direct High-Speed ADSI LDAP Account Provisioning (~10 Seconds Total)
# ==============================================================================
$missingUsers = @($users | Where-Object { 
    $uLower = $_.username.ToLower()
    -not [string]::IsNullOrWhiteSpace($uLower) -and -not $ADUserCache.ContainsKey($uLower) 
})

if ($missingUsers.Count -gt 0) {
    Write-Host "[*] Provisioning $($missingUsers.Count) missing AD accounts via Direct ADSI LDAP..."
    
    foreach ($u in $missingUsers) {
        $username  = $u.username
        $uLower    = $username.ToLower()
        $firstName = $u.first_name
        $lastName  = $u.last_name
        $fullName  = "$firstName $lastName"
        $email     = $u.email
        $uType     = $u.user_type
        $school    = $u.school
        $grade     = [string]$u.grade_level

        if ($uType -eq "STUDENT") {
            if ($grade -eq "GRAD" -or $school -like "*Graduates*") {
                $targetOU = "OU=Graduates,OU=Students,OU=APEX K12,$domainDN"
            } elseif (-not [string]::IsNullOrWhiteSpace($school) -and -not [string]::IsNullOrWhiteSpace($grade) -and $grade -ne "N/A") {
                $formattedGrade = if ($grade -match "^\d+$") { "{0:D2}" -f [int]$grade } else { $grade }
                $targetOU = "OU=Grade $formattedGrade,OU=$school,OU=Students,OU=APEX K12,$domainDN"
            } elseif (-not [string]::IsNullOrWhiteSpace($school)) {
                $targetOU = "OU=$school,OU=Students,OU=APEX K12,$domainDN"
            } else {
                $targetOU = "OU=Students,OU=APEX K12,$domainDN"
            }
        } elseif ($uType -eq "FACULTY") {
            $targetOU = "OU=Faculty,OU=Staff,OU=APEX K12,$domainDN"
        } elseif ($uType -eq "ADMIN") {
            $targetOU = "OU=Administration,OU=Staff,OU=APEX K12,$domainDN"
        } else {
            $targetOU = "OU=Support Staff,OU=Staff,OU=APEX K12,$domainDN"
        }

        $cnName = "$fullName ($username)"
        try {
            $ouObj = [adsi]"LDAP://$targetOU"
            $newUser = $ouObj.Create("user", "CN=$cnName")
            $newUser.Put("sAMAccountName", $username)
            $newUser.Put("userPrincipalName", "$username@$domain")
            $newUser.Put("givenName", $firstName)
            $newUser.Put("sn", $lastName)
            $newUser.Put("displayName", $fullName)
            $newUser.Put("mail", $email)
            $newUser.SetInfo()

            $newUser.SetPassword($plainPassword)
            $newUser.Put("userAccountControl", 66048) # Enabled (512) + Password Never Expires (65536)
            $newUser.SetInfo()

            $dn = "CN=$cnName,$targetOU"
            $ADUserDNMap[$uLower] = $dn
            $ADUserCache[$uLower] = [PSCustomObject]@{
                SamAccountName     = $username
                DistinguishedName  = $dn
                Enabled            = $true
            }
        } catch {
            Write-Error "[!] ADSI CREATION ERROR for ${username}: $($_.Exception.Message)"
        }
    }
}

# ==============================================================================
# 5. Dynamic Group Reconciliation & Instant DN-Based Queueing
# ==============================================================================
foreach ($u in $users) {
    $username = $u.username
    if ([string]::IsNullOrWhiteSpace($username)) { continue }
    $uLower = $username.ToLower()

    $userDN = $ADUserDNMap[$uLower]
    if ([string]::IsNullOrWhiteSpace($userDN)) { continue }

    $TargetGroupsForUser = @{}
    if ($u.user_type -eq "STUDENT") {
        if ($u.grade_level -eq "GRAD" -or $u.school -like "*Graduates*") {
            $TargetGroupsForUser["GRP_Graduates"] = $true
        } else {
            $TargetGroupsForUser["GRP_District_Students"] = $true
            $gradeGrp = Format-GradeGroup [string]$u.grade_level
            if ($gradeGrp) { $TargetGroupsForUser[$gradeGrp] = $true }
            if ($u.school -like "*Oakridge*") { $TargetGroupsForUser["GRP_Oakridge_ES"] = $true }
            elseif ($u.school -like "*Pinecrest*") { $TargetGroupsForUser["GRP_Pinecrest_ES"] = $true }
            elseif ($u.school -like "*Lakeside*") { $TargetGroupsForUser["GRP_Lakeside_MS"] = $true }
            elseif ($u.school -like "*Apex High*") { $TargetGroupsForUser["GRP_Apex_HS"] = $true }
        }
    } elseif ($u.user_type -eq "FACULTY") {
        $TargetGroupsForUser["GRP_District_Faculty"] = $true
    } else {
        $TargetGroupsForUser["GRP_District_Staff"] = $true
    }

    foreach ($gSam in $GroupMembers.Keys) {
        if ($TargetGroupsForUser.ContainsKey($gSam)) {
            if (-not $GroupMembers[$gSam].ContainsKey($uLower)) {
                if (-not $PendingGroupAddsDN.ContainsKey($gSam)) { 
                    $PendingGroupAddsDN[$gSam] = [System.Collections.Generic.List[string]]::new()
                }
                $PendingGroupAddsDN[$gSam].Add($userDN)
            }
        }
    }
}

# ==============================================================================
# 6. High-Speed Direct ADSI COM Group Commit (~1.5 Seconds Total)
# ==============================================================================
foreach ($gSam in $PendingGroupRemovesDN.Keys) {
    $list = $PendingGroupRemovesDN[$gSam]
    if ($list.Count -gt 0) {
        $groupDN = "CN=$gSam,$groupOU"
        try {
            $groupObj = [adsi]"LDAP://$groupDN"
            foreach ($dn in $list) {
                try { $groupObj.Remove("LDAP://$dn") } catch {}
            }
            Write-Host "[-] BULK STRIPPED $($list.Count) account(s) from Group '$gSam' via Direct ADSI COM"
        } catch {
            Write-Error "[!] ADSI Group Remove Error for ${gSam}: $($_.Exception.Message)"
        }
    }
}

foreach ($gSam in $PendingGroupAddsDN.Keys) {
    $list = $PendingGroupAddsDN[$gSam]
    if ($list.Count -gt 0) {
        $groupDN = "CN=$gSam,$groupOU"
        try {
            $groupObj = [adsi]"LDAP://$groupDN"
            foreach ($dn in $list) {
                try { $groupObj.Add("LDAP://$dn") } catch {}
            }
            Write-Host "[+] BULK ADDED $($list.Count) account(s) to Group '$gSam' via Direct ADSI COM"
        } catch {
            Write-Error "[!] ADSI Group Add Error for ${gSam}: $($_.Exception.Message)"
        }
    }
}

exit 0