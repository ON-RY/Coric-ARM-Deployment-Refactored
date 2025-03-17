$VerbosePreference = 'Continue'
$ErrorActionPreference = 'Stop'

Write-Verbose "Initializing and formatting raw disks"

$disks = Get-Disk | Where partitionstyle -eq 'raw' | sort number

## start at F:\
$letters = 70..89 | ForEach-Object { ([char]$_) }
$count = 0

$somethingAssigned = $false

foreach ($d in $disks)
{
    $driveLetter = $letters[$count].ToString()
    Write-Verbose ("Assigning drive letter '{0}' to disk #'{0}'" -f $driveLetter, $d.number)
    $d |
        Initialize-Disk -PartitionStyle GPT -PassThru |
        New-Partition -UseMaximumSize -DriveLetter $driveLetter |
        Foreach-Object {
            $fileSystemLabel = ''

            if ($ENV:COMPUTERNAME -match 'sql')
            {
                switch ($driveLetter)
                {
                    'F' { $fileSystemLabel = 'SqlBackup' }
                    'G' { $fileSystemLabel = 'SqlData' }
                    'H' { $fileSystemLabel = 'SqlLogs' }
                }
            }
            else
            {
                switch ($driveLetter)
                {
                    'F' { $fileSystemLabel = 'Data' }
                }
            }

            if ($fileSystemLabel)
            {
                $_ | Format-Volume -FileSystem NTFS -NewFileSystemLabel $fileSystemLabel -Confirm:$false -Force
            }
            else
            {
                $_ | Format-Volume -FileSystem NTFS -Confirm:$false -Force
            }
        }

    $somethingAssigned = $true

    $count++
}

if ($somethingAssigned)
{
    Restart-Service Server -Force
}
