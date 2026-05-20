param(
    [string]$Appliance = "Appliance URL Here",
    [string]$Token      = "ApplianceAPITokenHere",
    [string]$DeviceName = "DeviceNameHere"
)

# Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Bypass SSL cert validation (PS 5.1 / Automate safe)
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

    # Find device by name
    $endpointKey = $null
    $endpoint    = $null

    foreach ($key in $Status.PSObject.Properties.Name) {
        if ($Status.$key.name -eq $DeviceName) {
            $endpointKey = $key
            $endpoint    = $Status.$key
            break
        }
    }

    if (-not $endpoint) {
        Write-Output "Device not found: $DeviceName"
        exit 1
    }

    # =========================
    # RAW FULL OUTPUT (IMPORTANT)
    # =========================
    Write-Section "FULL RAW OBJECT (EXPANDED)"

    # This is your BEST debugging view
    $endpoint | Format-List * -Force | Out-String | Write-Output

    # =========================
    # MACHINE DETAILS
    # =========================
    if ($endpoint.machine_details) {
        Write-Section "MACHINE DETAILS"
        $endpoint.machine_details | Format-List * -Force | Out-String | Write-Output
    }

    # =========================
    # VOLUMES
    # =========================
    if ($endpoint.machine_details -and $endpoint.machine_details.volumes) {
        Write-Section "VOLUMES"

        $endpoint.machine_details.volumes |
            Format-List * -Force |
            Out-String |
            Write-Output
    }

    # =========================
    # SHADOWPROTECT
    # =========================
    if ($endpoint.shadowprotect) {
        Write-Section "SHADOWPROTECT (FULL)"

        $endpoint.shadowprotect | Format-List * -Force | Out-String | Write-Output

        if ($endpoint.shadowprotect.jobs) {
            Write-Section "SHADOWPROTECT JOBS"

            foreach ($job in $endpoint.shadowprotect.jobs) {
                $job | Format-List * -Force | Out-String | Write-Output
                Write-Output "------------------------------------------------------------"
            }
        }

        if ($endpoint.shadowprotect.version) {
            Write-Section "SHADOWPROTECT VERSION"
            $endpoint.shadowprotect.version | Format-List * -Force | Out-String | Write-Output
        }
    }

    # =========================
    # IMAGEMANAGER
    # =========================
    if ($endpoint.imagemanager) {
        Write-Section "IMAGEMANAGER (FULL)"

        $endpoint.imagemanager | Format-List * -Force | Out-String | Write-Output

        if ($endpoint.imagemanager.folders -and $endpoint.imagemanager.folders.Count -gt 0) {
            Write-Section "IMAGEMANAGER FOLDERS"

            foreach ($folder in $endpoint.imagemanager.folders) {
                $folder | Format-List * -Force | Out-String | Write-Output
                Write-Output "------------------------------------------------------------"
            }
        }
        else {
            Write-Output "No ImageManager folder data found."
        }
    }

    # =========================
    # DONE
    # =========================
    Write-Output ""
    Write-Output "✅ Completed data pull for device: $DeviceName"

}
catch {
    Write-Output "API call failed."
    Write-Output ("Message: {0}" -f $_.Exception.Message)

    if ($_.Exception.InnerException) {
        Write-Output ("Inner: {0}" -f $_.Exception.InnerException.Message)
    }

    exit 1
}
