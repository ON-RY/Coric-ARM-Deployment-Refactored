<#
Set-SqlCollation.ps1
- Rebuilds SQL Server system databases for DEFAULT instance (MSSQLSERVER) to the requested collation.
- Safe for Azure Custom Script Extension (CSE).

Highlights
- Auto-resume after reboot (pending reboot detected -> register task -> reboot -> resume).
- Verifies SQL media MAJOR version matches installed instance (SQL 2019=15.x).
- Stops all SQL-related services to avoid file locks.
- Accepts license in silent mode.
- Forces DATA/TEMPDB/USERDB dirs and fixes ACL for 'NT SERVICE\MSSQLSERVER'.
- Tails SQL Setup Summary/Detail logs on failure.

CSE example:
  powershell -ExecutionPolicy Bypass -File Set-SqlCollation.ps1 -SqlCollation "SQL_Latin1_General_CP1_CI_AS" -Verbose
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$SqlCollation,

  [Parameter(Mandatory=$false)]
  [string]$SqlSetupPath = 'C:\SQLServerFull\setup.exe',  # your default media path

  # INTERNAL: set by the resume task after reboot. Do NOT pass from CSE.
  [switch]$ResumeAfterReboot
)

$ErrorActionPreference = 'Stop'

# ---------------- Logging ----------------
$logRoot = 'C:\WindowsAzure\Logs\CustomScript'
$newLog  = Join-Path $logRoot ("Set-SqlCollation_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
try { Start-Transcript -Path $newLog -Force -ErrorAction SilentlyContinue } catch {}

# ---------------- Helpers ----------------
function Wait-ForCondition {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][scriptblock]$Condition,
    [Parameter(Mandatory=$true)][string]$Description,
    [int]$TimeoutMinutes = 45,
    [int]$DelaySeconds   = 15
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

function Test-PendingReboot {
  $cbsp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
  $pfr  = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
  return (Test-Path $cbsp) -or ($null -ne $pfr)
}

function Register-ResumeTask {
  param(
    [Parameter(Mandatory)] [string]$TaskName,
    [Parameter(Mandatory)] [string]$ScriptFullPath,
    [Parameter(Mandatory)] [string]$SqlCollation,
    [Parameter(Mandatory)] [string]$SqlSetupPath
  )

  # Build the exact resume command (run as SYSTEM at startup)
  $pwsh = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $args = @(
    '-NoProfile','-ExecutionPolicy','Bypass',
    '-File', ('"{0}"' -f $ScriptFullPath),
    '-SqlCollation', ('"{0}"' -f $SqlCollation),
    '-SqlSetupPath', ('"{0}"' -f $SqlSetupPath),
    '-ResumeAfterReboot',
    '-Verbose'
  ) -join ' '

  # Create task
  $action  = New-ScheduledTaskAction -Execute $pwsh -Argument $args
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $princ   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
  $task    = New-ScheduledTask -Action $action -Trigger $trigger -Principal $princ -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -StartWhenAvailable)
  Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
}

function Unregister-ResumeTask {
  param([Parameter(Mandatory)][string]$TaskName)
  try {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
      Write-Host "Removed resume task '$TaskName'."
    }
  } catch {}
}

function Tail-SetupLogs {
  param([int]$Lines=120)
  $roots = @(
    "$env:ProgramFiles\Microsoft SQL Server\150\Setup Bootstrap\Log",  # SQL 2019
    "$env:ProgramFiles\Microsoft SQL Server\160\Setup Bootstrap\Log"   # SQL 2022 (just in case)
  )
  foreach ($r in $roots) {
    if (-not (Test-Path $r)) { continue }
    $sum = Join-Path $r 'Summary.txt'
    if (Test-Path $sum) {
      Write-Host "----- Tail Summary.txt ($sum) -----"
      Get-Content $sum -ErrorAction SilentlyContinue | Select-Object -Last $Lines | ForEach-Object { Write-Host $_ }
    }
    $latest = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
      $det = Join-Path $latest.FullName 'Detail.txt'
      if (Test-Path $det) {
        Write-Host "----- Tail Detail.txt ($det) -----"
        Get-Content $det -ErrorAction SilentlyContinue | Select-Object -Last $Lines | ForEach-Object { Write-Host $_ }
      }
    }
    break
  }
}

