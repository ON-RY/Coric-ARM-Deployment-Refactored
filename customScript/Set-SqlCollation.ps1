<#
Set-SqlCollation.ps1
- Rebuilds SQL Server system databases for the DEFAULT instance (MSSQLSERVER) with the requested collation.
- Auto-handles pending reboot: schedules itself to resume after reboot, then restarts the VM.
- Designed for Azure Custom Script Extension (non-interactive).

Example (SQL 2019 media in C:\SQLServerFull):
  powershell -ExecutionPolicy Bypass -File Set-SqlCollation.ps1 `
    -SqlCollation "SQL_Latin1_General_CP1_CI_AS" `
    -SqlSetupPath "C:\SQLServerFull\setup.exe" -Verbose
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SqlCollation,

  # Optional: point to the exact setup.exe (recommended)
  [Parameter(Mandatory = $false)]
  [string]$SqlSetupPath,

  # Internal flag used when the script resumes itself after a reboot
  [switch]$ResumeAfterReboot
)

$ErrorActionPreference = 'Stop'

# ---------------- Logging ----------------
$logRoot = 'C:\WindowsAzure\Logs\CustomScript'
$newLog  = $logRoot + '\Set-SqlCollation_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date)
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
try { Start-Transcript -Path $newLog -Force -ErrorAction SilentlyContinue } catch {}

# Keep a simple marker so we don’t create multiple tasks
$marker = Join-Path $logRoot 'Set-SqlCollation.resume.marker'
$taskName = 'Set-SqlCollation-Resume'

function Wait-ForCondition {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][scriptblock]$Condition,
    [Parameter(Mandatory=$true)][string]$Description,
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

function New-ResumeTask-And-Reboot {
  param(
    [Parameter(Mandatory=$true)][string]$ScriptPath,
    [Parameter(Mandatory=$true)][string]$SqlCollationArg,
    [string]$SqlSetupPathArg
  )

  if (Test-Path $marker) {
    Write-Host "Resume marker already present; skipping task creation."
  } else {
    # Build the argument string the task will run after reboot
    $argParts = @(
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', ('"{0}"' -f $ScriptPath),
      '-SqlCollation', ('"{0}"' -f $SqlCollationArg),
      '-ResumeAfterReboot',
      '-Verbose'
    )
    if ($SqlSetupPathArg) {
      $argParts += @('-SqlSetupPath', ('"{0}"' -f $SqlSetupPathArg))
    }
    $taskArgs = ($argParts -join ' ')

    $action    = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument $taskArgs
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount

    Write-Host "Registering resume task '$taskName' to run at startup as SYSTEM..."
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    # Create marker so we don't create this repeatedly
    New-Item -Path $marker -ItemType File -Force | Out-Null
  }

  Write-Host "Rebooting now to clear pending reboot state..."
  try { Stop-Transcript | Out-Null } catch {}
  Restart-Computer -Force
  # Execution stops here; after reboot the task will run us with -ResumeAfterReboot
}

# -------- Basic validation --------
if ($SqlCollation -notmatch '^[A-Za-z0-9_]+$') {
  Write-Error "SqlCollation '$SqlCollation' contains invalid characters. Example: SQL_Latin1_General_CP1_CI_AS"
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

# -------- Pending reboot handling --------
$pendingReboot = (
  (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction SilentlyContinue) -ne $null
) -or (
  Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
)

if ($pendingReboot -and -not $ResumeAfterReboot) {
  # Create resume task & reboot. Use our current on-disk path from the CSE folder (or wherever we are).
  $thisScript = $PSCommandPath
  if (-not $thisScript) { $thisScript = $MyInvocation.MyCommand.Path }
  if (-not (Test-Path $thisScript)) { throw "Cannot determine current script path for resume scheduling." }

  New-ResumeTask-And-Reboot -ScriptPath $thisScript -SqlCollationArg $SqlCollation -SqlSetupPathArg $SqlSetupPath
  return
}

# If we’re resuming, remove the task+marker ASAP to avoid loops
if ($ResumeAfterReboot) {
  try {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
      Write-Host "Removed resume task '$taskName'."
    }
  } catch {}
  try { if (Test-Path $marker) { Remove-Item $marker -Force } } catch {}
}

# -------- Discover default instance --------
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
$instVerStr = $setupInfo.Version
$instVer    = [version]$instVerStr
$instMajor  = $instVer.Major   # 15=SQL 2019, 16=SQL 2022
Write-Host "Detected instance '$instanceName' version $instVerStr (major=$instMajor)."

# Current collation (if present)
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

# -------- System drive normalization --------
$sd = [string]$env:SystemDrive
if (-not $sd.EndsWith('\')) { $sd = $sd + '\' }
if ($sd -notmatch '^[A-Za-z]:\\$') { $sd = 'C:\' }
Write-Host ("DEBUG: SystemDrive='{0}'" -f $sd)

# -------- Locate setup.exe --------
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
  $preferredFolder = switch ($instMajor) {
    16 { $sd + 'SQLServer2022Full' }
    15 { $sd + 'SQLServerFull'     }  # <- your 2019 default drop
    Default { $null }
  }
  $candidates = @()
  if ($preferredFolder -and (Test-Path -LiteralPath $preferredFolder)) {
    $candidates += ,($preferredFolder + '\setup.exe')
  }
  $candidates += @(
    $sd + 'SQLServer2019Full\setup.exe',
    $sd + 'SQLServer2022Full\setup.exe'
  )
  foreach ($cand in $candidates) {
    if (Test-Path -LiteralPath $cand) { $setupPath = $cand; break }
  }
}
if (-not $setupPath) {
  Write-Error 'Unable to locate setup.exe for SQL Server. Provide -SqlSetupPath.'
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}
Write-Host "Setup path resolved to: '$setupPath'"

# Confirm media major matches instance major
$setupVerStr = (Get-Item -LiteralPath $setupPath).VersionInfo.ProductVersion
$setupVer    = [version]$setupVerStr
$setupMajor  = $setupVer.Major
Write-Host "Detected setup.exe version $setupVerStr (major=$setupMajor)."
if ($setupMajor -ne $instMajor) {
  Write-Error "SQL media mismatch: instance major=$instMajor, setup major=$setupMajor. Use matching media (2019↔15.x, 2022↔16.x)."
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

# Ensure DATA dir
$sqlPath  = $setupInfo.SQLPath  # e.g. C:\Program Files\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQL\
$dataDir  = if ($sqlPath) { $sqlPath.TrimEnd('\') + '\DATA' } else { $null }
if ($dataDir -and -not (Test-Path -LiteralPath $dataDir)) {
  New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}

# Stop SQL-related services (avoid file locks)
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

# Build arguments and run setup
$arguments = @(
  '/QUIET',
  '/IACCEPTSQLSERVERLICENSETERMS',
  '/ACTION=REBUILDDATABASE',
  '/INSTANCENAME=MSSQLSERVER',
  "/SQLCOLLATION=$SqlCollation",
  '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"'
)
$argLine = ($arguments -join ' ')
Write-Host "Invoking: `"$setupPath`" $argLine"
$proc = Start-Process -FilePath $setupPath -ArgumentList $argLine -PassThru -Wait -NoNewWindow

# Dump setup logs on failure
function Write-SetupLogsTail {
  param([int]$Lines = 120)
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

# Start engine
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
