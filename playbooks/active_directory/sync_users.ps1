Import-Module ActiveDirectory -ErrorAction Stop

$jsonPath = "C:\Windows\Temp\dynamic_ad_users.json"
if (-not (Test-Path $jsonPath)) {
    Write-Host "JSON file not found at $jsonPath"
    exit 0
}

$raw = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json
if ($null -ne $raw.dynamic_ad_users) {
    $users = @($raw.dynamic_ad_users)
} elseif ($raw -is [System.Array]) {
    $users = $raw
} else {
    $users = @($raw)
}

Write-Host "Loaded $($users.Count) user record(s) for Active Directory synchronization."

$domain   = "apex.lab"
$parentOU = "OU=APEX Lab,DC=apex,DC=lab"
$targetOU = "OU=Departments,OU=APEX Lab,DC=apex,DC=lab"
$userOU   = "CN=Users,DC=apex,DC=lab"

# 1. Ensure required Organizational Units exist
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$parentOU'" -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name "APEX Lab" -Path "DC=apex,DC=lab" -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
    Write-Host "[+] CREATED OU: APEX Lab"
}
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$targetOU'" -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name "Departments" -Path $parentOU -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
    Write-Host "[+] CREATED OU: Departments"
}

$secPassword = ConvertTo-SecureString $env:DEFAULT_PASSWORD -AsPlainText -Force

# 2. Ensure Department Security Groups exist inside Departments OU
$depts = @($users | Select-Object -ExpandProperty department -Unique | Where-Object { $_ })
foreach ($d in $depts) {
    $groupSam = $d -replace '[\\/:*?"<>|]', ''
    $grp = Get-ADGroup -Filter "SamAccountName -eq '$groupSam'" -ErrorAction SilentlyContinue
    if (-not $grp) {
        New-ADGroup -Name $d -SamAccountName $groupSam -GroupScope Global -GroupCategory Security -Path $targetOU -ErrorAction SilentlyContinue
        Write-Host "[+] CREATED AD GROUP: '$d'"
    } else {
        Write-Host "[=] AD GROUP EXISTS: '$d'"
    }
}

# 3. Provision Users, Update Paths, Clean Stale Groups & Bind Target Groups
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
        New-ADUser -Name $fullName `
                   -GivenName $firstName `
                   -Surname $lastName `
                   -UserPrincipalName "$username@$domain" `
                   -SamAccountName $username `
                   -EmailAddress $email `
                   -Path $userOU `
                   -AccountPassword $secPassword `
                   -Enabled $true `
                   -PasswordNeverExpires $true `
                   -ErrorAction SilentlyContinue
        Write-Host "[+] CREATED AD USER: $username ($fullName)"
    } else {
        if ($adUser.DistinguishedName -notlike "*$userOU*") {
            Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $userOU -ErrorAction SilentlyContinue
            Write-Host "[*] MOVED AD USER: $username -> $userOU"
        } else {
            Write-Host "[=] AD USER EXISTS: $username"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($dept)) {
        $deptSam = $dept -replace '[\\/:*?"<>|]', ''

        $currentDeptGroups = Get-ADPrincipalGroupMembership -Identity $username -ErrorAction SilentlyContinue | 
            Where-Object { $_.DistinguishedName -like "*$targetOU*" }

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
