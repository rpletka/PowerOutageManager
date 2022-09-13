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
