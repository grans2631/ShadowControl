#$Appliance = "Appliance URL Here"
#$Token     = "API Token Here"

# Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Bypass SSL cert validation for internal appliance use
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
    param(
        [Parameter(Mandatory = $false)]
        [double]$Value
    )

    if ($null -eq $Value) { return $null }

    # API values appear to be MB, convert MB to GB
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

    $Results = foreach ($endpointKey in $Status.PSObject.Properties.Name) {
        $endpoint = $Status.$endpointKey

        # Filter device status = ok
        if ($null -eq $endpoint.status -or $endpoint.status.ToString().Trim().ToLower() -ne "ok") {
            continue
        }

        # Skip if no jobs exist
        if (-not $endpoint.shadowprotect -or -not $endpoint.shadowprotect.jobs) {
            continue
        }

        foreach ($job in $endpoint.shadowprotect.jobs) {
            # Filter job last_result = success
            if ($null -eq $job.last_result -or $job.last_result.ToString().Trim().ToLower() -ne "success") {
                continue
            }

            # Flatten schedule into a readable string
            $ScheduleText = $null
            if ($job.schedule) {
                $ScheduleText = ($job.schedule | ForEach-Object {
                    "Interval=$($_.interval); Frequency=$($_.frequency); Mode=$($_.mode); Repeats=$($_.repeats)"
                }) -join " | "
            }

            # Flatten volume info into a readable string
            $VolumeText = $null
            if ($endpoint.machine_details -and $endpoint.machine_details.volumes) {
                $VolumeText = ($endpoint.machine_details.volumes | ForEach-Object {
                    "{0} ({1}) SizeGB={2} UsedGB={3} OS_Vol={4}" -f `
                        $_.mountpoint,
                        $_.device,
                        (Convert-ToGB $_.size),
                        (Convert-ToGB $_.used),
                        $_.os_vol
                }) -join " | "
            }

            [PSCustomObject]@{
                DeviceName        = $endpoint.name
                Organization      = $endpoint.org
                SystemStatus      = $endpoint.status
                RAM_MB            = if ($endpoint.machine_details) { $endpoint.machine_details.ram } else { $null }
                LastBoot          = if ($endpoint.machine_details) { $endpoint.machine_details.last_boot } else { $null }
                Volumes           = $VolumeText

                JobName           = $job.name
                JobStatus         = $job.status
                LastResult        = $job.last_result
                LastRun           = $job.last_run
                LastSuccess       = $job.last_success
                LastMode          = $job.last_mode
                NextRun           = $job.next_run
                Destination       = $job.destination
                Schedule          = $ScheduleText
            }
        }
    }

    if (-not $Results) {
        Write-Output "No devices with System Summary Status 'ok' and jobs with Last Result 'Success' were found."
        exit 0
    }

    Write-Output ""
    Write-Output "Filtered ShadowControl Results"
    Write-Output "============================================================"
    $Results | Sort-Object DeviceName, JobName | Format-Table -AutoSize

    # Optional CSV export
    $CsvPath = "C:\Temp\ShadowControl_OK_Success_Jobs.csv"
    $Results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Output ""
    Write-Output "CSV exported to: $CsvPath"
}
catch {
    Write-Output "API call failed."
    Write-Output ("Message: {0}" -f $_.Exception.Message)

    if ($_.Exception.InnerException) {
        Write-Output ("Inner: {0}" -f $_.Exception.InnerException.Message)
    }

    exit 1
}
