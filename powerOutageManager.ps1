<#
This script will monitor an array of non-UPS devices to identify a power outage if all of the monitored devices fail.
Once a power failure is detected the script will tag the powered on VMs and gracefully shutdown any vms with tools and
stop any VMs without tools.  Finally it will gracefully shutdown the core infrastructure VMs identified in a specifed 
Core VM DRS group.  This group should be setup to have afinity that the core vms should be running on a specific host.
The host should be set to power on following power interruption.  The host should have autostart configured for the 
core VMs including the VM that runs this script.  Once the scripting VM and vcenter are restarted the script will power
back on any VMs that were taged before shutdown.  Future releases may further automate the DRS rules and esxi autostart
configuration.
#>

#TODO: setup vm group and host group 
#TODO: setup afinity rule in code
#TODO: setup autostart order of critical vms on target host

function Get-TimeStamp {
    
    return "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
    
}

$domainName = "far-away.galaxy"
$vCenterFQDN = "vcva." + $domainName
$NonUPSDevicesToCheck = @("192.168.1.11", "192.168.1.75", "192.168.2.65")
$CoreVMGroupName = "Critical VMs"
$SecondsToWaitForShutdown = 90
$vCenterRetries=10
$AllDevicesUpLogFrequency=15 #Minutes

$credential = Get-Secret -name vCenterCreds
$maxTries=$vCenterRetries
while ($maxTries -gt 0) {
    $Error.Clear()
    $vCenterConnection = connect-viserver -Server $vCenterFQDN -Credential $credential -ErrorAction SilentlyContinue
    if ($Error.Count -eq 0) {
        break;
    } else {
        Write-Host $Error
        start-sleep -Seconds 60
        $MaxTries--
    }
}
if ($null -eq $vCenterConnection) {
    Write-Host "$(Get-TimeStamp) Unable to reach $vCenterFQDN after $vCenterRetries Tries. Terminating script."
    Exit
} else {
    $Message='Successfull connection to {0} after {1} retries.' -f  $vCenterFQDN, ($vCenterRetries - $maxTries).ToString()
    Write-Host "$(Get-TimeStamp) $Message "
}

#If DesiredPowerState Tag Category doesn't exist then create it
$TagCategoryName = "DesiredPowerState"
Try {
    $VMTagCat = Get-TagCategory -Name  $TagCategoryName -ErrorAction Stop
    Write-Host "$(Get-TimeStamp) TagCategory $TagCategoryName found, skipping creation."
}
Catch {
    $VMTagCat = New-TagCategory -Name $TagCategoryName -Description "Desired VM Powerstate after a graceful shutdown and cold datacenter startup."
}
#If PoweredOn VM Tag doesn't exist then create it
$TagName = "PoweredOn"
Try {
    $PoweredOnTag = Get-Tag -Name  $TagName -ErrorAction Stop
    Write-Host "$(Get-TimeStamp) Tag $TagName found, skipping creation"
}
Catch {
    $PoweredOnTag = New-Tag -Name $TagName -Description "PoweredOn signifies that this VM should be powered-on after a graceful shutdown and cold datacenter startup." -Category $TagCategoryName
}

#Check to see if we've recovered from a power outage
$VMsToPowerON=Get-TagAssignment -Tag "PoweredOn"|Select -ExpandProperty Entity 
if ($null -eq $VMsToPowerON) {Write-Host "$(Get-TimeStamp) No VMs found to PowerOn (Not in a recovery)." }
Foreach ($VM in $VMsToPowerON) {
    Write-Host "$(Get-TimeStamp) Powering on $VM "
    Start-VM $VM -Confirm:$False -ErrorAction SilentlyContinue
}

