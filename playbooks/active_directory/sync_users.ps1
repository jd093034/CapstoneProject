# Load Windows' Active Directory tools.
# -ErrorAction Stop means: if these tools aren't installed, stop the whole script immediately.
Import-Module ActiveDirectory -ErrorAction Stop

# File paths where Ansible drops the active and inactive user lists exported from PostgreSQL
$jsonPath         = "C:\Windows\Temp\dynamic_ad_users.json"
$inactiveJsonPath = "C:\Windows\Temp\dynamic_inactive_users.json"

# @() creates an empty list. Wrapping results in @(...) forces them to stay a list even if
# the file has 0 or 1 user, which prevents errors later when we check $users.Count.
$users = @()
# Test-Path checks if the file actually exists on the hard drive (returns $true or $false)
if (Test-Path $jsonPath) {
    # Get-Content -Raw reads the whole file as one block of text; | pipes that text into ConvertFrom-Json
    $raw = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json
    # $null is PowerShell's word for "nothing/empty". -ne means "not equal", and -is checks the data type.
    if ($null -ne $raw.dynamic_ad_users) {
        $users = @($raw.dynamic_ad_users)
    } elseif ($raw -is [System.Array]) {
        $users = $raw
    } else {
        $users = @($raw)
    }
}

# Same list-wrapping setup for terminated/withdrawn users
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

# Write-Host prints status text to the screen. $(...) lets us run .Count inside a double-quoted sentence.
Write-Host "Loaded $($users.Count) active user(s) and $($inactiveUsers.Count) inactive user(s) for K-12 AD sync."

$domain        = "apex.lab"
# Ask Active Directory for our domain's root path ("DC=apex,DC=lab") so we don't have to hardcode it
$domainDN      = (Get-ADDomain).DistinguishedName
# Folder path where terminated users get quarantined
$disabledOU    = "OU=Users - Disabled,OU=APEX K12,$domainDN"
# Folder path where all district/school/grade security groups live
$groupOU       = "OU=Groups,OU=APEX K12,$domainDN"
# $env: reads a Windows environment variable passed by Ansible; if none was sent, use the fallback password
$plainPassword = if ($env:DEFAULT_PASSWORD) { $env:DEFAULT_PASSWORD } else { "StudentPass2026!" }

# Reference list of old folder paths left over from earlier lab runs before we switched to the K-12 layout
$legacyOUs = @(
    "OU=Departments,OU=APEX Lab,$domainDN",
    "OU=APEX Lab,$domainDN",
    "OU=Users - Disabled,$domainDN",
    "OU=Disabled Users,$domainDN"
)

# --- Build the K-12 folders (OUs) and security groups ---
# Parent folders have to be listed first so the subfolders inside them have somewhere to go
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

# 0..5 counts from 0 to 5. $_ is the current number in the loop, += tacks the new folder onto $K12_OUs,
# and -f plugs $_ into {0:D2} so single digits get a leading zero (00 = Kindergarten, 05 = 5th grade).
0..5  | ForEach-Object { $K12_OUs += ("OU=Grade {0:D2},OU=Oakridge Elementary,OU=Students,OU=APEX K12,$domainDN" -f $_) }
0..5  | ForEach-Object { $K12_OUs += ("OU=Grade {0:D2},OU=Pinecrest Elementary,OU=Students,OU=APEX K12,$domainDN" -f $_) }
6..8  | ForEach-Object { $K12_OUs += ("OU=Grade {0:D2},OU=Lakeside Middle School,OU=Students,OU=APEX K12,$domainDN" -f $_) }
9..12 | ForEach-Object { $K12_OUs += ("OU=Grade {0:D2},OU=Apex High School,OU=Students,OU=APEX K12,$domainDN" -f $_) }

