#requires -Version 5.1
<#
.SYNOPSIS
Reconciles the existing HR CSV with the isolated iam.test / LAB-JML AD lab.
.DESCRIPTION
DryRun never calls directory write cmdlets. Logs are still written locally.
Accounts and groups outside the configured lab OUs are never adopted or changed.
Disabled Active accounts require explicit authorization by EmployeeID.
No account deletion, password export, session termination or Entra synchronization.
#>
[CmdletBinding()]
param(
    [string]$CsvPath = (Join-Path $PSScriptRoot '..\..\data\hr_feed.csv'),
    [switch]$DryRun,
    [switch]$ValidateOnly,
    [string[]]$ReactivateEmployeeId = @(),
    [string]$LogDirectory = (Join-Path $PSScriptRoot '..\..\logs\Phase2-Hybrid-AD')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$domainName = 'iam.test'
$domainDN = 'DC=iam,DC=test'
$usersOU = 'OU=Users,OU=LAB-JML,DC=iam,DC=test'
$groupsOU = 'OU=Groups,OU=LAB-JML,DC=iam,DC=test'
$departmentGroups = @{
    'Human-Resources' = 'GG-JML-Human-Resources'
    'SecOps' = 'GG-JML-SecOps'
    'IT-Infrastructure' = 'GG-JML-IT-Infrastructure'
}
$commonGroup = 'GG-JML-AllEmployees'
$requiredColumns = @('EmployeeID','GivenName','Surname','DisplayName',
    'UserPrincipalName','Department','JobTitle','AccountStatus')

# Validate the entire input before querying or changing AD.
if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
    throw "CSV not found: $CsvPath"
}
$rows = @(Import-Csv -LiteralPath $CsvPath -Encoding UTF8)
if ($rows.Count -eq 0) { throw 'The CSV must contain at least one employee.' }
foreach ($column in $requiredColumns) {
    if ($column -notin $rows[0].PSObject.Properties.Name) {
        throw "Missing CSV column: $column"
    }
}
$seenIds = @{}
$seenNames = @{}
foreach ($row in $rows) {
    foreach ($column in $requiredColumns) {
        $row.$column = ([string]$row.$column).Trim()
        if ([string]::IsNullOrWhiteSpace($row.$column)) {
            throw "Empty $column in the CSV. No directory changes performed."
        }
    }
    if ($seenIds.ContainsKey($row.EmployeeID)) {
        throw "Duplicate EmployeeID: $($row.EmployeeID)"
    }
    $seenIds[$row.EmployeeID] = $true
    if ($row.UserPrincipalName -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        throw "Invalid source UPN for $($row.EmployeeID)"
    }
    $sam = $row.UserPrincipalName.Split('@')[0].ToLowerInvariant()
    if ($sam.Length -gt 20 -or $sam -notmatch '^[a-z0-9._-]+$') {
        throw "Unsupported AD account name for $($row.EmployeeID): $sam"
    }
    if ($seenNames.ContainsKey($sam)) { throw "Duplicate account name: $sam" }
    $seenNames[$sam] = $true
    if (-not $departmentGroups.ContainsKey($row.Department)) {
        throw "Unknown Department for $($row.EmployeeID): $($row.Department)"
    }
    if ($row.AccountStatus -notin @('Active','Terminated')) {
        throw "Invalid AccountStatus for $($row.EmployeeID): $($row.AccountStatus)"
    }
}
foreach ($id in $ReactivateEmployeeId) {
    if (@($rows | Where-Object {
        $_.EmployeeID -eq $id -and $_.AccountStatus -eq 'Active'
    }).Count -ne 1) {
        throw "Reactivation ID must identify exactly one Active CSV record: $id"
    }
}
if ($ValidateOnly) {
    Write-Host "CSV valid: $($rows.Count) employees. AD was not accessed."
    $rows | Select-Object EmployeeID,DisplayName,Department,AccountStatus
    return
}

Import-Module ActiveDirectory -ErrorAction Stop
$domain = Get-ADDomain
if ($domain.DNSRoot -ne $domainName -or $domain.DistinguishedName -ne $domainDN) {
    throw 'This version only operates in the iam.test lab domain.'
}
$server = $domain.PDCEmulator
Get-ADOrganizationalUnit -Identity $usersOU -Server $server | Out-Null
Get-ADOrganizationalUnit -Identity $groupsOU -Server $server | Out-Null
$groups = @{}
$managedGroupNames = @($commonGroup) + @($departmentGroups.Values)
foreach ($name in $managedGroupNames) {
    $group = Get-ADGroup -Identity "CN=$name,$groupsOU" -Server $server
    if ($group.GroupCategory -ne 'Security' -or $group.GroupScope -ne 'Global') {
        throw "Expected a Global Security group: $name"
    }
    $groups[$name] = $group
}

function ConvertTo-LdapFilterValue {
    param([string]$Value)
    return $Value.Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29').Replace([string][char]0,'\00')
}

