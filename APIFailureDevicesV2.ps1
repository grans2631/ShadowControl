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

function Write-Section {
    param([string]$Title)

    Write-Output ""
    Write-Output "============================================================"
    Write-Output $Title
    Write-Output "============================================================"
}

function Write-KeyValue {
    param(
        [string]$Label,
        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        Write-Output ("{0,-14}: <null>" -f $Label)
    }
    else {
        Write-Output ("{0,-14}: {1}" -f $Label, $Value)
    }
}

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

    $machinesFound = 0

    foreach ($endpointKey in $Status.PSObject.Properties.Name) {
        $endpoint = $Status.$endpointKey

        if ($null -eq $endpoint.imagemanager) {
            continue
        }

        $entries = Find-ImageManagerMessages -Object $endpoint.imagemanager

        if ($entries.Count -gt 0) {
            $machinesFound++

            Write-Section ("Machine Name: {0}" -f $endpoint.name)

            Write-Output "Imagemanager Details"

            $sortedEntries = $entries |
                Sort-Object Category, Type, Reason, Code

            foreach ($entry in $sortedEntries) {
                Write-KeyValue "Category"    $entry.Category
                Write-KeyValue "Type"        $entry.Type
                Write-KeyValue "Code"        $entry.Code
                Write-KeyValue "Reason"      $entry.Reason
                Write-KeyValue "Criticality" $entry.Criticality
                Write-Output "------------------------------------------------------------"
            }
        }
    }

    if ($machinesFound -eq 0) {
        Write-Output "No machines found with populated errors or warnings under consolidation, verification, retention, or replication_jobs."
        exit 0
    }
}
catch {
    Write-Output "API call failed."
    Write-Output ("Message: {0}" -f $_.Exception.Message)

    if ($_.Exception.InnerException) {
        Write-Output ("Inner: {0}" -f $_.Exception.InnerException.Message)
    }

    exit 1
}
