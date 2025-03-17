<#PSScriptInfo
    .VERSION
        1.0.0
    .GUID
        b87cb823-6e61-466b-9175-5688089f01b1
    .DESCRIPTION
        A runbook for executing the "CreateADPDC.ps1" DSC configuration
        in an interactive PowerShell session. "Update" is in the script
        name because this script will most often be used to update AD on an
        existing DC. It's not used to create AD initially (the "CreateADPDC.ps1"
        DSC configuration is called automatically by the Azure DSC VM Extension
        during the initial DC/AD configuration).
    .AUTHOR
        BNRS
    .COMPANYNAME
        SimCorp Coric
    .COPYRIGHT
    .TAGS
        Private
    .LICENSEURI
    .PROJECTURI
    .ICONURI
    .EXTERNALMODULEDEPENDENCIES
    .REQUIREDSCRIPTS
    .EXTERNALSCRIPTDEPENDENCIES
    .RELEASENOTES
    .PRIVATEDATA
#>
<#
.SYNOPSIS
    Managed Services runbook for updating AD on a client PDC.
.DESCRIPTION
    A runbook for executing the "CreateADPDC.ps1" DSC configuration
    in an interactive PowerShell session. "Update" is in the script
    name because this script will most often be used to update AD on an
    existing DC. It's not used to create AD initially (the "CreateADPDC.ps1"
    DSC configuration is called automatically by the Azure DSC VM Extension
    during the initial DC/AD configuration).
.EXAMPLE
    .\UpdateADPDC.ps1
#>
#Requires -Version '5.1'
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $True)]
param()

if ($ENV:COMPUTERNAME.Substring(8, 2).ToLower() -ne 'dc')
{
    Write-Warning 'This is a domain controller script but the server does not appear to be a domain controller. Aborting...'
    exit
}

# The 'C:\ScriptLibrary\CreateADPDC.ps1' directory must exist
# And also contain the file 'CreateADPDC.ps1'
$dscConfigName = 'CreateADPDC'

$dscConfigDir = "C:\ScriptLibrary\{0}.ps1" -f $dscConfigName
$dscConfigFilePath = "{0}\{1}.ps1" -f $dscConfigDir, $dscConfigName

if (-not (Test-Path -Path $dscConfigDir -PathType Container))
{
    Write-Warning ("Directory '{0}' not present. Aborting..." -f $dscConfigDir)
    exit
}

if (-not (Test-Path -Path $dscConfigFilePath -PathType Leaf))
{
    Write-Warning ("DSC Config File '{0}' not present. Aborting..." -f $dscConfigFilePath)
    exit
}

if (-not (Get-PackageProvider | where Name -eq 'NuGet'))
{
    Write-Verbose 'Bootstrapping NuGet package provider...'

    $null = Get-PackageProvider -Name NuGet -ForceBootstrap
}

$psRepos = Get-PSRepository -WarningAction Ignore -ErrorAction Ignore

if (-not $psRepos)
{
    Write-Verbose '  * Default PSGallery not registered. Attempting to Register...'

    Register-PSRepository -Default
}

$psgalleryRepo = $psRepos | where Name -eq 'PSGallery'

if ($psgalleryRepo -and $psgalleryRepo.InstallationPolicy -ne 'Trusted')
{
    Write-Verbose '  * PSGallery is Untrusted. Attempting to Trust...'

    Set-PSRepository -Name 'PSGallery' -InstallationPolicy 'Trusted'

    if ((Get-PSRepository -Name 'PSGallery' -WarningAction Ignore -ErrorAction Ignore).InstallationPolicy -ne 'Trusted')
    {
        Write-Warning '    Trust failed. Check firewall and/or URL Filtering settings.'
    }
}

# Check required module versions and install them from the PSGallery Repository if they do not exist
$requiredModuleNames = @('xActiveDirectory', 'xNetworking', 'xPendingReboot')

foreach ($requiredModuleName in $requiredModuleNames)
{
    Write-Verbose ("Checking module '{0}'..." -f $requiredModuleName)

    $installRequiredVersion = $true

    $requiredModuleFolderPath = Join-Path -Path $dscConfigDir -ChildPath $requiredModuleName

    if (-not (Test-Path -Path $requiredModuleFolderPath -PathType Container))
    {
        Write-Warning ("Module subfolder '{0}' not present. Aborting..." -f $requiredModuleFolderPath)
        continue
    }

    $subModuleVersion = Get-Module -ListAvailable -Name $requiredModuleFolderPath | foreach { $_.version.ToString() }

    if ($subModuleVersion -and $subModuleVersion -ne '0.0')
    {
        $installedModuleVersions = Get-Module -ListAvailable -Name $requiredModuleName | foreach { $_.version.ToString() }

        if ($installedModuleVersions -contains $subModuleVersion) { $installRequiredVersion = $false }
    }

    if ($installRequiredVersion)
    {
        Write-Verbose ("The required version of module '{0}' needs to be installed from the PSGallery repository..." -f $requiredModuleName)
        Install-Module -Name $requiredModuleName -Repository 'PSGallery' -RequiredVersion $subModuleVersion -Force -AllowClobber -SkipPublisherCheck -Scope:AllUsers
    }
    else
    {
        Write-Verbose ("The required version of module '{0}' is already installed." -f $requiredModuleName)
    }
}

$domain = ($ENV:COMPUTERNAME -split '-')[0] + '.Hosted'

Import-Module $dscConfigFilePath
. $dscConfigFilePath

if (-not $cred) { $cred = Get-Credential -Message 'Enter Domain Admin credential and password' }

# Compiles DSC configuration into a .mof file in a newly created directory with the same name as the DSC config
CreateADPDC -DomainName $domain -AdminCreds $cred -ConfigurationData $configData -WarningAction Ignore

Start-DscConfiguration -Path $dscConfigName -Wait -Force -Verbose