#Check array of non-UPS devices.  If all of them are down for 4 successive pings (3 devices with 4 pings each with a 5 second timeout will require 60 seconds of downtime before triggering shutdown)
$DevicesDown=0
$start_time=(Get-Date).AddMinutes(-1 * $AllDevicesUpLogFrequency) #Force first successful log
while ($DevicesDown -ne $NonUPSDevicesToCheck.Count) {
    $NonUPSDeviceResults=Test-Connection -Quiet -TimeoutSeconds 5 -Count 4 -TargetName $NonUPSDevicesToCheck -ErrorAction SilentlyContinue
    #Device will only be marked down if all pings fail for a given test
    $DevicesDown=$NonUPSDeviceResults | group |where {$_.Name -eq $False} |select-object -ExpandProperty Count 
    if ($null -eq $DevicesDown) {$DevicesDown=0}
    $DevicesUp=$NonUPSDevicesToCheck.Count - $DevicesDown
    if ($DevicesDown -gt 0) {
        Write-Host "$(Get-TimeStamp) There were $DevicesUp non-UPS powered devices up and $DevicesDown devices Down."
        $start_time=Get-Date
    } else {
        if (((Get-Date)-$start_time).TotalMinutes -gt $AllDevicesUpLogFrequency) {
            Write-Host "$(Get-TimeStamp) There were $DevicesUp non-UPS powered devices up and $DevicesDown devices Down. Successfull messages will be supressed for $AllDevicesUpLogFrequency minutes. "
            $start_time=Get-Date
        }
        Start-Sleep -Seconds 15
    } 
}
Write-Host "$(Get-TimeStamp) Power failure detected!"
 
$CoreVMsList=Get-DrsClusterGroup -Type "VMGroup" -Name $CoreVMGroupName|Select Member 
$PoweredOnVMs=get-vm|Where {($_.PowerState -eq "PoweredOn") -and ($_.Name -notin $CoreVMsList.Member.Name) }
$CoreVMs=get-vm|Where {($_.PowerState -eq "PoweredOn") -and ($_.Name -in $CoreVMsList.Member.Name) }

#Clear out tags from previous assignment
Get-TagAssignment -Tag "PoweredOn"|remove-tagassignment -Confirm:$False

$start_time=Get-Date
#Mark all the currently powered on VMs with VMware tools as PoweredOn then Shutdown Guest
$PoweredOnVMs=get-vm|Where {($_.PowerState -eq "PoweredOn") -and ($_.ExtensionData.Guest.ToolsStatus -ne "toolsNotRunning") -and ($_.Name -notin $CoreVMsList.Member.Name) }
Foreach ($VM in $PoweredOnVMs) {
    $VM | New-TagAssignment -Tag $PoweredOnTag -ErrorAction SilentlyContinue
    Write-Host "$(Get-TimeStamp) Shutting down $VM "
    Stop-VMGuest $VM -Confirm:$False
}

#Mark all the currently powered on VMs with VMware tools as PoweredOn then Power Off
$PoweredOnVMs=get-vm|Where {($_.PowerState -eq "PoweredOn") -and ($_.ExtensionData.Guest.ToolsStatus -eq "toolsNotRunning") -and ($_.Name -notin $CoreVMsList.Member.Name) }
Foreach ($VM in $PoweredOnVMs) {
    $VM | New-TagAssignment -Tag $PoweredOnTag -ErrorAction SilentlyContinue
    Write-Host "$(Get-TimeStamp) Stopping $VM "
    Stop-VM $VM -Confirm:$False
}

Write-Host "$(Get-TimeStamp) Waiting $SecondsToWaitForShutdown for shutdowns to complete."
#Wait $SecondsToWaitForShutdown seconds for guest shutdowns then stop any remaining vms
$elapsed_time=0
while ($elapsed_time.TotalSeconds -lt $SecondsToWaitForShutdown){
    $end_time = Get-Date
    $elapsed_time = $end_time - $start_time
    start-sleep 5
}

#Mark all the currently powered on VMs with VMware tools as PoweredOn then stop any remaining VMs
$PoweredOnVMs=get-vm|Where {($_.PowerState -eq "PoweredOn") -and ($_.Name -notin $CoreVMsList.Member.Name) }
Foreach ($VM in $PoweredOnVMs) {
    $VM | New-TagAssignment -Tag $PoweredOnTag -ErrorAction SilentlyContinue
    Write-Host "$(Get-TimeStamp) Stopping $VM "
    Stop-VMGuest $VM -Confirm:$False
}

Foreach ($CoreVM in $CoreVMs) {
    Write-Host "$(Get-TimeStamp) Shutting down $CoreVM "
    Stop-VMGuest $CoreVM -RunAsync -Confirm:$False

}
