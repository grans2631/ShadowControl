#$Appliance = "Appliance URL Here"
#$Token     = "API Token Here"

# Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Bypass SSL cert validation for PowerShell 5.1 / Automate
# Only define the type if it does not already exist in this PowerShell session.
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
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
}

[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

$Headers = @{
    CMD_TOKEN = $Token
}

# Set CSV path
$CsvPath = "C:\Temp\ImageManager\Replication Issues\ImageManager_ReplicationJobs_Issues.csv"

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

function Get-NearestNameFromPathNodes {
    param(
        [System.Collections.ArrayList]$NodeStack
    )

    if ($null -eq $NodeStack -or $NodeStack.Count -eq 0) {
        return $null
    }

    for ($i = $NodeStack.Count - 1; $i -ge 0; $i--) {
        $node = $NodeStack[$i]
        if ($null -ne $node -and $node.PSObject.Properties.Name -contains 'name' -and -not [string]::IsNullOrWhiteSpace($node.name)) {
            return $node.name
        }
    }

    return $null
}

function Add-MessageEntriesFromList {
    param(
        [string]$EntryType,
        $EntryList,
        [string]$Path,
        [System.Collections.ArrayList]$NodeStack,
        [ref]$Results
    )

    $category = Get-TargetCategoryFromPath -Path $Path
    if ($null -eq $category) { return }

    foreach ($entry in @($EntryList)) {
        if ($null -eq $entry) { continue }

        $itemName = Get-NearestNameFromPathNodes -NodeStack $NodeStack

        $Results.Value += [PSCustomObject]@{
            Category    = $category
            ItemName    = $itemName
            Type        = $EntryType
            Code        = $entry.code
            Reason      = $entry.reason
            Criticality = $entry.criticality
        }
    }
}

function Find-ImageManagerMessages {
    param(
        $Object,
        [string]$Path = "imagemanager",
        [System.Collections.ArrayList]$NodeStack = $(New-Object System.Collections.ArrayList)
    )

    $results = @()

    if ($null -eq $Object) {
        return $results
    }

    if (Test-IsSimpleValue $Object) {
        return $results
    }

    if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string] -and $Object -isnot [System.Management.Automation.PSCustomObject]) {
        $index = 0
        foreach ($item in $Object) {
            $childPath = "$Path[$index]"
            $results += Find-ImageManagerMessages -Object $item -Path $childPath -NodeStack $NodeStack
            $index++
        }
        return $results
    }

    if ($Object -is [System.Management.Automation.PSCustomObject] -or $Object -is [hashtable]) {
        [void]$NodeStack.Add($Object)

        $propNames = @($Object.PSObject.Properties.Name)

        if ($propNames -contains 'errors' -and $null -ne $Object.errors) {
            Add-MessageEntriesFromList -EntryType "Error" -EntryList $Object.errors -Path "$Path.errors" -NodeStack $NodeStack -Results ([ref]$results)
        }

        if ($propNames -contains 'warnings' -and $null -ne $Object.warnings) {
            Add-MessageEntriesFromList -EntryType "Warning" -EntryList $Object.warnings -Path "$Path.warnings" -NodeStack $NodeStack -Results ([ref]$results)
        }

        foreach ($prop in $Object.PSObject.Properties) {
            $propName = $prop.Name
            $propValue = $prop.Value

            if ($propName -in @('errors','warnings')) {
                continue
            }

            if ($null -eq $propValue) {
                continue
            }

            if (Test-IsSimpleValue $propValue) {
                continue
            }

            $childPath = "$Path.$propName"
            $results += Find-ImageManagerMessages -Object $propValue -Path $childPath -NodeStack $NodeStack
        }

        $NodeStack.RemoveAt($NodeStack.Count - 1)
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
        Write-Output "No data returned from ShadowControl API"
        exit 1
    }

    $csvRows = @()

    foreach ($endpointKey in $Status.PSObject.Properties.Name) {
        $endpoint = $Status.$endpointKey

        if ($null -eq $endpoint.imagemanager) {
            continue
        }

        $entries = Find-ImageManagerMessages -Object $endpoint.imagemanager

        $replicationEntries = $entries | Where-Object { $_.Category -eq 'replication_jobs' }

        if ($replicationEntries.Count -gt 0) {
            foreach ($entry in $replicationEntries) {
                $csvRows += [PSCustomObject]@{
                    MachineName = $endpoint.name
                    Category    = $entry.Category
                    Type        = $entry.Type
                    Reason      = $entry.Reason
                }
            }
        }
    }

    if ($csvRows.Count -eq 0) {
        Write-Output "No machines found with populated errors or warnings under replication_jobs."
        exit 0
    }

    $csvRows = $csvRows | Sort-Object MachineName, Category, Type, Reason -Unique

    $folder = Split-Path -Path $CsvPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($folder) -and -not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    $csvRows |
        Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

    Write-Output "CSV export completed."
    Write-Output ("File: {0}" -f $CsvPath)
    Write-Output ("Rows: {0}" -f $csvRows.Count)
}
catch {
    Write-Output "API call failed."
    Write-Output ("Message: {0}" -f $_.Exception.Message)

    if ($_.Exception.InnerException) {
        Write-Output ("Inner: {0}" -f $_.Exception.InnerException.Message)
    }

    exit 1
}
