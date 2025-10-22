[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SqlCollation
)

$ErrorActionPreference = 'Stop'

Write-Verbose "Requested SQL Server collation: $SqlCollation" -Verbose

function Wait-ForCondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [int]$TimeoutMinutes = 45,
        [int]$DelaySeconds = 15
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $result = $null
    while (-not ($result = & $Condition)) {
        if ((Get-Date) -ge $deadline) {
            throw "Timed out waiting for $Description after $TimeoutMinutes minutes."
        }

        Write-Host "Waiting for $Description..."
        Start-Sleep -Seconds $DelaySeconds
    }

    return $result
}

# Discover the instance ID for the default instance
$instanceKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
Wait-ForCondition -Condition { Test-Path $instanceKey } -Description "SQL Server instance registry key at $instanceKey"

$instanceName = Wait-ForCondition -Condition {
        if (Test-Path $instanceKey) {
            $name = (Get-ItemProperty -Path $instanceKey -ErrorAction SilentlyContinue).MSSQLSERVER
            if ($name) {
                return $name
            }
        }

        $false
    } -Description 'default SQL Server instance name'

$serverKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceName\MSSQLServer"
Wait-ForCondition -Condition { Test-Path $serverKey } -Description "SQL Server configuration registry key at $serverKey"

$currentCollation = (Get-ItemProperty -Path $serverKey -Name Collation).Collation
Write-Verbose "Current SQL Server collation: $currentCollation" -Verbose

if ($currentCollation -eq $SqlCollation) {
    Write-Host "SQL Server is already using the $SqlCollation collation."
    return
}

# Determine the SQL Server setup executable path
$knownSetupFolders = @(
    Join-Path $env:SystemDrive 'SQLServerFull',
    Join-Path $env:SystemDrive 'SQLServer2019Full',
    Join-Path $env:SystemDrive 'SQLServer2022Full'
) | Where-Object { Test-Path $_ }

$setupPath = $null
foreach ($folder in $knownSetupFolders) {
    $candidate = Join-Path $folder 'setup.exe'
    if (Test-Path $candidate) {
        $setupPath = $candidate
        break
    }
}

if (-not $setupPath) {
    # Fall back to searching within the system drive for setup.exe inside SQLServer* directories
    $searchRoots = Get-ChildItem -Directory -Path $env:SystemDrive -Filter 'SQLServer*' -ErrorAction SilentlyContinue
    foreach ($root in $searchRoots) {
        $candidate = Get-ChildItem -Path $root.FullName -Filter 'setup.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($candidate) {
            $setupPath = $candidate.FullName
            break
        }
    }
}

if (-not $setupPath) {
    throw 'Unable to locate setup.exe for SQL Server. Cannot rebuild system databases to change the collation.'
}

Write-Host "Rebuilding SQL Server system databases with collation $SqlCollation using setup at $setupPath."

# Ensure the SQL Server service is stopped before rebuilding
$serviceName = 'MSSQLSERVER'
$null = Wait-ForCondition -Condition { Get-Service -Name $serviceName -ErrorAction SilentlyContinue } -Description "SQL Server service $serviceName"
if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    if ((Get-Service -Name $serviceName).Status -ne 'Stopped') {
        Stop-Service -Name $serviceName -Force -ErrorAction Stop
        (Get-Service -Name $serviceName).WaitForStatus('Stopped', [TimeSpan]::FromMinutes(5))
    }
}

$arguments = @(
    '/QUIET',
    '/ACTION=REBUILDDATABASE',
    '/INSTANCENAME=MSSQLSERVER',
    "/SQLCOLLATION=$SqlCollation",
    '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"'
) -join ' '

$process = Start-Process -FilePath $setupPath -ArgumentList $arguments -PassThru -Wait -NoNewWindow

if ($process.ExitCode -ne 0) {
    throw "SQL Server setup returned exit code $($process.ExitCode) while rebuilding the system databases."
}

# Start the service after rebuild
if ($svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    if ($svc.Status -ne 'Running') {
        Start-Service -Name $serviceName
        $svc.WaitForStatus('Running', [TimeSpan]::FromMinutes(5))
    } else {
        Write-Host "SQL Server service $serviceName is already running after rebuild."
    }
}

Write-Host "SQL Server collation successfully updated to $SqlCollation."