# Loop through every folder path one by one
foreach ($ouPath in $K12_OUs) {
    # -not flips true/false. LDAP:// is the address prefix Windows uses to check if a folder already exists in AD.
    if (-not [DirectoryServices.DirectoryEntry]::Exists("LDAP://$ouPath")) {
        # -split ',' chops the path at commas: [0] grabs the new folder's name, and "-split ',', 2" splits
        # into just 2 chunks so [1] keeps the entire parent folder path intact. -replace strips off "OU=".
        $ouName = ($ouPath -split ',')[0] -replace 'OU=', ''
        $parentPath = ($ouPath -split ',', 2)[1]
        # Turn off Windows' accidental delete lock ($false) so wipe_all.sh can delete everything cleanly between runs.
        # -ErrorAction SilentlyContinue tells PowerShell to ignore minor warnings and keep moving.
        New-ADOrganizationalUnit -Name $ouName -Path $parentPath -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
    }
}

# @{} creates an empty lookup table (key -> value) so we can check existing groups instantly
$ExistingGroupsHash = @{}
# -SearchBase limits the search to just our Groups folder; -Filter grabs only groups starting with "GRP_".
# SamAccountName is Windows' internal name for an account/group name, and .ToLower() makes it lowercase.
Get-ADGroup -Filter "SamAccountName -like 'GRP_*'" -SearchBase $groupOU -ErrorAction SilentlyContinue | ForEach-Object {
    $ExistingGroupsHash[$_.SamAccountName.ToLower()] = $_
}

# List of all district, school, and grade security groups (GRP_Grade_00 through GRP_Grade_12)
$BaseGroups = @(
    "GRP_District_Students", "GRP_District_Faculty", "GRP_District_Staff", "GRP_Graduates",
    "GRP_Oakridge_ES", "GRP_Pinecrest_ES", "GRP_Lakeside_MS", "GRP_Apex_HS"
)
0..12 | ForEach-Object { $BaseGroups += ("GRP_Grade_{0:D2}" -f $_) }

# Create any missing Global Security Groups inside $groupOU
foreach ($grpName in $BaseGroups) {
    if (-not $ExistingGroupsHash.ContainsKey($grpName.ToLower())) {
        New-ADGroup -Name $grpName -SamAccountName $grpName -GroupCategory Security -GroupScope Global -Path $groupOU -ErrorAction SilentlyContinue
    }
}

# --- Save current AD users and groups into memory for speed ---
# Asking Active Directory 1,000 separate times inside a loop is super slow.
# Instead, we grab everyone once at the start and store them in memory lookup tables.
Write-Host "[*] Pre-caching Active Directory user store and security groups..."

$ADUserCache = @{} # Lookup table: username -> full AD user info (including whether Enabled is true/false)
$ADUserDNMap = @{} # Lookup table: username -> DistinguishedName (the user's exact folder path in AD)

# -Filter * means "grab every user" inside OU=APEX K12; -Properties asks AD to include Enabled and DistinguishedName
Get-ADUser -Filter * -SearchBase "OU=APEX K12,$domainDN" -Properties Enabled, DistinguishedName -ErrorAction SilentlyContinue | ForEach-Object {
    $uLower = $_.SamAccountName.ToLower()
    $ADUserCache[$uLower] = $_
    $ADUserDNMap[$uLower] = $_.DistinguishedName
}

# Nested lookup table: $GroupMembers["GRP_Name"]["username"] = $true
$GroupMembers = @{}
# -Properties member tells Get-ADGroup to also return the list of everyone currently inside each group
Get-ADGroup -Filter "SamAccountName -like 'GRP_*'" -SearchBase $groupOU -Properties member -ErrorAction SilentlyContinue | ForEach-Object {
    $grpSam = $_.SamAccountName
    $memberHash = @{}
    if ($_.member) {
        foreach ($mDN in $_.member) {
            # Display names look like "John Smith (jsmith1)". -match searches for the text inside the
            # parentheses and automatically saves that captured username into $Matches[1].
            if ($mDN -match "CN=.*?\((.*?)\),") {
                $memberHash[$Matches[1].ToLower()] = $true
            } else {
                # Fallback if an older account didn't have parentheses: grab the CN= piece and strip "CN="
                $cnVal = ($mDN -split ',')[0] -replace 'CN=', ''
                $memberHash[$cnVal.ToLower()] = $true
            }
        }
    }
    $GroupMembers[$grpSam] = $memberHash
}

