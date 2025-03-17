configuration CreateADPDC
{
   param
   (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30
    )

    Import-Module PSDesiredStateConfiguration

    Import-DscResource -ModuleName PSDesiredStateConfiguration

    Import-DSCResource -ModuleName @{
        ModuleName="xActiveDirectory"
        ModuleVersion="3.0.0.0"
    }
    Import-DSCResource -ModuleName @{
        ModuleName="xNetworking"
        ModuleVersion="5.7.0.0"
    }
    Import-DSCResource -ModuleName @{
        ModuleName="xPendingReboot"
        ModuleVersion="0.4.0.0"
    }

    [System.Management.Automation.PSCredential ]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    $Interface=Get-NetAdapter|Where Name -Like "Ethernet*"|Select-Object -First 1
    $InterfaceAlias=$($Interface.Name)
    $DomainDN = "DC=$($DomainName.Split(".")[0]),DC=$($DomainName.Split(".")[1])"
    $CoricComputersOU = "Coric Computers"
    $CoricUsersOU = "Coric Users"
    $CoricSecurityOU = "Coric Security"

    Node localhost
    {
        Script AddADDSFeature {
            SetScript = {
                Install-WindowsFeature "AD-Domain-Services" -IncludeManagementTools -ErrorAction SilentlyContinue
            }
            GetScript =  { @{} }
            TestScript = { $false }
        }

        WindowsFeature File-Services
        {
            Ensure = "Present"
            Name = "File-Services"
        }

        WindowsFeature FS-Resource-Manager
        {
            Ensure = "Present"
            Name = "FS-Resource-Manager"
        }

	    WindowsFeature DNS
        {
            Ensure = "Present"
            Name = "DNS"
        }

        Script script1
	    {
      	    SetScript =  {
		        Set-DnsServerDiagnostics -All $true
                Write-Verbose -Verbose "Enabling DNS client diagnostics"
            }
            GetScript =  { @{} }
            TestScript = { $false }
	        DependsOn = "[WindowsFeature]DNS"
        }

	    WindowsFeature DnsTools
	    {
	        Ensure = "Present"
            Name = "RSAT-DNS-Server"
	    }

        xDnsServerAddress DnsServerAddress
        {
            Address        = '127.0.0.1'
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = 'IPv4'
	        DependsOn = "[WindowsFeature]DNS"
        }

        WindowsFeature ADDSInstall
        {
            Ensure = "Present"
            Name = "AD-Domain-Services"
	        DependsOn="[WindowsFeature]File-Services", "[WindowsFeature]FS-Resource-Manager", "[Script]AddADDSFeature"
        }

        xADDomain FirstDS
        {
            DomainName = $DomainName
            DomainAdministratorCredential = $DomainCreds
            SafemodeAdministratorPassword = $DomainCreds
            DatabasePath = "C:\Windows\NTDS"
            LogPath = "C:\Windows\NTDS"
            SysvolPath = "C:\Windows\SYSVOL"
	        DependsOn = "[WindowsFeature]ADDSInstall"
        }

        LocalConfigurationManager
        {
            ConfigurationMode = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        xADOrganizationalUnit CoricComputers
        {
            Name = $CoricComputersOU
            Path = $DomainDN
            Ensure = "Present"
            DependsOn = "[xADDomain]FirstDS"
        }

        xADOrganizationalUnit CoricComputersAdmin
        {
            Name = "Admin"
            Path = "OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputers"
        }

        xADOrganizationalUnit CoricComputersAdminRDG
        {
            Name = "RDG"
            Path = "OU=Admin,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersAdmin"
        }

        xADOrganizationalUnit CoricComputersAdminFS
        {
            Name = "FS"
            Path = "OU=Admin,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersAdmin"
        }

        xADOrganizationalUnit CoricComputersAdminSSO
        {
            Name = "SSO"
            Path = "OU=Admin,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersAdmin"
        }

        xADOrganizationalUnit CoricComputersAdminMfa
        {
            Name      = "MFA"
            Path      = "OU=Admin,OU=$CoricComputersOU,$DomainDN"
            Ensure    = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersAdmin"
        }

        xADOrganizationalUnit CoricComputersAdminFTP
        {
            Name = "FTP"
            Path = "OU=Admin,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersAdmin"
        }

        xADOrganizationalUnit CoricComputersAdminSQL
        {
            Name = "SQL"
            Path = "OU=Admin,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersAdmin"
        }


        xADOrganizationalUnit CoricComputersEnvP
        {
            Name = "Env P"
            Path = "OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputers"
        }

        xADOrganizationalUnit CoricComputersEnvPIIS
        {
            Name = "IIS"
            Path = "OU=Env P,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvP"
        }

        xADOrganizationalUnit CoricComputersEnvPDrone
        {
            Name = "Drone"
            Path = "OU=Env P,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvP"
        }

        xADOrganizationalUnit CoricComputersEnvPDesktop
        {
            Name = "Desktop"
            Path = "OU=Env P,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvP"
        }

        xADOrganizationalUnit CoricComputersEnvPFile
        {
            Name = "File"
            Path = "OU=Env P,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvP"
        }

        xADOrganizationalUnit CoricComputersEnvPPushPull
        {
            Name = "PushPull"
            Path = "OU=Env P,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvP"
        }

        xADOrganizationalUnit CoricComputersEnvPSQL
        {
            Name = "SQL"
            Path = "OU=Env P,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvP"
        }

        xADOrganizationalUnit CoricComputersEnvPWebReporter
        {
            Name = "WebReporter"
            Path = "OU=Env P,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvP"
        }

        xADOrganizationalUnit CoricComputersEnvU
        {
            Name = "Env U"
            Path = "OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputers"
        }

        xADOrganizationalUnit CoricComputersEnvUIIS
        {
            Name = "IIS"
            Path = "OU=Env U,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvU"
        }

        xADOrganizationalUnit CoricComputersEnvUDrone
        {
            Name = "Drone"
            Path = "OU=Env U,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvU"
        }

        xADOrganizationalUnit CoricComputersEnvUDesktop
        {
            Name = "Desktop"
            Path = "OU=Env U,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvU"
        }

        xADOrganizationalUnit CoricComputersEnvUFile
        {
            Name      = 'File'
            Path      = "OU=Env U,OU=$CoricComputersOU,$DomainDN"
            Ensure    = 'Present'
            DependsOn = '[xADOrganizationalUnit]CoricComputersEnvU'
        }

        xADOrganizationalUnit CoricComputersEnvUPushPull
        {
            Name = "PushPull"
            Path = "OU=Env U,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvU"
        }

        xADOrganizationalUnit CoricComputersEnvUSQL
        {
            Name = "SQL"
            Path = "OU=Env U,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvU"
        }

        xADOrganizationalUnit CoricComputersEnvUWebReporter
        {
            Name = "WebReporter"
            Path = "OU=Env U,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvU"
        }


        xADOrganizationalUnit CoricComputersEnvD
        {
            Name = "Env D"
            Path = "OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputers"
        }

        xADOrganizationalUnit CoricComputersEnvDIIS
        {
            Name = "IIS"
            Path = "OU=Env D,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvD"
        }

        xADOrganizationalUnit CoricComputersEnvDDrone
        {
            Name = "Drone"
            Path = "OU=Env D,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvD"
        }

        xADOrganizationalUnit CoricComputersEnvDDesktop
        {
            Name = "Desktop"
            Path = "OU=Env D,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvD"
        }

        xADOrganizationalUnit CoricComputersEnvDFile
        {
            Name = "File"
            Path = "OU=Env D,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvD"
        }

        xADOrganizationalUnit CoricComputersEnvDPushPull
        {
            Name = "PushPull"
            Path = "OU=Env D,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvD"
        }

        xADOrganizationalUnit CoricComputersEnvDSQL
        {
            Name = "SQL"
            Path = "OU=Env D,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvD"
        }

        xADOrganizationalUnit CoricComputersEnvDWebReporter
        {
            Name = "WebReporter"
            Path = "OU=Env D,OU=$CoricComputersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricComputersEnvD"
        }

        xADOrganizationalUnit CoricUsers
        {
            Name = $CoricUsersOU
            Path = $DomainDN
            Ensure = "Present"
            DependsOn = "[xADDomain]FirstDS"
        }

        xADOrganizationalUnit CoricUsersDocumentWarehouseAccess
        {
            Name = "Document Warehouse Access"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

        xADOrganizationalUnit CoricUsersHostingAdmin
        {
            Name = "Hosting Admin"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

        xADOrganizationalUnit CoricUsersCoricSupport
        {
            Name = "Coric Support"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

   		xADOrganizationalUnit CoricUsersCoricPresales
        {
            Name = "Coric Presales"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

        xADOrganizationalUnit CoricUsersCoricPS
        {
            Name = "Coric PS"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

        xADOrganizationalUnit CoricUsersServiceAccounts
        {
            Name = "Service Accounts"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

        xADOrganizationalUnit CoricUsersClientPowerUser
        {
            Name = "Client Power User"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

        xADOrganizationalUnit CoricUsersClientITUser
        {
            Name = "Client IT User"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

        xADOrganizationalUnit CoricUsersClientLiteUser
        {
            Name = "Client Lite User"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

        xADOrganizationalUnit CoricUsersClientBusinessUser
        {
            Name = "Client Business User"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

		xADOrganizationalUnit CoricUsersSCDaaSAdmin
        {
            Name = "SCDaaS Admin"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

		xADOrganizationalUnit CoricUsersSCDaaSSupport
        {
            Name = "SCDaaS Support"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

   		xADOrganizationalUnit CoricUsersSimcorpUniSD
        {
            Name = "Simcorp UniSD"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

        xADOrganizationalUnit CoricUsersLeavers
        {
            Name = "Leavers"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }

        xADOrganizationalUnit CoricUsersWorkflowTeamMembers
        {
            Name = "Workflow Team Members"
            Path = "OU=$CoricUsersOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricUsers"
        }


        xADOrganizationalUnit CoricSecurity
        {
            Name = $CoricSecurityOU
            Path = $DomainDN
            Ensure = "Present"
            DependsOn = "[xADDomain]FirstDS"
        }

		xADOrganizationalUnit CoricSecurityAdmin
        {
            Name = "Admin"
            Path = "OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurity"
        }

        xADOrganizationalUnit CoricSecurityAdminApplicationAccessGroups
        {
            Name = "Application Access Groups"
            Path = "OU=Admin,OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurityAdmin"
        }

        xADOrganizationalUnit CoricSecurityAdminRdpAccessGroups
        {
            Name = "RDP Access Groups"
            Path = "OU=Admin,OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurityAdmin"
        }


        xADOrganizationalUnit CoricSecurityEnvP
        {
            Name = "Env P"
            Path = "OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurity"
        }

        xADOrganizationalUnit CoricSecurityEnvPApplicationAccessGroups
        {
            Name = "Application Access Groups"
            Path = "OU=Env P,OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurityEnvP"
        }

        xADOrganizationalUnit CoricSecurityEnvPRdpAccessGroups
        {
            Name = "RDP Access Groups"
            Path = "OU=Env P,OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurityEnvP"
        }

        xADOrganizationalUnit CoricSecurityEnvPWarehouseAccessGroups
        {
            Name = "Warehouse Access Groups"
            Path = "OU=Env P,OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurityEnvP"
        }

        xADOrganizationalUnit CoricSecurityEnvU
        {
            Name = "Env U"
            Path = "OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurity"
        }

        xADOrganizationalUnit CoricSecurityEnvUApplicationAccessGroups
        {
            Name = "Application Access Groups"
            Path = "OU=Env U,OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurityEnvU"
        }

        xADOrganizationalUnit CoricSecurityEnvURdpAccessGroups
        {
            Name = "RDP Access Groups"
            Path = "OU=Env U,OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurityEnvU"
        }

        xADOrganizationalUnit CoricSecurityEnvUWarehouseAccessGroups
        {
            Name = "Warehouse Access Groups"
            Path = "OU=Env U,OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurityEnvU"
        }

        xADOrganizationalUnit CoricSecurityEnvD
        {
            Name = "Env D"
            Path = "OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurity"
        }

        xADOrganizationalUnit CoricSecurityEnvDApplicationAccessGroups
        {
            Name = "Application Access Groups"
            Path = "OU=Env D,OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurityEnvD"
        }

        xADOrganizationalUnit CoricSecurityEnvDRdpAccessGroups
        {
            Name = "RDP Access Groups"
            Path = "OU=Env D,OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurityEnvD"
        }

        xADOrganizationalUnit CoricSecurityEnvDWarehouseAccessGroups
        {
            Name = "Warehouse Access Groups"
            Path = "OU=Env D,OU=$CoricSecurityOU,$DomainDN"
            Ensure = "Present"
            DependsOn = "[xADOrganizationalUnit]CoricSecurityEnvD"
        }
    }
}

$configData = @{
    AllNodes = @(
        @{
            NodeName = 'localhost'
            PSDscAllowPlainTextPassword = $true
        }
    )
}