# Identity/collision checks for ALL employees, before any write operation.
$properties = @('EmployeeID','Department','Title','GivenName','Surname',
    'DisplayName','UserPrincipalName','MemberOf')
$entries = @(
    foreach ($row in $rows) {
        $sam = $row.UserPrincipalName.Split('@')[0].ToLowerInvariant()
        $localUPN = $row.UserPrincipalName # UPN de inicio de sesion que ya contiene el CSV.
        $idFilter = ConvertTo-LdapFilterValue $row.EmployeeID
        $samFilter = ConvertTo-LdapFilterValue $sam
        $upnFilter = ConvertTo-LdapFilterValue $localUPN
        $legacyUpnFilter = ConvertTo-LdapFilterValue "$sam@$domainName"
        $ldapFilter = "(|(employeeID=$idFilter)(sAMAccountName=$samFilter)(userPrincipalName=$upnFilter)(userPrincipalName=$legacyUpnFilter))"
        $matches = @(Get-ADUser -LDAPFilter $ldapFilter -SearchBase $domainDN -Properties $properties -Server $server)
        if ($matches.Count -gt 1) {
            throw "Multiple identity matches for $($row.EmployeeID). Resolve manually."
        }
        $user = $null
        if ($matches.Count -eq 1) {
            $user = $matches[0]
            if (-not $user.DistinguishedName.EndsWith(",$usersOU", [StringComparison]::OrdinalIgnoreCase)) {
                throw "Account outside the lab Users OU: $sam. No directory changes performed."
            }
            if ($user.EmployeeID -ne $row.EmployeeID -or $user.SamAccountName -ne $sam -or $user.UserPrincipalName -notin @($localUPN, "$sam@$domainName")) {
                throw "Identity mismatch for $($row.EmployeeID). No automatic adoption or rename."
            }
            if ($row.AccountStatus -eq 'Active' -and -not $user.Enabled -and $row.EmployeeID -notin $ReactivateEmployeeId) {
                throw "Active CSV record $($row.EmployeeID) has a disabled AD account. Explicitly review reactivation with -ReactivateEmployeeId $($row.EmployeeID)."
            }
        }
        [pscustomobject]@{ Row = $row; Sam = $sam; LocalUPN = $localUPN; User = $user }
    }
)

New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$logPath = Join-Path $LogDirectory "jml-ad-$runId.jsonl"
$script:actionCount = 0
$script:unchangedCount = 0
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-JmlRecord {
    param([string]$EmployeeId, [string]$Action, [string]$Result, [string]$Details)
    $record = [ordered]@{
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        runId = $runId
        operator = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        employeeId = $EmployeeId
        action = $Action
        result = $Result
        details = $Details
    }
    $json = $record | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($logPath, $json + [Environment]::NewLine, $utf8)
    Write-Host "[$Result] $EmployeeId | $Action | $Details"
}

function Invoke-JmlChange {
    param([string]$EmployeeId, [string]$Action, [string]$Details, [scriptblock]$Operation)
    if ($DryRun) {
        Write-JmlRecord $EmployeeId $Action 'Planned' $Details
    } else {
        & $Operation | Out-Null
        Write-JmlRecord $EmployeeId $Action 'Applied' $Details
    }
    $script:actionCount++
}

