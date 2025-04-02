$VerbosePreference = 'Continue'
$ErrorActionPreference = 'Stop'

try {
    Write-Verbose "Initializing and formatting raw disks"
    
    $disks = Get-Disk | Where partitionstyle -eq 'raw' | sort number
    
    # Check if any raw disks exist
    if (-not $disks) {
        Write-Verbose "No raw disks found to initialize"
        exit 0  # Exit successfully if no disks to initialize
    }
    
    ## start at F:\
    $letters = 70..89 | ForEach-Object { ([char]$_) }
    $count = 0
    $somethingAssigned = $false
    
    foreach ($d in $disks) {
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
    
    if ($somethingAssigned) {
        try {
            Restart-Service Server -Force
        }
        catch {
            Write-Warning "Could not restart Server service: $_"
            # But don't fail the whole script for this
        }
    }
    
    exit 0  # Explicitly exit with success code
}
catch {
    Write-Error "Error initializing disks: $_"
    exit 1  # Exit with failure code
}

