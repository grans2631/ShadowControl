(new-object Net.WebClient).DownloadString('https://bit.ly/LTPoSh') | iex

Install-Module PoshRSJob -Repository PSGallery

Install-Module AutomateAPI -Repository PSGallery

Import-Module AutomateAPI


Connect-AutomateAPI
#remember to use your CWA USERNAME AND PASSWORD

Connect-ControlAPI
#remember to create a user in ScreenConnect (no MFA)

Get-AutomateComputer -Online $False | Compare-AutomateControlStatus | ft clientname,computername,RemoteAgentLastContact,LastConnectedControl
Get-AutomateComputer -Online $False | Compare-AutomateControlStatus | ft clientname,computername,RemoteAgentVersion, RemoteAgentLastContact,RemoteAgentLastInventory, LastStartup, LastConnectedControl

(Get-AutomateComputer -Online $False | Compare-AutomateControlStatus).count

Get-AutomateComputer -Online $False | Compare-AutomateControlStatus

 #These don't always work: (repair commands)
Get-AutomateComputer -Online $False | Compare-AutomateControlStatus | Repair-AutomateAgent -Action Check
Get-AutomateComputer -ComputerName "360-LT068" | Compare-AutomateControlStatus | Repair-AutomateAgent -Action Reinstall
Get-AutomateComputer -ComputerName "360-LT068" | Compare-AutomateControlStatus | Repair-AutomateAgent -Action Update
Get-AutomateComputer -ComputerName "360-LT068" | Compare-AutomateControlStatus | Repair-AutomateAgent -Action Check
Get-AutomateComputer -ComputerName "360-LT068" | Compare-AutomateControlStatus | Repair-AutomateAgent -Action Restart

#Get computers with inventory older than 30 days
$days = 30
Get-AutomateComputer |
  Where-Object { $_.LastInventory -lt (Get-Date).AddDays(-$days) } |
  Select-Object ClientName, ComputerName, @{N='LastInventory'; E={$_.LastInventory.ToLocalTime()}}


Get-Command -Module AutomateAPI


#Gets a list of computers offline in Automate and provides RemoteAgentLastContact Date
Get-AutomateComputer -Online $false |
    Compare-AutomateControlStatus |
    Format-Table ClientName, ComputerName, RemoteAgentLastContact


Get-ControlSessions


# Pull all computer records
$computers = Get-AutomateComputer

# Filter machines where the last Windows Update is older than 7 days
$stale = $computers | Where-Object {
    $_.WindowsUpdateDate -and 
    ([datetime]$_.WindowsUpdateDate) -lt (Get-Date).AddDays(-60)
}

# Display selected properties in a clean table, extracting ClientName.Name
$stale | Select-Object `
    @{Name='Client'; Expression={ $_.ClientName.Name }},
    ComputerName,
    OperatingSystemVersion,
    WindowsUpdateDate,
    RemoteAgentLastContact |
    Sort-Object Client, ComputerName |
    Format-Table -AutoSize



# Set threshold in days
$thresholdDays = 60

# Pull all computer records
$computers = Get-AutomateComputer

# Filter machines where the last Windows Update is older than threshold
$stale = $computers | Where-Object {
    $_.WindowsUpdateDate -and 
    ([datetime]$_.WindowsUpdateDate) -lt (Get-Date).AddDays(-$thresholdDays)
}

# Output just the count
Write-Host "Devices with no Windows Update in the last $thresholdDays days: $($stale.Count)"



# Pull all computer records
$computers = Get-AutomateComputer




# Filter machines: only servers AND Windows Update older than 60 days
$staleServers = $computers | Where-Object {
    $_.WindowsUpdateDate -and 
    ([datetime]$_.WindowsUpdateDate) -lt (Get-Date).AddDays(-60) -and
    $_.Type -match 'server'
}

# Display selected properties in a clean table, extracting ClientName.Name
$staleServers | Select-Object `
    @{Name='Client'; Expression={ $_.ClientName.Name }},
    ComputerName,
    OperatingSystemVersion,
    WindowsUpdateDate,
    Type,
    RemoteAgentLastContact |
    Sort-Object ClientName, ComputerName |
    Format-Table -AutoSize