# To-do lists mapping each group name -> list of user paths (DNs) to add or remove in bulk at the end
$PendingGroupAddsDN    = @{}
$PendingGroupRemovesDN = @{}

# Reusable helper function that turns a grade number like "5" into the group name "GRP_Grade_05"
function Format-GradeGroup ($gradeStr) {
    # Ignore blank values, "N/A" (staff), or "GRAD" (alumni); return $null means "no grade group needed"
    if ([string]::IsNullOrWhiteSpace($gradeStr) -or $gradeStr -eq "N/A" -or $gradeStr -eq "GRAD") { return $null }
    $gInt = 0
    # TryParse safely checks if $gradeStr is a valid number without crashing;
    # [ref]$gInt gives TryParse a variable box to store the converted integer into.
    if ([int]::TryParse($gradeStr, [ref]$gInt)) {
        return ("GRP_Grade_{0:D2}" -f $gInt)
    }
    return $null
}

# --- Disable or delete users who left the school ---
foreach ($u in $inactiveUsers) {
    $username = $u.username
    # continue skips the rest of the loop for this entry if the username is blank
    if ([string]::IsNullOrWhiteSpace($username)) { continue }
    $uLower = $username.ToLower()

    # Only act if this person currently has an account in Active Directory
    if ($ADUserCache.ContainsKey($uLower)) {
        $adUser = $ADUserCache[$uLower]
        $daysSinceTerm = 0
        # [string] forces terminated_at into plain text so date checks don't trip over null values
        $rawTermAt = [string]$u.terminated_at

        # try/catch is a safety net: parse the termination date and subtract it from today's date ([DateTime]::Now).
        # [Math]::Max(0, ...) guarantees we never get a negative day count if a test timestamp is slightly ahead.
        if (-not [string]::IsNullOrWhiteSpace($rawTermAt) -and $rawTermAt -ne "null" -and $rawTermAt -ne "None") {
            try {
                $termDate = [DateTime]::Parse($rawTermAt)
                $daysSinceTerm = [Math]::Max(0, (([DateTime]::Now) - $termDate).Days)
            } catch {
                $daysSinceTerm = 0
            }
        }

        # -gt means "greater than" and -and means both conditions must be true:
        # Delete accounts terminated over 30 days ago UNLESS legal_hold is true.
        if ($daysSinceTerm -gt 30 -and -not [bool]$u.legal_hold) {
            # -Confirm:$false skips the "Are you sure?" popup so automation doesn't hang waiting for input
            Remove-ADUser -Identity $username -Confirm:$false -ErrorAction SilentlyContinue
            $ADUserCache.Remove($uLower)
            $ADUserDNMap.Remove($uLower)
        } else {
            # Within 30 days (or frozen by a legal hold):
            # 1. Disable their account so they cannot log in
            if ($adUser.Enabled) {
                Set-ADUser -Identity $username -Enabled $false -ErrorAction SilentlyContinue
            }
            # 2. -notlike checks wildcard text: if they aren't already in the Disabled folder, move them there
            if ($adUser.DistinguishedName.ToLower() -notlike "*$($disabledOU.ToLower())*") {
                Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $disabledOU -ErrorAction SilentlyContinue
            }
            # 3. Check every group ($GroupMembers.Keys); if they are a member, add them to the removal to-do list
            foreach ($gSam in $GroupMembers.Keys) {
                if ($GroupMembers[$gSam].ContainsKey($uLower)) {
                    if (-not $PendingGroupRemovesDN.ContainsKey($gSam)) { 
                        # Create a fast expandable text list to collect everyone being stripped from this group
                        $PendingGroupRemovesDN[$gSam] = [System.Collections.Generic.List[string]]::new()
                    }
                    $PendingGroupRemovesDN[$gSam].Add($adUser.DistinguishedName)
                }
            }
        }
    }
}

