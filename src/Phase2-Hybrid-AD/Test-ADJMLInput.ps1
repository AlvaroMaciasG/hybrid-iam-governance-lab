#requires -Version 5.1
# Native syntax and CSV preflight tests. Does not access or modify AD.
[CmdletBinding()]
param([string]$CsvPath = (Join-Path $PSScriptRoot '..\..\data\hr_feed.csv'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$entryPoint = Join-Path $PSScriptRoot 'Invoke-ADJMLProvisioning.ps1'
$syntaxTokens = $null
$syntaxErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($entryPoint, [ref]$syntaxTokens, [ref]$syntaxErrors) | Out-Null
if (@($syntaxErrors).Count -gt 0) {
    $syntaxErrors | Format-List Message,Extent
    throw 'FAIL: PowerShell syntax validation.'
}
Write-Host 'PASS: native PowerShell syntax'
$valid = @(& $entryPoint -CsvPath $CsvPath -ValidateOnly)
if ($valid.Count -ne 4 -or @($valid | Where-Object { $_.EmployeeID -eq 'EMP004' -and $_.AccountStatus -eq 'Terminated' }).Count -ne 1) {
    throw 'FAIL: expected the original four employees and EMP004 Terminated.'
}
Write-Host 'PASS: original four-row CSV'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ad-jml-input-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    foreach ($case in @('DuplicateEmployeeID','UnknownDepartment','InvalidStatus','EmptyField','DuplicateAccountName','LongAccountName','MissingColumn')) {
        $data = @(Import-Csv -LiteralPath $CsvPath -Encoding UTF8)
        switch ($case) {
            'DuplicateEmployeeID' { $data[1].EmployeeID = $data[0].EmployeeID }
            'UnknownDepartment' { $data[0].Department = 'Not-A-Department' }
            'InvalidStatus' { $data[0].AccountStatus = 'Typo-Status' }
            'EmptyField' { $data[0].DisplayName = ' ' }
            'DuplicateAccountName' { $data[1].UserPrincipalName = $data[0].UserPrincipalName }
            'LongAccountName' { $data[0].UserPrincipalName = 'abcdefghijklmnopqrstu@example.test' }
            'MissingColumn' { $data = @($data | Select-Object * -ExcludeProperty JobTitle) }
        }
        $badPath = Join-Path $tempRoot "$case.csv"
        $data | Export-Csv -LiteralPath $badPath -NoTypeInformation -Encoding UTF8
        $rejected = $false
        try { & $entryPoint -CsvPath $badPath -ValidateOnly | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw "FAIL: invalid input accepted: $case" }
        Write-Host "PASS: rejected $case"
    }
    $rejected = $false
    try { & $entryPoint -CsvPath $CsvPath -ValidateOnly -ReactivateEmployeeId EMP004 | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'FAIL: reactivation accepted for a Terminated record.' }
    Write-Host 'PASS: rejected reactivation of Terminated EMP004'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
Write-Host 'PASS: all 10 syntax/input checks. AD has not been accessed.'
