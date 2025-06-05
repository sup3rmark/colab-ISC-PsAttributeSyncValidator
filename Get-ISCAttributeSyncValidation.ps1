#Requires -Version 7.0 -Modules iscUtils,Microsoft.PowerShell.SecretStore,Microsoft.PowerShell.SecretManagement
<#
.SYNOPSIS
Output a CSV of all correlated accounts on a source, with all attribute values available for Attribute Sync and the corresponding
    Identity Attribute values for the correlated identity.

.DESCRIPTION
Retrieves all accounts on a specified source, and outputs a CSV to enable you to analyze the values for each attribute available for
    attribute sync, compared against the value of the corresponding mapped Identity Attribute.

.LINK
https://github.com/sup3rmark/colab-ISC-PsAttributeSyncValidator

.EXAMPLE
Get-ISCAttributeSyncValidation -Tenant foo -SourceName bar

.EXAMPLE
Get-ISCAttributeSyncValidation -Tenant foo -SourceID 166xxxxxxxxxxxxxxxxxxxxxxxxxx1af

.EXAMPLE
Get-ISCAttributeSyncValidation -SourceName bar

.EXAMPLE
Get-ISCAttributeSyncValidation -Tenant foo -SourceName bar -OutputDirectory $PWD
#>

[CmdletBinding()]
param(
    # The ISC tenant name (eg. https://[tenant].identitynow.com); if not specified, will try to use an existing connection from iscUtils
    [Parameter ()]
    [string] $Tenant,

    # Specify the source to check by name
    [Parameter (ParameterSetName = 'SourceName'
    )]
    [string] $SourceName,

    # Specify the source to check by ID
    [Parameter (ParameterSetName = 'SourceID'
    )]
    [string] $SourceID,

    # The directory to save the file to; if not specified, will export list to the clipboard
    [Parameter ()]
    [string] $OutputDirectory
)

#region Initial Connection
if ($Tenant) {
    Connect-ISC -Tenant $tenant
}
else {
    try {
        $null = Test-ISCConnection -ErrorAction Stop -ReconnectAutomatically
    }
    catch {
        throw 'No tenant provided. Please provide a tenant.'
    }
}
$connection = Get-ISCConnection -IncludeSources
$Tenant = $connection.Tenant
$apiUrl = $connection.'API URL'
$token = $connection.Token | ConvertTo-SecureString -AsPlainText
$sources = $connection.SourceList
Write-Verbose "Connected to $tenant tenant."

if ($SourceName) {
    $SourceID = ($sources | Where-Object { $_.name -eq $SourceName }).id
    if ($null -eq $SourceID) {
        throw 'No source found with specified name.'
    }
}
else {
    $SourceName = ($sources | Where-Object { $_.id -eq $SourceID }).name
    if ($null -eq $SourceName) {
        throw 'No source found with specified ID.'
    }
}
Write-Verbose "Source: $SourceName ($SourceID)."
#endRegion

#Get Attribute Sync Mapping
$attrMapping = (Invoke-RestMethod -Uri "$apiUrl/v2025/sources/$SourceID/attribute-sync-config" -Authentication Bearer -Token $token -Headers @{'X-SailPoint-Experimental' = 'true' }).attributes
Write-Verbose "Retrieved $SourceName attribute sync config."

#Get Source Accounts
Write-Verbose "Retrieving $SourceName accounts. This may take a bit..."
$accounts = Get-ISCAccount -List -Source $source
Write-Verbose "Retrieved $($accounts.count) accounts."

#Get Identities
Write-Verbose 'Retrieving identities. This may take a bit...'
$identities = Get-ISCIdentity -List
Write-Verbose "Retrieved $($identities.count) identities."

#Compare
$list = @()
$accounts = $accounts | Where-Object { $_.uncorrelated -eq $false -and $_.disabled -eq $false }
Write-Verbose "Comparing attributes for $($accounts.count) correlated, active accounts. This may take a bit..."
foreach ($account in $accounts) {
    $identity = $identities | Where-Object { $_.id -eq $account.identity.id }
    $row = New-Object PSObject
    foreach ($attribute in $attrMapping) {
        $row | Add-Member -Type NoteProperty -Name "$source-$($attribute.target)" -Value $account.attributes."$($attribute.target)" -Force
        $row | Add-Member -Type NoteProperty -Name "id-$($attribute.name)" -Value $identity.attributes."$($attribute.name)" -Force
        $row | Add-Member -Type NoteProperty -Name "$($attribute.target)-Mismatch" -Value ($account.attributes."$($attribute.target)" -ne $identity.attributes."$($attribute.name)")
    }
    $list += $row
    Clear-Variable row, identity
}
Write-Verbose 'Finished comparing attributes!'

$attrList = @()
foreach ($var in $($list | Get-Member | Where-Object { $_.Name -like '*-Mismatch' })) {
    $attr = New-Object PSObject
    $attr | Add-Member -Type NoteProperty -Name "$Source`Attribute" -Value ($var.name -replace ('-Mismatch', $null)) -Force
    $attr | Add-Member -Type NoteProperty -Name 'MismatchCount' -Value ($list | Where-Object { $_."$($var.name)" -eq $true }).count -Force
    $attr | Add-Member -Type NoteProperty -Name 'SyncEnabled' -Value ($attrMapping | Where-Object { $_.target -eq ($var.name -replace ('-Mismatch', $null)) }).enabled
    $attrList += $attr
}

$attrList | Sort-Object -Property @{Expression = 'SyncEnabled'; Descending = $true }, @{Expression = 'MismatchCount'; Descending = $true }

if ($OutputDirectory) {
    $filepath = "$OutputDirectory\$Tenant-$SourceName-$(Get-Date -Format yyyyMMddHHmmss).csv"
    $list | Export-Csv -Path $filepath
    Write-Host "Data sent to $filepath."
}
else {
    $list | ConvertTo-Csv -Delimiter "`t" | Set-Clipboard
    Write-Host 'Data sent to Clipboard.'
}