# --- Create missing AD accounts ---
# Where-Object filters $users down to only active people who aren't already in our AD lookup table
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

        # -eq means "equals" and -like checks wildcard text (*Graduates*).
        # Pick the exact folder path where this user belongs based on role, campus, and grade.
        if ($uType -eq "STUDENT") {
            if ($grade -eq "GRAD" -or $school -like "*Graduates*") {
                $targetOU = "OU=Graduates,OU=Students,OU=APEX K12,$domainDN"
            } elseif (-not [string]::IsNullOrWhiteSpace($school) -and -not [string]::IsNullOrWhiteSpace($grade) -and $grade -ne "N/A") {
                # "^\d+$" checks if the grade is all numbers; [int]$grade converts "5" to a number so {0:D2} makes it "05"
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

        # Put the username in parentheses ("John Smith (jsmith1)") so Active Directory doesn't throw a
        # duplicate-name collision error if two students in the same grade share the exact same name.
        $cnName = "$fullName ($username)"
        try {
            # [adsi] is Windows' direct shortcut for talking to Active Directory. Using it directly instead of
            # the normal New-ADUser command skips slow background steps and creates 1,000 accounts in ~10 seconds.
            $ouObj = [adsi]"LDAP://$targetOU"
            $newUser = $ouObj.Create("user", "CN=$cnName")
            # .Put() fills in standard AD fields (sAMAccountName = login, givenName = first, sn = last),
            # and .SetInfo() hits "Save" to write the new account into Active Directory.
            $newUser.Put("sAMAccountName", $username)
            $newUser.Put("userPrincipalName", "$username@$domain")
            $newUser.Put("givenName", $firstName)
            $newUser.Put("sn", $lastName)
            $newUser.Put("displayName", $fullName)
            $newUser.Put("mail", $email)
            $newUser.SetInfo()

            # Set their password and activate the account:
            # Windows uses number codes for account settings—66048 turns the account ON (512) + sets password never expires (65536).
            $newUser.SetPassword($plainPassword)
            $newUser.Put("userAccountControl", 66048)
            $newUser.SetInfo()

            # [PSCustomObject]@{} builds a matching user record in our memory lookup tables so the group
            # assignment section right below sees this brand-new user without re-querying Active Directory.
            $dn = "CN=$cnName,$targetOU"
            $ADUserDNMap[$uLower] = $dn
            $ADUserCache[$uLower] = [PSCustomObject]@{
                SamAccountName     = $username
                DistinguishedName  = $dn
                Enabled            = $true
            }
        } catch {
            # Curly braces around ${username} keep the colon ":" right after it from confusing PowerShell;
            # $_.Exception.Message pulls the readable error text if creating that specific user failed.
            Write-Error "[!] ADSI CREATION ERROR for ${username}: $($_.Exception.Message)"
        }
    }
}

# --- Match active users to their security groups ---
foreach ($u in $users) {
    $username = $u.username
    if ([string]::IsNullOrWhiteSpace($username)) { continue }
    $uLower = $username.ToLower()

    $userDN = $ADUserDNMap[$uLower]
    if ([string]::IsNullOrWhiteSpace($userDN)) { continue }

    # Build a checklist table ($TargetGroupsForUser) of every group this user should belong to
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

    # Check our memory lookup table—if they aren't already in a required group, add them to the to-do list
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

# --- Apply all group removals and additions in bulk ---
# Open each group directly with [adsi] and remove/add everyone on the to-do list in one fast batch (~1.5 seconds).
# The empty "catch {}" ignores harmless errors if someone was already removed or added.
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

# Exit code 0 tells Ansible the script finished cleanly with zero errors
exit 0