Write-JmlRecord '' 'RunStart' 'Info' "Source: $CsvPath; DryRun: $DryRun; employees: $($rows.Count)"
try {
    foreach ($entry in $entries) {
        $row = $entry.Row
        $user = $entry.User
        $sam = $entry.Sam
        $localUPN = $entry.LocalUPN
        $beforeCount = $script:actionCount

        if ($row.AccountStatus -eq 'Terminated') {
            if ($null -eq $user) {
                Write-JmlRecord $row.EmployeeID 'AbsentTerminated' 'Unchanged' 'Account absent; it will not be created.'
                $script:unchangedCount++
                continue
            }
            if ($user.Enabled) {
                Invoke-JmlChange $row.EmployeeID 'DisableAccount' $sam {
                    Disable-ADAccount -Identity $user.ObjectGUID -Server $server
                }
            }
            foreach ($name in $managedGroupNames) {
                $group = $groups[$name]
                if ($group.DistinguishedName -in @($user.MemberOf)) {
                    Invoke-JmlChange $row.EmployeeID 'RemoveGroup' $name {
                        Remove-ADGroupMember -Identity $group.ObjectGUID -Members $user.ObjectGUID -Server $server -Confirm:$false
                    }
                }
            }
        } else {
            $desiredGroups = @($commonGroup, $departmentGroups[$row.Department])
            if ($null -eq $user) {
                if ($DryRun) {
                    Invoke-JmlChange $row.EmployeeID 'CreateUser' "$sam; $($row.Department); temporary password required" {}
                    foreach ($name in $desiredGroups) {
                        Invoke-JmlChange $row.EmployeeID 'AddGroup' $name {}
                    }
                    continue
                }
                # Prompt separately for every NEW account. Never export or log passwords.
                $password = Read-Host "Temporary password for $($row.DisplayName) [$($row.EmployeeID)]" -AsSecureString
                try {
                    $newUser = New-ADUser -Name $row.DisplayName -DisplayName $row.DisplayName -GivenName $row.GivenName -Surname $row.Surname -SamAccountName $sam -UserPrincipalName $localUPN -EmployeeID $row.EmployeeID -Department $row.Department -Title $row.JobTitle -Path $usersOU -AccountPassword $password -Enabled $true -ChangePasswordAtLogon $true -Server $server -PassThru
                } finally {
                    if ($null -ne $password) { $password.Dispose() }
                }
                $script:actionCount++
                Write-JmlRecord $row.EmployeeID 'CreateUser' 'Applied' $sam
                $user = Get-ADUser -Identity $newUser.ObjectGUID -Properties $properties -Server $server
                if (-not $user.Enabled) { throw "New account $sam is disabled; check password setup before continuing." }
            }

            # Remove old departmental memberships before granting the new one.
            foreach ($name in $departmentGroups.Values) {
                $group = $groups[$name]
                if ($name -notin $desiredGroups -and $group.DistinguishedName -in @($user.MemberOf)) {
                    Invoke-JmlChange $row.EmployeeID 'RemoveGroup' $name {
                        Remove-ADGroupMember -Identity $group.ObjectGUID -Members $user.ObjectGUID -Server $server -Confirm:$false
                    }
                }
            }
            $desiredAttributes = @{
                GivenName = $row.GivenName; Surname = $row.Surname
                DisplayName = $row.DisplayName; Department = $row.Department; Title = $row.JobTitle
                UserPrincipalName = $localUPN
            }
            $changes = @{}
            foreach ($key in $desiredAttributes.Keys) {
                if ($user.$key -cne $desiredAttributes[$key]) { $changes[$key] = $desiredAttributes[$key] }
            }
            if ($changes.Count -gt 0) {
                Invoke-JmlChange $row.EmployeeID 'UpdateAttributes' ($changes.Keys -join ', ') {
                    Set-ADUser -Identity $user.ObjectGUID -Server $server @changes
                }
            }
            foreach ($name in $desiredGroups) {
                $group = $groups[$name]
                if ($group.DistinguishedName -notin @($user.MemberOf)) {
                    Invoke-JmlChange $row.EmployeeID 'AddGroup' $name {
                        Add-ADGroupMember -Identity $group.ObjectGUID -Members $user.ObjectGUID -Server $server
                    }
                }
            }
            # Re-enable only explicitly authorized IDs, after groups/attributes succeed.
            if (-not $user.Enabled) {
                Invoke-JmlChange $row.EmployeeID 'ReactivateAccount' $sam {
                    Enable-ADAccount -Identity $user.ObjectGUID -Server $server
                }
            }
        }
        if ($script:actionCount -eq $beforeCount) {
            Write-JmlRecord $row.EmployeeID 'NoChange' 'Unchanged' $sam
            $script:unchangedCount++
        }
    }
    # Check actual final state after apply; successful commands alone are not proof.
    if (-not $DryRun) {
        foreach ($entry in $entries) {
            $row = $entry.Row
            $idFilter = ConvertTo-LdapFilterValue $row.EmployeeID
            $actual = @(Get-ADUser -LDAPFilter "(employeeID=$idFilter)" -SearchBase $usersOU -Properties $properties -Server $server)
            if ($row.AccountStatus -eq 'Terminated' -and $actual.Count -eq 0) { continue }
            if ($actual.Count -ne 1) { throw "Verification failed: identity count for $($row.EmployeeID)" }
            $actualUser = $actual[0]
            $actualManagedGroups = @($managedGroupNames | Where-Object {
                $groups[$_].DistinguishedName -in @($actualUser.MemberOf)
            })
            if ($row.AccountStatus -eq 'Active') {
                $expectedGroups = @($commonGroup, $departmentGroups[$row.Department])
                if (-not $actualUser.Enabled -or $actualUser.Department -cne $row.Department -or $actualUser.Title -cne $row.JobTitle -or $actualUser.SamAccountName -ne $entry.Sam -or $actualUser.UserPrincipalName -ne $entry.LocalUPN -or $actualManagedGroups.Count -ne 2 -or @($expectedGroups | Where-Object { $_ -notin $actualManagedGroups }).Count -gt 0) {
                    throw "Verification failed: Active state or groups for $($row.EmployeeID)"
                }
            } elseif ($actualUser.Enabled -or $actualManagedGroups.Count -ne 0) {
                throw "Verification failed: Terminated state or groups for $($row.EmployeeID)"
            }
            Write-JmlRecord $row.EmployeeID 'VerifyState' 'Verified' $entry.Sam
        }
    }
    Write-JmlRecord '' 'RunComplete' 'Info' "Actions: $script:actionCount; unchanged employees: $script:unchangedCount"
} catch {
    Write-JmlRecord '' 'RunFailed' 'Error' $_.Exception.Message
    throw
} finally {
    Write-Host "Log: $logPath"
}
