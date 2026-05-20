#$Appliance = "Appliance URL Here"
#$Token     = "API Token Here"

# Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Bypass SSL cert validation (PS 5.1 safe)
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

        $endpointStatus = $endpoint.status
        $jobs = $endpoint.shadowprotect.jobs

        # Determine if endpoint has issues
        $endpointIssue = ($endpointStatus -notmatch "ok|success")

        # Determine if any jobs have failed
        $jobIssues = @()
        if ($jobs) {
            $jobIssues = $jobs | Where-Object {
                $_.last_result -and $_.last_result -notmatch "success"
            }
        }

        if ($endpointIssue -or $jobIssues.Count -gt 0) {
            $FoundIssues = $true

            Write-Output "============================================================"
            Write-Output "🚨 ISSUE DETECTED"
            Write-Output "============================================================"

            Write-Output ("Name   : {0}" -f $endpoint.name)
            Write-Output ("Org    : {0}" -f $endpoint.org)
            Write-Output ("Status : {0}" -f $endpoint.status)
            Write-Output ""

            # Show volumes (optional but useful context)
            if ($endpoint.machine_details -and $endpoint.machine_details.volumes) {
                Write-Output "Volumes:"
                $endpoint.machine_details.volumes |
                    Where-Object { $_.mountpoint } |
                    Select-Object `
                        mountpoint,
                        device,
                        @{Name="SizeGB";Expression={ Convert-ToGB $_.size }},
                        @{Name="UsedGB";Expression={ Convert-ToGB $_.used }},
                        os_vol |
                    Format-Table -AutoSize | Out-String | Write-Output
            }

            # Show ONLY failed jobs
            if ($jobIssues.Count -gt 0) {
                Write-Output "Failed Jobs:"
                foreach ($job in $jobIssues) {
                    Write-Output ("  Job Name     : {0}" -f $job.name)
                    Write-Output ("  Status       : {0}" -f $job.status)
                    Write-Output ("  Last Result  : {0}" -f $job.last_result)
                    Write-Output ("  Last Run     : {0}" -f $job.last_run)
                    Write-Output ("  Next Run     : {0}" -f $job.next_run)
                    Write-Output ("  Destination  : {0}" -f $job.destination)

                    if ($job.schedule) {
                        foreach ($sched in $job.schedule) {
                            Write-Output ("    Schedule -> {0} | {1} | {2} | Repeats: {3}" -f `
                                $sched.frequency,
                                $sched.interval,
                                $sched.mode,
                                $sched.repeats)
                        }
                    }

                    Write-Output "  ----------------------------------------"
                }
            }
            else {
                Write-Output "⚠️ Endpoint unhealthy but no failed jobs detected"
            }

            Write-Output ""
        }
    }

    if (-not $FoundIssues) {
        Write-Output "✅ All devices reporting healthy backups"
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
