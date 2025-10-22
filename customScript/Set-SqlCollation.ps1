<#
Set-SqlCollation.ps1
- Rebuilds SQL Server system databases for the DEFAULT instance (MSSQLSERVER) with the requested collation.
- Designed for Azure Custom Script Extension (no interactive prompts).

Key safeguards:
- Checks Windows pending reboot.
- Ensures SQL media MAJOR version matches installed instance.
- Stops all related services to avoid file locks.
- Accepts license in silent mode.
- Surfaces Setup Summary/Detail logs into CSE output on failure.

USAGE (CSE example):
  powershell -ExecutionPolicy Bypass -File Set-SqlCollation.ps1 -SqlCollation "SQL_Latin1_General_CP1_CI_AS" -Verbose

OPTION: pin the exact setup.exe:
  powershell -ExecutionPolicy Bypass -File Set-SqlCollation.ps1 -SqlCollation "SQL_Latin1_General_CP1_CI_AS" -SqlSetupPath "C:\SQLServer2022Full\setup.exe" -Verbose
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SqlCollation,

  # Optional: provide the exact path to setup.exe to avoid discovery/search.
  [Parameter(Mandatory = $false)]
  [string]$SqlSetupPath
)

$ErrorActionPreference = 'Stop'

# --- Logging for CSE troubleshooting ---------------------------------------------------------------
$logRoot = 'C:\WindowsAzure\Logs\CustomScript'
$newLog  = $logRoot + '\Set-SqlCollation_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date)
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
try { Start-Transcript -Path $newLog -Force -ErrorAction SilentlyContinue } catch {}

function Wait-ForCondition {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Condition,
    [Parameter(Mandatory = $true)][string]$Description,
    [int]$TimeoutMinutes = 45,
    [int]$DelaySeconds = 15
  )
  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  $result = $null
  while (-not ($result = & $Condition)) {
    if ((Get-Date) -ge $deadline) { throw "Timed out waiting for $Description after $TimeoutMinutes minutes." }
    Write-Host "Waiting for $Description..."
    Start-Sleep -Seconds $DelaySeconds
  }
  return $result
}

# --- Basic validation -----------------------------------------------------------------------------
if ($SqlCollation -notmatch '^[A-Za-z0-9_]+$') {
  Write-Error "SqlCollation '$SqlCollation' contains invalid characters. Example: SQL_Latin1_General_CP1_CI_AS"
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

# --- Fail fast on pending reboot ------------------------------------------------------------------
$pendingReboot = (
  (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction SilentlyContinue) -ne $null
) -or (
  Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
)
if ($pendingReboot) {
  Write-Error "Windows has a pending reboot. Reboot the VM and rerun the deployment."
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

# --- Discover default instance via registry --------------------------------------------------------
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

# Instance version info (to match media)
$setupKey   = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceName\Setup"
$setupInfo  = Get-ItemProperty -Path $setupKey -ErrorAction Stop
$instVerStr = $setupInfo.Version         # e.g. 16.0.1000.6
$instVer    = [version]$instVerStr
$instMajor  = $instVer.Major             # 15=SQL2019, 16=SQL2022

Write-Host "Detected instance '$instanceName' version $instVerStr (major=$instMajor)."

# --- Current collation (if available)
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
  } else { throw }
}

if ($currentCollation) {
  Write-Verbose "Current SQL Server collation: $currentCollation" -Verbose
  if ($currentCollation -eq $SqlCollation) {
    Write-Host "SQL Server is already using the $SqlCollation collation."
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
  }
} elseif (-not $PSBoundParameters.ContainsKey('Verbose')) {
  Write-Host "Current SQL Server collation is not yet set in the registry; proceeding with rebuild."
}

