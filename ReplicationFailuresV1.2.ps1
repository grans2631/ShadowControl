param(
    [string]$Appliance = "Appliance URL",
    [string]$Token = "API Token",


    # How old replication success can be before we treat it as stale/problematic
    [int]$ReplicationStaleHours = 8
)

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

function Convert-ToGB {
    param([double]$Value)
    if ($null -eq $Value) { return $null }
    return [math]::Round(($Value / 1024), 2)
}

function Get-ArrayCount {
    param($Value)
    if ($null -eq $Value) { return 0 }
    if ($Value -is [System.Array]) { return $Value.Count }
    if ($Value -is [System.Collections.ICollection]) { return $Value.Count }
    return 1
}

function Test-IsReplicationIssue {
    param(
        $Endpoint,
        $Folder,
        $ReplicationJob,
        [int]$StaleHours
    )

    $reasons = @()

    $endpointStatus = [string]$Endpoint.status
    if ($endpointStatus -match '^(critical|broken)$') {
        $reasons += "Endpoint status is $endpointStatus"
    }

    $queuedFiles = 0
    if ($null -ne $ReplicationJob.queued_files) {
        $queuedFiles = [int]$ReplicationJob.queued_files
    }

    $lastSuccessTime = $null
    $lastSuccessAgeHours = $null

    if ($ReplicationJob.last_success_time) {
        try {
            $lastSuccessTime = [datetime]::Parse($ReplicationJob.last_success_time)
            $lastSuccessAgeHours = [math]::Round(((Get-Date) - $lastSuccessTime).TotalHours, 2)
        }
        catch {
        }
    }

    $errorCount = Get-ArrayCount $ReplicationJob.errors
    $warningCount = Get-ArrayCount $ReplicationJob.warnings

    if ($errorCount -gt 0) {
        $reasons += "Replication job has $errorCount error(s)"
    }

    if ($warningCount -gt 0) {
        $reasons += "Replication job has $warningCount warning(s)"
    }

    if ($queuedFiles -gt 0 -and $null -eq $lastSuccessTime) {
        $reasons += "Queued files present ($queuedFiles) and no last_success_time recorded"
    }

    if ($queuedFiles -gt 0 -and $null -ne $lastSuccessAgeHours -and $lastSuccessAgeHours -ge $StaleHours) {
        $reasons += "Queued files present ($queuedFiles) and last replication success is stale ($lastSuccessAgeHours hours old)"
    }

    # This can catch a weird state where queued files are piling up on a bad endpoint
    if ($queuedFiles -gt 0 -and $endpointStatus -match '^(critical|broken)$') {
        $reasons += "Queued files present ($queuedFiles) on endpoint in $endpointStatus state"
    }

    return ,$reasons
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

    $FoundIssues = $false

    foreach ($endpointKey in $Status.PSObject.Properties.Name) {
        $endpoint = $Status.$endpointKey

        if (-not $endpoint.imagemanager -or -not $endpoint.imagemanager.folders) {
            continue
        }

        $deviceIssues = @()

        foreach ($folder in $endpoint.imagemanager.folders) {
            if (-not $folder.replication_jobs) {
                continue
            }

            foreach ($repJob in $folder.replication_jobs) {
                $reasons = Test-IsReplicationIssue -Endpoint $endpoint -Folder $folder -ReplicationJob $repJob -StaleHours $ReplicationStaleHours

                if ($reasons.Count -gt 0) {
                    $FoundIssues = $true

                    $lastSuccessAgeHours = $null
                    if ($repJob.last_success_time) {
                        try {
                            $lastSuccessAgeHours = [math]::Round(((Get-Date) - ([datetime]::Parse($repJob.last_success_time))).TotalHours, 2)
                        }
                        catch {
                        }
                    }

                    $errorCount = Get-ArrayCount $repJob.errors
                    $warningCount = Get-ArrayCount $repJob.warnings

                    $deviceIssues += [PSCustomObject]@{
                        DeviceKey          = $endpointKey
                        DeviceName         = $endpoint.name
                        Org                = $endpoint.org
                        EndpointStatus     = $endpoint.status
                        LostContact        = $endpoint.lost_contact
                        FolderPath         = $folder.path
                        ReplicationJobName = $repJob.name
                        Progress           = $repJob.progress
                        QueuedFiles        = $repJob.queued_files
                        LastSuccessTime    = $repJob.last_success_time
                        LastSuccessAgeHrs  = $lastSuccessAgeHours
                        TargetLocation     = $repJob.target_location_type
                        ErrorCount         = $errorCount
                        WarningCount       = $warningCount
                        Reasons            = ($reasons -join "; ")
                    }
                }
            }
        }

        if ($deviceIssues.Count -gt 0) {
            Write-Output "============================================================"
            Write-Output "SUSPECTED REPLICATION FAILURE"
            Write-Output "============================================================"
            Write-Output ("Device Name     : {0}" -f $endpoint.name)
            Write-Output ("Org             : {0}" -f $endpoint.org)
            Write-Output ("Endpoint Status : {0}" -f $endpoint.status)
            Write-Output ("Lost Contact    : {0}" -f $endpoint.lost_contact)
            Write-Output ""

            if ($endpoint.machine_details -and $endpoint.machine_details.volumes) {
                Write-Output "Volumes:"
                $endpoint.machine_details.volumes |
                    Where-Object { $_.mountpoint } |
                    Select-Object `
                        mountpoint,
                        device,
                        @{Name="SizeGB";Expression={ Convert-ToGB $_.size }},
                        @{Name="UsedGB";Expression={ Convert-ToGB $_.used }},
                        os_vol,
                        protected |
                    Format-Table -AutoSize | Out-String | Write-Output
            }

            Write-Output "Replication Issue Details:"
            $deviceIssues |
                Select-Object `
                    FolderPath,
                    ReplicationJobName,
                    QueuedFiles,
                    LastSuccessTime,
                    LastSuccessAgeHrs,
                    TargetLocation,
                    ErrorCount,
                    WarningCount,
                    Progress,
                    Reasons |
                Format-List | Out-String | Write-Output

            if ($endpoint.shadowprotect -and $endpoint.shadowprotect.jobs) {
                $failedJobs = $endpoint.shadowprotect.jobs | Where-Object {
                    ($_.last_result -and $_.last_result -notmatch '^success$') -or
                    ($_.status -and $_.status -match 'fail|error|critical|broken')
                }

                if ($failedJobs.Count -gt 0) {
                    Write-Output "Related Failed Backup Jobs:"
                    foreach ($job in $failedJobs) {
                        Write-Output ("  Job Name      : {0}" -f $job.name)
                        Write-Output ("  Status        : {0}" -f $job.status)
                        Write-Output ("  Last Result   : {0}" -f $job.last_result)
                        Write-Output ("  Last Run      : {0}" -f $job.last_run)
                        Write-Output ("  Next Run      : {0}" -f $job.next_run)
                        Write-Output ("  Last Success  : {0}" -f $job.last_success)
                        Write-Output ("  Destination   : {0}" -f $job.destination)
                        Write-Output "  ----------------------------------------"
                    }
                }
            }

            Write-Output ""
        }
    }

    if (-not $FoundIssues) {
        Write-Output "No suspected replication failures found using the current detection rules."
        Write-Output ("Current stale threshold: {0} hour(s)" -f $ReplicationStaleHours)
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