# Filter machines: only servers AND Windows Update older than 60 days
$staleServers = $computers | Where-Object {
    $_.WindowsUpdateDate -and 
    ([datetime]$_.WindowsUpdateDate) -lt (Get-Date).AddDays(-60) -and
    $_.Type -match 'workstation'
}

# Display selected properties in a clean table, extracting ClientName.Name
$staleServers | Select-Object `
    @{Name='Client'; Expression={ $_.ClientName.Name }},
    ComputerName,
    OperatingSystemVersion,
    WindowsUpdateDate,
    RemoteAgentVersion,
    Type,
    RemoteAgentLastContact |
    Sort-Object ClientName, ComputerName |
    Format-Table -AutoSize







# Pull all computer records
$computers = Get-AutomateComputer

# Filter: only machines where both WindowsUpdateDate AND RemoteAgentLastContact are older than 30 days
$staleSystems = $computers | Where-Object {
    $_.WindowsUpdateDate -and
    $_.RemoteAgentLastContact -and
    ([datetime]$_.WindowsUpdateDate) -lt (Get-Date).AddDays(-60) -and
    ([datetime]$_.RemoteAgentLastContact) -lt (Get-Date).AddDays(-60)
}

# Display selected properties in a clean table
$staleSystems | Select-Object `
    @{Name='Client'; Expression={ $_.ClientName.Name }},
    ComputerName,
    OperatingSystemVersion,
    WindowsUpdateDate,
    RemoteAgentVersion,
    Type,
    RemoteAgentLastContact |
    Sort-Object Client, ComputerName |
    Format-Table -AutoSize








# Pull all computer records
$computers = Get-AutomateComputer

# Filter: machines that checked in within the last 7 days AND have not had a Windows update in 30+ days
$filtered = $computers | Where-Object {
    $_.WindowsUpdateDate -and
    $_.RemoteAgentLastContact -and
    ([datetime]$_.RemoteAgentLastContact) -ge (Get-Date).AddDays(-7) -and
    ([datetime]$_.WindowsUpdateDate) -lt (Get-Date).AddDays(-90)
}

# Display selected properties in a clean table
$filtered | Select-Object `
    @{Name='Client'; Expression={ $_.ClientName.Name }},
    ComputerName,
    OperatingSystemVersion,
    WindowsUpdateDate,
    RemoteAgentVersion,
    Type,
    RemoteAgentLastContact |
    Sort-Object Client, ComputerName |
    Format-Table -AutoSize








# Get all computers from Automate
$computers = Get-AutomateComputer

# Find duplicates by computer name
$duplicates = $computers |
    Group-Object -Property ComputerName |
    Where-Object { $_.Count -gt 1 } |
    Select-Object -ExpandProperty Group

# Display relevant fields
$duplicates | Select-Object `
    @{Name='Client'; Expression={ $_.ClientName.Name }},
    ComputerName,
    ComputerID,
    RemoteAgentLastContact,
    RemoteAgentVersion,
    OperatingSystemVersion |
    Sort-Object ComputerName |
    Format-Table -AutoSize






# Get all sessions (machines) from Control
$sessions = Get-ControlSession

# Find duplicates by machine name
$duplicates = $sessions |
    Group-Object -Property Name |
    Where-Object { $_.Count -gt 1 } |
    Select-Object -ExpandProperty Group

# Display relevant fields
$duplicates | Select-Object `
    SessionID 





#!ps
#timeout=900000
#maxlength=9000000
Invoke-Expression(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/Braingears/PowerShell/master/Automate-Module.psm1')
Install-Automate -Server 'lt.360smartnet.com' -LocationID 1326 -Token '2df3aa5dc5206e83bbb73f714d0d99bc' -Transcript
 
Confirmed the agent was using the correct version.
ComputerName  : TOKN-SVDC1
ServerAddress : https://lt.360smartnet.com
ComputerID    : 22529
ClientID      : 251
LocationID    : 990
Version       : 250.249