# ---------------- Validation ----------------
if ($SqlCollation -notmatch '^[A-Za-z0-9_]+$') {
  Write-Error "SqlCollation '$SqlCollation' contains invalid characters. Example: SQL_Latin1_General_CP1_CI_AS"
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

# ---------------- Auto-reboot handling ----------------
$TaskName = 'Set-SqlCollation-Resume'
$scriptPath = $MyInvocation.MyCommand.Path

if (-not $ResumeAfterReboot) {
  if (Test-PendingReboot) {
    Write-Host "Pending reboot detected -> registering resume task and rebooting now."
    Register-ResumeTask -TaskName $TaskName -ScriptFullPath $scriptPath -SqlCollation $SqlCollation -SqlSetupPath $SqlSetupPath
    try { Stop-Transcript | Out-Null } catch {}
    Restart-Computer -Force
    # In case Restart-Computer fails to terminate the process immediately:
    Start-Sleep -Seconds 10
    exit 0
  }
} else {
  # We're running post-reboot via the scheduled task
  Unregister-ResumeTask -TaskName $TaskName
}

# ---------------- Detect instance + version ----------------
$instKey  = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
Wait-ForCondition -Condition { Test-Path -LiteralPath $instKey } -Description "SQL instance registry key at $instKey"

$instanceName = Wait-ForCondition -Condition {
  if (Test-Path -LiteralPath $instKey) {
    $val = (Get-ItemProperty -Path $instKey -ErrorAction SilentlyContinue).MSSQLSERVER
    if ($val) { return $val }
  }; $false
} -Description 'default SQL Server instance name'

$serverKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceName\MSSQLServer"
Wait-ForCondition -Condition { Test-Path -LiteralPath $serverKey } -Description "SQL Server config registry key at $serverKey"

$setupKey   = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceName\Setup"
$setupInfo  = Get-ItemProperty -Path $setupKey -ErrorAction Stop
$instVerStr = $setupInfo.Version
$instMajor  = ([version]$instVerStr).Major
Write-Host "Detected instance '$instanceName' version $instVerStr (major=$instMajor)."

# Current collation (if present)
try {
  $serverConfig = Get-ItemProperty -Path $serverKey -ErrorAction Stop
  if ($serverConfig.PSObject.Properties.Match('Collation').Count -gt 0) {
    $cur = [string]$serverConfig.PSObject.Properties['Collation'].Value
    if ($cur) { Write-Host "Current collation: $cur" }
    if ($cur -eq $SqlCollation) {
      Write-Host "SQL Server already uses $SqlCollation. Nothing to do."
      try { Stop-Transcript | Out-Null } catch {}
      exit 0
    }
  }
} catch {}

# ---------------- Locate setup.exe ----------------
if (-not (Test-Path -LiteralPath $SqlSetupPath)) {
  Write-Error "setup.exe not found at '$SqlSetupPath'."
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}
$setupVerStr = (Get-Item -LiteralPath $SqlSetupPath).VersionInfo.ProductVersion
$setupMajor  = ([version]$setupVerStr).Major
Write-Host "Using setup.exe '$SqlSetupPath' version $setupVerStr (major=$setupMajor)."

if ($setupMajor -ne $instMajor) {
  Write-Error "SQL media mismatch: instance major=$instMajor, setup major=$setupMajor. Use matching media (SQL 2019↔15.x)."
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

# ---------------- Ensure DATA dir + ACL ----------------
# Preferred path from registry, else sensible default for 2019
$sqlPath = $setupInfo.SQLPath
$dataDir = if ($sqlPath) { ($sqlPath.TrimEnd('\') + '\DATA') } else { "$env:ProgramFiles\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQL\DATA" }
if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
# Grant engine SID modify rights (covers edge cases)
try {
  $acl  = Get-Acl -Path $dataDir
  $rule = New-Object System.Security.AccessControl.FileSystemAccessRule('NT SERVICE\MSSQLSERVER','Modify','ContainerInherit,ObjectInherit','None','Allow')
  $acl.SetAccessRule($rule); Set-Acl -Path $dataDir -AclObject $acl
} catch { Write-Host "WARN: Failed to set ACL on $dataDir: $($_.Exception.Message)" }

Write-Host "DATA directory: $dataDir"

# ---------------- Stop related services ----------------
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
$null = Wait-ForCondition -Condition { Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue } -Description "MSSQLSERVER service presence"

# ---------------- Run setup (REBUILDDATABASE) ----------------
# Force dirs to remove ambiguity
$arguments = @(
  '/QUIET',
  '/IACCEPTSQLSERVERLICENSETERMS',
  '/ACTION=REBUILDDATABASE',
  '/INSTANCENAME=MSSQLSERVER',
  "/SQLCOLLATION=$SqlCollation",
  '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"',
  "/SQLUSERDBDIR=""$dataDir""",
  "/SQLUSERDBLOGDIR=""$dataDir""",
  "/SQLTEMPDBDIR=""$dataDir""",
  "/SQLTEMPDBLOGDIR=""$dataDir"""
) -join ' '

Write-Host "Invoking: `"$SqlSetupPath`" $arguments"
$proc = Start-Process -FilePath $SqlSetupPath -ArgumentList $arguments -PassThru -Wait -NoNewWindow

if ($proc.ExitCode -ne 0) {
  Write-Error ("SQL Server setup returned exit code {0} while rebuilding the system databases." -f $proc.ExitCode)
  Tail-SetupLogs -Lines 160
  try { Stop-Transcript | Out-Null } catch {}
  exit $proc.ExitCode
}

# ---------------- Start engine ----------------
$svc = Get-Service -Name 'MSSQLSERVER' -ErrorAction Stop
if ($svc.Status -ne 'Running') {
  Write-Host "Starting MSSQLSERVER..."
  Start-Service -Name 'MSSQLSERVER'
  (Get-Service -Name 'MSSQLSERVER').WaitForStatus('Running', [TimeSpan]::FromMinutes(5))
} else {
  Write-Host "MSSQLSERVER already running."
}

Write-Host "SQL Server collation successfully updated to $SqlCollation."
try { Stop-Transcript | Out-Null } catch {}
exit 0
