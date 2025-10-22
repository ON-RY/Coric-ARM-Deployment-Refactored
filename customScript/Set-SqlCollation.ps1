[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SqlCollation
)

$ErrorActionPreference = 'Stop'

# --- Logging to help CSE troubleshooting
$logRoot = 'C:\WindowsAzure\Logs\CustomScript'
$newLog  = Join-Path $logRoot ("Set-SqlCollation_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
try { Start-Transcript -Path $newLog -Force -ErrorAction SilentlyContinue } catch {}

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

# --- Registry discovery for default instance
$instanceKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
Wait-ForCondition -Condition { Test-Path -LiteralPath $instanceKey } -Description "SQL Server instance registry key at $instanceKey"

$instanceName = Wait-ForCondition -Condition {
    if (Test-Path -LiteralPath $instanceKey) {
        $val = (Get-ItemProperty -Path $instanceKey -ErrorAction SilentlyContinue).MSSQLSERVER
        if ($val) { return $val }
    }
    $false
} -Description 'default SQL Server instance name'

$serverKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceName\MSSQLServer"
Wait-ForCondition -Condition { Test-Path -LiteralPath $serverKey } -Description "SQL Server configuration registry key at $serverKey"

$currentCollation = $null
try {
    $serverConfig = Get-ItemProperty -Path $serverKey -ErrorAction Stop
    if ($serverConfig.PSObject.Properties.Match('Collation').Count -gt 0) {
        $currentCollation = [string]$serverConfig.PSObject.Properties['Collation'].Value
    } else {
        Write-Verbose "Collation registry value is not yet available; proceeding without it." -Verbose
    }
}
catch {
    if ($_.FullyQualifiedErrorId -like '*PropertyNotFoundException*' -or $_.Exception.Message -match 'Property Collation does not exist') {
        Write-Verbose "Collation registry value is not yet available; proceeding without it." -Verbose
    } else {
        throw
    }
}

if ($currentCollation) {
    Write-Verbose "Current SQL Server collation: $currentCollation" -Verbose
    if ($currentCollation -eq $SqlCollation) {
        Write-Host "SQL Server is already using the $SqlCollation collation."
        Stop-Transcript | Out-Null 2>$null
        exit 0
    }
} elseif (-not $PSBoundParameters.ContainsKey('Verbose')) {
    Write-Host "Current SQL Server collation is not yet set in the registry; proceeding with rebuild."
}

# --- Normalize system drive root to ensure 'C:\' (not 'C:')
$systemDriveRoot = ([System.IO.Path]::GetFullPath("$($env:SystemDrive)\")).TrimEnd('\') + '\'

# --- Determine setup.exe location (avoid array-to-string pitfalls)
$knownSetupFolders = @(
    (Join-Path -Path $systemDriveRoot -ChildPath 'SQLServerFull'),
    (Join-Path -Path $systemDriveRoot -ChildPath 'SQLServer2019Full'),
    (Join-Path -Path $systemDriveRoot -ChildPath 'SQLServer2022Full')
)

$existingSetupFolders = foreach ($kf in $knownSetupFolders) {
    if (Test-Path -LiteralPath $kf) { $kf }
}

$setupPath = $null

# Prefer known folders
foreach ($folder in $existingSetupFolders) {
    $candidate = Join-Path -Path $folder -ChildPath 'setup.exe'
    if (Test-Path -LiteralPath $candidate) {
        $setupPath = $candidate
        break
    }
}

# Fallback: search safely under the system drive for SQLServer* folders
if (-not $setupPath) {
    try {
        $roots = Get-ChildItem -LiteralPath $systemDriveRoot -Directory -Filter 'SQLServer*' -ErrorAction SilentlyContinue
        foreach ($root in $roots) {
            $candidate = Get-ChildItem -LiteralPath $root.FullName -Filter 'setup.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($candidate) {
                $setupPath = $candidate.FullName
                break
            }
        }
    } catch {
        Write-Verbose "Fallback search for setup.exe failed: $($_.Exception.Message)" -Verbose
    }
}

if (-not $setupPath) {
    Write-Error 'Unable to locate setup.exe for SQL Server. Cannot rebuild system databases to change the collation.'
    Stop-Transcript | Out-Null 2>$null
    exit 1
}

Write-Host "Rebuilding SQL Server system databases with collation $SqlCollation using setup at '$setupPath'."

# --- Ensure the SQL Server service is stopped before rebuilding
$serviceName = 'MSSQLSERVER'
$null = Wait-ForCondition -Condition { Get-Service -Name $serviceName -ErrorAction SilentlyContinue } -Description "SQL Server service $serviceName presence"
$svc = Get-Service -Name $serviceName -ErrorAction Stop
if ($svc.Status -ne 'Stopped') {
    Write-Host "Stopping service $serviceName..."
    Stop-Service -Name $serviceName -Force -ErrorAction Stop
    (Get-Service -Name $serviceName).WaitForStatus('Stopped', [TimeSpan]::FromMinutes(5))
}

# --- Run setup to rebuild master with desired collation
$arguments = @(
    '/QUIET',
    '/ACTION=REBUILDDATABASE',
    '/INSTANCENAME=MSSQLSERVER',
    "/SQLCOLLATION=$SqlCollation",
    '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"'
) -join ' '

Write-Host "Invoking: `"$setupPath`" $arguments"
$proc = Start-Process -FilePath $setupPath -ArgumentList $arguments -PassThru -Wait -NoNewWindow

# --- Check exit code and surface SQL setup logs for easier diagnosis
if ($proc.ExitCode -ne 0) {
    Write-Error ("SQL Server setup returned exit code {0} while rebuilding the system databases." -f $proc.ExitCode)
    # Common setup log locations by version (best-effort hints for CSE logs)
    $logHints = @(
        "$env:ProgramFiles\Microsoft SQL Server\150\Setup Bootstrap\Log\Summary.txt",
        "$env:ProgramFiles\Microsoft SQL Server\160\Setup Bootstrap\Log\Summary.txt",
        "$env:ProgramFiles\Microsoft SQL Server\170\Setup Bootstrap\Log\Summary.txt"
    )
    foreach ($hint in $logHints) {
        if (Test-Path -LiteralPath $hint) {
            Write-Host ("Possible setup log: {0}" -f $hint)
            break
        }
    }
    Stop-Transcript | Out-Null 2>$null
    exit $proc.ExitCode
}

# --- Start the service after rebuild
$svc = Get-Service -Name $serviceName -ErrorAction Stop
if ($svc.Status -ne 'Running') {
    Write-Host "Starting service $serviceName..."
    Start-Service -Name $serviceName
    (Get-Service -Name $serviceName).WaitForStatus('Running', [TimeSpan]::FromMinutes(5))
} else {
    Write-Host "SQL Server service $serviceName is already running after rebuild."
}

Write-Host "SQL Server collation successfully updated to $SqlCollation."
try { Stop-Transcript | Out-Null } catch {}
exit 0
