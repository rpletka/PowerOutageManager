<# Onetime setup commands

Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope Process -ErrorAction SilentlyContinue
Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted 
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore
Install-Module -Name VMware.PowerCLI -Scope CurrentUser
Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false

Set-SecretStoreConfiguration -Authentication None -Confirm:$false
#If LocalVault doesn't exist create Local Vault
$Vault=Get-SecretVault LocalStore -ErrorAction SilentlyContinue
if ( $Vault.IsDefault ) {
    Write-Host "LocalStore Vault exists.  Skipping..."
} else {
    Write-Host "Creating LocalStore Vault"
    Register-SecretVault -Name LocalStore -ModuleName Microsoft.PowerShell.SecretStore  -DefaultVault
}
Get-Credential -username administrator@vsphere.local | set-secret -name vCenterCreds

#>

function Get-TimeStamp {
    
    return "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
    
}
#TODO: setup vm host group
#TODO: setup afinity rule in code
#TODO: setup restat order on target host

$domainName = "far-away.galaxy"
$vCenterFQDN = "vcva." + $domainName
$NonUPSDevicesToCheck = @("192.168.1.11", "192.168.1.75", "192.168.2.65")
$CoreVMGroupName = "Critical VMs"
$SecondsToWaitForShutdown = 90

$credential = Get-Secret -name vCenterCreds
$vCenterConnection = connect-viserver -Server $vCenterFQDN -Credential $credential

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

#Check array of non-ups devices.  If all of them are down for 4 successive pings (3 devices with 4 pings each with a 5 second timeout will require 60 seconds of downtime before triggering shutdown)
$DevicesDown=0
while ($DevicesDown -ne $NonUPSDevicesToCheck.Count) {
    
    $NonUPSDeviceResults=Test-Connection -Quiet -TimeoutSeconds 5 -Count 4 -TargetName $NonUPSDevicesToCheck -ErrorAction SilentlyContinue
    $DevicesDown=$NonUPSDeviceResults | group |where {$_.Name -eq $False} |select-object -ExpandProperty Count 
    if ($null -eq $DevicesDown) {$DevicesDown=0}
    $DevicesUp=$NonUPSDevicesToCheck.Count - $DevicesDown
    Write-Host "$(Get-TimeStamp) There was $DevicesUp devices up and $DevicesDown devices Down."
}
Write-Host "$(Get-TimeStamp) Power failure detected!"
 
$CoreVMsList=Get-DrsClusterGroup -Type "VMGroup" -Name $CoreVMGroupName|Select Member 
$PoweredOnVMs=get-vm|Where {($_.PowerState -eq "PoweredOn") -and ($_.Name -notin $CoreVMsList.Member.Name) }
$CoreVMs=get-vm|Where {($_.PowerState -eq "PoweredOn") -and ($_.Name -in $CoreVMsList.Member.Name) }

#Clear out tags from previous assignment
Get-TagAssignment -Tag "PoweredOn"|remove-tagassignment -Confirm:$False

$start_time=Get-Datejkk
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