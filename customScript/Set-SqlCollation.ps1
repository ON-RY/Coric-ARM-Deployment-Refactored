[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$SqlCollation,

  [Parameter(Mandatory=$false)]
  [string]$SqlSetupPath = 'C:\SQLServerFull\setup.exe',

  [switch]$ResumeAfterReboot
)

$ErrorActionPreference = 'Stop'

# ----- logging -----
$logRoot = 'C:\WindowsAzure\Logs\CustomScript'
$newLog  = Join-Path $logRoot ('Set-SqlCollation_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
try { Start-Transcript -Path $newLog -Force -ErrorAction SilentlyContinue } catch {}

# ----- helpers -----
function Wait-ForCondition {
  param([scriptblock]$Condition,[string]$Description,[int]$TimeoutMinutes=45,[int]$DelaySeconds=15)
  $deadline=(Get-Date).AddMinutes($TimeoutMinutes)
  $result=$null
  while(-not($result=& $Condition)){
    if((Get-Date) -ge $deadline){ throw "Timed out waiting for $Description after $TimeoutMinutes minutes." }
    Write-Host "Waiting for $Description..."
    Start-Sleep -Seconds $DelaySeconds
  }
  return $result
}

function Test-PendingReboot {
  $cbsp='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
  $pfr = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
  return (Test-Path $cbsp) -or ($null -ne $pfr)
}

function Register-ResumeTask {
  param([string]$TaskName,[string]$ScriptFullPath,[string]$SqlCollationArg,[string]$SqlSetupPathArg)
  $pwsh="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $args=@(
    '-NoProfile','-ExecutionPolicy','Bypass',
    '-File',('"{0}"' -f $ScriptFullPath),
    '-SqlCollation',('"{0}"' -f $SqlCollationArg),
    '-SqlSetupPath',('"{0}"' -f $SqlSetupPathArg),
    '-ResumeAfterReboot','-Verbose'
  ) -join ' '
  try{ Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }catch{}
  $action=New-ScheduledTaskAction -Execute $pwsh -Argument $args
  $trigger=New-ScheduledTaskTrigger -AtStartup
  $princ=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -StartWhenAvailable
  $task=New-ScheduledTask -Action $action -Trigger $trigger -Principal $princ -Settings $settings
  Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
  Write-Host "Registered resume task '$TaskName'."
}

function Unregister-ResumeTask { param([string]$TaskName)
  try{
    if(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue){
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
      Write-Host "Removed resume task '$TaskName'."
    }
  }catch{}
}

function Tail-SetupLogs { param([int]$Lines=120)
  $roots=@(
    "$env:ProgramFiles\Microsoft SQL Server\150\Setup Bootstrap\Log",
    "$env:ProgramFiles\Microsoft SQL Server\160\Setup Bootstrap\Log"
  )
  foreach($r in $roots){
    if(-not(Test-Path $r)){ continue }
    $sum=Join-Path $r 'Summary.txt'
    if(Test-Path $sum){
      Write-Host "----- Tail Summary.txt ($sum) -----"
      Get-Content $sum -ErrorAction SilentlyContinue | Select-Object -Last $Lines | ForEach-Object { Write-Host $_ }
    }
    $latest=Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if($latest){
      $det=Join-Path $latest.FullName 'Detail.txt'
      if(Test-Path $det){
        Write-Host "----- Tail Detail.txt ($det) -----"
        Get-Content $det -ErrorAction SilentlyContinue | Select-Object -Last $Lines | ForEach-Object { Write-Host $_ }
      }
    }
    break
  }
}

# ----- validate input -----
if($SqlCollation -notmatch '^[A-Za-z0-9_]+$'){
  Write-Error "SqlCollation '$SqlCollation' contains invalid characters. Example: SQL_Latin1_General_CP1_CI_AS"
  try{ Stop-Transcript | Out-Null }catch{}
  exit 1
}

# ----- auto-reboot handling -----
$TaskName='Set-SqlCollation-Resume'
$scriptPath=$MyInvocation.MyCommand.Path

if(-not $ResumeAfterReboot){
  if(Test-PendingReboot){
    Write-Host "Pending reboot detected -> registering resume task and rebooting now."
    Register-ResumeTask -TaskName $TaskName -ScriptFullPath $scriptPath -SqlCollationArg $SqlCollation -SqlSetupPathArg $SqlSetupPath
    try{ Stop-Transcript | Out-Null }catch{}
    Restart-Computer -Force
    Start-Sleep -Seconds 10
    exit 0
  }
}else{
  Unregister-ResumeTask -TaskName $TaskName
}

# ----- discover instance/version -----
$instKey='HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
Wait-ForCondition -Condition { Test-Path -LiteralPath $instKey } -Description "SQL instance registry key"

$instanceName=Wait-ForCondition -Condition {
  if(Test-Path -LiteralPath $instKey){
    $v=(Get-ItemProperty -Path $instKey -ErrorAction SilentlyContinue).MSSQLSERVER
    if($v){ return $v }
  }
  $false
} -Description 'default SQL Server instance name'

$serverKey="HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceName\MSSQLServer"
Wait-ForCondition -Condition { Test-Path -LiteralPath $serverKey } -Description "SQL Server config registry key"

