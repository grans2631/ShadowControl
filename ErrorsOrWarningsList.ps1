#$Appliance = "Appliance URL Here"
#$Token     = "API Token Here"

# Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Bypass SSL cert validation for PowerShell 5.1 / Automate
Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;

public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint,
        X509Certificate certificate,
        WebRequest request,
        int certificateProblem) {
        return true;
    }
}
"@

[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

$Headers = @{
    CMD_TOKEN = $Token
}

# Set this to one of:
# consolidation
# replication_jobs
# retention
# verification
$TargetCategory = "replication_jobs"

function Test-IsSimpleValue {
    param($Value)

    return (
        $null -eq $Value -or
        $Value -is [string] -or
        $Value -is [int] -or
        $Value -is [long] -or
        $Value -is [double] -or
        $Value -is [decimal] -or
        $Value -is [bool] -or
        $Value -is [datetime]
    )
}

function Get-TargetCategoryFromPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    foreach ($name in @("consolidation","replication_jobs","retention","verification")) {
        if ($Path -match "(^|[./])$name($|[./\[])" -or $Path -eq $name) {
            return $name
        }
    }

    return $null
}

function Add-MessageEntriesFromList {
    param(
        [string]$EntryType,
        $EntryList,
        [string]$Path,
        [ref]$Results
    )

    $category = Get-TargetCategoryFromPath -Path $Path
    if ($null -eq $category) { return }

    foreach ($entry in @($EntryList)) {
        if ($null -eq $entry) { continue }

        $Results.Value += [PSCustomObject]@{
            Category = $category
            Type     = $EntryType
        }
    }
}

function Find-ImageManagerMessages {
    param(
        $Object,
        [string]$Path = "imagemanager"
    )

    $results = @()

    if ($null -eq $Object) { return $results }
    if (Test-IsSimpleValue $Object) { return $results }

    if ($Object -is [System.Collections.IEnumerable] -and
        $Object -isnot [string] -and
        $Object -isnot [System.Management.Automation.PSCustomObject]) {

        $index = 0
        foreach ($item in $Object) {
            $results += Find-ImageManagerMessages -Object $item -Path "$Path[$index]"
            $index++
        }
        return $results
    }

    if ($Object -is [System.Management.Automation.PSCustomObject] -or $Object -is [hashtable]) {
        $propNames = @($Object.PSObject.Properties.Name)

        if ($propNames -contains 'errors' -and $null -ne $Object.errors) {
            Add-MessageEntriesFromList -EntryType "Error" -EntryList $Object.errors -Path "$Path.errors" -Results ([ref]$results)
        }

        if ($propNames -contains 'warnings' -and $null -ne $Object.warnings) {
            Add-MessageEntriesFromList -EntryType "Warning" -EntryList $Object.warnings -Path "$Path.warnings" -Results ([ref]$results)
        }

        foreach ($prop in $Object.PSObject.Properties) {
            if ($prop.Name -in @('errors','warnings')) { continue }
            if ($null -eq $prop.Value) { continue }
            if (Test-IsSimpleValue $prop.Value) { continue }

            $results += Find-ImageManagerMessages -Object $prop.Value -Path "$Path.$($prop.Name)"
        }
    }

    return $results
}

try {
    $Status = Invoke-RestMethod `
        -Uri "$Appliance/api/reports/status/" `
        -Headers $Headers `
        -Method Get `
        -ErrorAction Stop

    if (-not $Status) {
        exit 1
    }

    $machineNames = New-Object System.Collections.Generic.List[string]

    foreach ($endpointKey in $Status.PSObject.Properties.Name) {
        $endpoint = $Status.$endpointKey
        if ($null -eq $endpoint.imagemanager) { continue }
        if ([string]::IsNullOrWhiteSpace($endpoint.name)) { continue }

        $entries = Find-ImageManagerMessages -Object $endpoint.imagemanager

        $hasTargetCategory = $false
        foreach ($entry in $entries) {
            if ($entry.Category -eq $TargetCategory) {
                $hasTargetCategory = $true
                break
            }
        }

        if ($hasTargetCategory) {
            [void]$machineNames.Add($endpoint.name)
        }
    }

    $machineNames |
        Sort-Object -Unique |
        ForEach-Object { Write-Output $_ }

    exit 0
}
catch {
    exit 1
}