# --- Normalize system drive root to 'C:\' ---------------------------------------------------------
$sd = [string]$env:SystemDrive
if (-not $sd.EndsWith('\')) { $sd = $sd + '\' }
if ($sd -notmatch '^[A-Za-z]:\\$') { $sd = 'C:\' }
Write-Host ("DEBUG: SystemDrive='{0}' (type={1})" -f $sd, $sd.GetType().FullName)

# --- Locate setup.exe -----------------------------------------------------------------------------
$setupPath = $null
if ($SqlSetupPath) {
  if (Test-Path -LiteralPath $SqlSetupPath) {
    $setupPath = (Resolve-Path -LiteralPath $SqlSetupPath).Path
    Write-Host "Using provided setup path: '$setupPath'"
  } else {
    Write-Error "Provided -SqlSetupPath '$SqlSetupPath' does not exist."
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
  }
}

if (-not $setupPath) {
  # Prefer matching media folder based on instance MAJOR
  $preferredFolder = switch ($instMajor) {
    16 { $sd + 'SQLServer2022Full' }  # SQL 2022
    15 { $sd + 'SQLServer2019Full' }  # SQL 2019
    Default { $null }
  }
  $candidates = @()
  if ($preferredFolder -and (Test-Path -LiteralPath $preferredFolder)) {
    $candidates += ,($preferredFolder + '\setup.exe')
  }
  # Fall back to common names
  $candidates += @(
    $sd + 'SQLServerFull\setup.exe',
    $sd + 'SQLServer2019Full\setup.exe',
    $sd + 'SQLServer2022Full\setup.exe'
  )
  foreach ($cand in $candidates) {
    if (Test-Path -LiteralPath $cand) { $setupPath = $cand; break }
  }
  if (-not $setupPath) {
    try {
      $roots = Get-ChildItem -LiteralPath $sd -Directory -Filter 'SQLServer*' -ErrorAction SilentlyContinue
      foreach ($root in $roots) {
        $cand = Get-ChildItem -LiteralPath $root.FullName -Filter 'setup.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cand) { $setupPath = $cand.FullName; break }
      }
    } catch { Write-Verbose "Fallback search for setup.exe failed: $($_.Exception.Message)" -Verbose }
  }
}
if (-not $setupPath) {
  Write-Error 'Unable to locate setup.exe for SQL Server. Cannot rebuild system databases to change the collation.'
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}
Write-Host "Setup path resolved to: '$setupPath'"

# --- Confirm media MAJOR matches instance MAJOR ---------------------------------------------------
$setupVerStr = (Get-Item -LiteralPath $setupPath).VersionInfo.ProductVersion
$setupVer    = [version]$setupVerStr
$setupMajor  = $setupVer.Major
Write-Host "Detected setup.exe version $setupVerStr (major=$setupMajor)."

if ($setupMajor -ne $instMajor) {
  Write-Error "SQL media mismatch: instance major=$instMajor, setup major=$setupMajor. Use matching media (e.g., SQL 2019↔15.x, SQL 2022↔16.x)."
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

# --- Ensure DATA directory exists (where master files will live) ----------------------------------
$sqlPath  = $setupInfo.SQLPath            # e.g. C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\
$dataDir  = if ($sqlPath) { $sqlPath.TrimEnd('\') + '\DATA' } else { $null }
if ($dataDir -and -not (Test-Path -LiteralPath $dataDir)) {
  New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}
if ($dataDir) { Write-Host "DATA directory: '$dataDir'" }

# --- Stop ALL related SQL services to avoid file locks --------------------------------------------
$serviceNames = @(
  'SQLSERVERAGENT','MSSQLSERVER','SQLBrowser','SQLWriter','SQLFullText',
  'MsDtsServer130','MsDtsServer140','MsDtsServer150','MsDtsServer160',
  'SSISTELEMETRY130','SSISTELEMETRY140','SSISTELEMETRY150','SSISTELEMETRY160',
  'SQLTELEMETRY','SQLTELEMETRY$MSSQLSERVER','MSOLAP$MSSQLSERVER',
  'MSSQLFDLauncher','SQLLaunchpad','SQLLaunchpad$MSSQLSERVER'
)
foreach ($sn in $serviceNames) {
  $svc = Get-Service -Name $sn -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -ne 'Stopped') {
    Write-Host "Stopping $sn ..."
    try { Stop-Service -Name $sn -Force -ErrorAction Stop } catch {}
    try { (Get-Service -Name $sn).WaitForStatus('Stopped', [TimeSpan]::FromMinutes(3)) } catch {}
  }
}
$null = Wait-ForCondition -Condition { Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue } -Description "SQL Server service MSSQLSERVER presence"

# --- Build arguments and run setup (REBUILDDATABASE) ----------------------------------------------
$arguments = @(
  '/QUIET',
  '/IACCEPTSQLSERVERLICENSETERMS',
  '/ACTION=REBUILDDATABASE',
  '/INSTANCENAME=MSSQLSERVER',
  "/SQLCOLLATION=$SqlCollation",
  '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"'
)

# Optional: force dirs explicitly if you want to be pedantic
# if ($dataDir) {
#   $arguments += "/SQLUSERDBDIR=""$dataDir"""
#   $arguments += "/SQLUSERDBLOGDIR=""$dataDir"""
#   $arguments += "/SQLTEMPDBDIR=""$dataDir"""
#   $arguments += "/SQLTEMPDBLOGDIR=""$dataDir"""
# }

$argLine = ($arguments -join ' ')
Write-Host "Invoking: `"$setupPath`" $argLine"
$proc = Start-Process -FilePath $setupPath -ArgumentList $argLine -PassThru -Wait -NoNewWindow

# --- On failure: surface Setup logs (Summary & latest Detail) to CSE output -----------------------
function Write-SetupLogsTail {
  param([int]$Lines = 80)
  $root = Join-Path $env:ProgramFiles 'Microsoft SQL Server'
  if (-not (Test-Path -LiteralPath $root)) { return }
  $majors = @($instMajor, 17, 16, 15, 14) | Select-Object -Unique
  foreach ($m in $majors) {
    $logRoot = Join-Path (Join-Path $root "$m`0\Setup Bootstrap\Log") ''
    if (-not (Test-Path -LiteralPath $logRoot)) { continue }

    $summary = Join-Path $logRoot 'Summary.txt'
    if (Test-Path -LiteralPath $summary) {
      Write-Host "----- Tail of setup Summary.txt ($summary) -----"
      Get-Content -LiteralPath $summary -ErrorAction SilentlyContinue | Select-Object -Last $Lines | ForEach-Object { Write-Host $_ }
    }

    # Find latest timestamped subfolder and print Detail.txt tail
    $latest = Get-ChildItem -LiteralPath $logRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
      $detail = Join-Path $latest.FullName 'Detail.txt'
      if (Test-Path -LiteralPath $detail) {
        Write-Host "----- Tail of setup Detail.txt ($detail) -----"
        Get-Content -LiteralPath $detail -ErrorAction SilentlyContinue | Select-Object -Last $Lines | ForEach-Object { Write-Host $_ }
      }
    }
    break
  }
}

if ($proc.ExitCode -ne 0) {
  Write-Error ("SQL Server setup returned exit code {0} while rebuilding the system databases." -f $proc.ExitCode)
  Write-SetupLogsTail -Lines 120
  try { Stop-Transcript | Out-Null } catch {}
  exit $proc.ExitCode
}

# --- Start the engine after rebuild ----------------------------------------------------------------
$svc = Get-Service -Name 'MSSQLSERVER' -ErrorAction Stop
if ($svc.Status -ne 'Running') {
  Write-Host "Starting service MSSQLSERVER..."
  Start-Service -Name 'MSSQLSERVER'
  (Get-Service -Name 'MSSQLSERVER').WaitForStatus('Running', [TimeSpan]::FromMinutes(5))
} else {
  Write-Host "SQL Server service MSSQLSERVER is already running after rebuild."
}

Write-Host "SQL Server collation successfully updated to $SqlCollation."
try { Stop-Transcript | Out-Null } catch {}
exit 0