$setupKey="HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceName\Setup"
$setupInfo=Get-ItemProperty -Path $setupKey -ErrorAction Stop
$instVerStr=$setupInfo.Version
$instMajor=([version]$instVerStr).Major
Write-Host "Detected instance '$instanceName' version $instVerStr (major=$instMajor)."

# already correct collation?
try{
  $serverConfig=Get-ItemProperty -Path $serverKey -ErrorAction Stop
  if($serverConfig.PSObject.Properties.Match('Collation').Count -gt 0){
    $cur=[string]$serverConfig.PSObject.Properties['Collation'].Value
    if($cur){ Write-Host "Current collation: $cur" }
    if($cur -eq $SqlCollation){
      Write-Host "SQL Server already uses $SqlCollation. Nothing to do."
      try{ Stop-Transcript | Out-Null }catch{}
      exit 0
    }
  }
}catch{}

# ----- locate setup.exe -----
if(-not (Test-Path -LiteralPath $SqlSetupPath)){
  Write-Error "setup.exe not found at '$SqlSetupPath'."
  try{ Stop-Transcript | Out-Null }catch{}
  exit 1
}
$setupVerStr=(Get-Item -LiteralPath $SqlSetupPath).VersionInfo.ProductVersion
$setupMajor=([version]$setupVerStr).Major
Write-Host "Using setup.exe '$SqlSetupPath' version $setupVerStr (major=$setupMajor)."
if($setupMajor -ne $instMajor){
  Write-Error "SQL media mismatch: instance major=$instMajor, setup major=$setupMajor. Use matching media (SQL 2019 = 15.x)."
  try{ Stop-Transcript | Out-Null }catch{}
  exit 1
}

# ----- ensure DATA dir + ACL -----
$sqlPath=$setupInfo.SQLPath
$dataDir=if($sqlPath){ ($sqlPath.TrimEnd('\') + '\DATA') } else { "$env:ProgramFiles\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQL\DATA" }
if(-not(Test-Path -LiteralPath $dataDir)){ New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
try{
  $acl=Get-Acl -Path $dataDir
  $rule=New-Object System.Security.AccessControl.FileSystemAccessRule('NT SERVICE\MSSQLSERVER','Modify','ContainerInherit,ObjectInherit','None','Allow')
  $acl.SetAccessRule($rule); Set-Acl -Path $dataDir -AclObject $acl
}catch{
  # >>> FIXED LINE (use -f formatting so colon isn't glued to $dataDir)
  Write-Host ("WARN: Failed to set ACL on {0}: {1}" -f $dataDir, $_.Exception.Message)
}
Write-Host ("DATA directory: {0}" -f $dataDir)

# ----- stop related services -----
$serviceNames=@(
  'SQLSERVERAGENT','MSSQLSERVER','SQLBrowser','SQLWriter','SQLFullText',
  'MsDtsServer130','MsDtsServer140','MsDtsServer150','MsDtsServer160',
  'SSISTELEMETRY130','SSISTELEMETRY140','SSISTELEMETRY150','SSISTELEMETRY160',
  'SQLTELEMETRY','SQLTELEMETRY$MSSQLSERVER','MSOLAP$MSSQLSERVER',
  'MSSQLFDLauncher','SQLLaunchpad','SQLLaunchpad$MSSQLSERVER'
)
foreach($sn in $serviceNames){
  $svc=Get-Service -Name $sn -ErrorAction SilentlyContinue
  if($svc -and $svc.Status -ne 'Stopped'){
    Write-Host "Stopping $sn ..."
    try{ Stop-Service -Name $sn -Force -ErrorAction Stop }catch{}
    try{ (Get-Service -Name $sn).WaitForStatus('Stopped',[TimeSpan]::FromMinutes(3)) }catch{}
  }
}
$null=Wait-ForCondition -Condition { Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue } -Description "MSSQLSERVER service presence"

# ----- rebuild -----
$arguments=@(
  '/QUIET',
  '/IACCEPTSQLSERVERLICENSETERMS',
  '/ACTION=REBUILDDATABASE',
  '/INSTANCENAME=MSSQLSERVER',
  "/SQLCOLLATION=$SqlCollation",
  '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"'
  
) -join ' '

Write-Host "Invoking: `"$SqlSetupPath`" $arguments"
$proc=Start-Process -FilePath $SqlSetupPath -ArgumentList $arguments -PassThru -Wait -NoNewWindow

if($proc.ExitCode -ne 0){
  Write-Error ("SQL Server setup returned exit code {0} while rebuilding the system databases." -f $proc.ExitCode)
  Tail-SetupLogs -Lines 160
  try{ Stop-Transcript | Out-Null }catch{}
  exit $proc.ExitCode
}

# ----- start engine -----
$svc=Get-Service -Name 'MSSQLSERVER' -ErrorAction Stop
if($svc.Status -ne 'Running'){
  Write-Host "Starting MSSQLSERVER..."
  Start-Service -Name 'MSSQLSERVER'
  (Get-Service -Name 'MSSQLSERVER').WaitForStatus('Running',[TimeSpan]::FromMinutes(5))
}else{
  Write-Host "MSSQLSERVER already running."
}

Write-Host "SQL Server collation successfully updated to $SqlCollation."
try{ Stop-Transcript | Out-Null }catch{}
exit 0
