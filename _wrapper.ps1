# DECLARE CONSTANTS/GLOBAL VARIABLES
## Environment
$TODAY = (Get-Date).ToString("yyyyMMdd")
$SERVER = $env:computername
## Directories
$BASE = "C:\Scripts\"
$ARCHIVE = "C:\Archive\"
$STAGE = "${BASE}stage\"
## Program Files
$PF = "${env:ProgramFiles}"
$WR_PROG = "${PF}\WinRAR\Winrar.exe"

$PFx86 = "${env:ProgramFiles(x86)}"
$GPG_PROG =  "${PFx86}\GNU\GnuPG\gpg.exe"
$WINSCP_PROG = "${PFx86}\WinSCP\WinSCP.com"
## Setup
CD $BASE # Change Directory to Base; Only Required for get-VendorConfigurations
[xml]$CONF = (Get-Content "${BASE}Configurations.xml") # Get "vendor configurations".

function format-String {
    param($String)
    $String = "`"$String`""
    return $String
}

function get-VendorConfigurations {
    # Get file mask for a given vendor and company via SQLCMD batch script.
    # Cannot use Invoke-SQL in this version of Powershell, so must read results
    # from a file.
    param($Company, $Vendor)
    
    $ArgList = @(
            "/C"
            "_get_configurations.bat"
            $company
            $vendor
    )
    Start cmd.exe -ArgumentList $ArgList -Wait -NoNewWindow
    
    $_filemask = (Get-Content "_filemask.psv" | Select-Object -Skip 1)
    Remove-Item "${BASE}_filemask.psv"
    return $_filemask.Trim()
}

function decrypt-File {
    # Take common extensions and remove them from the file.
    # All files within Feeds Archived are encrypted at least
    # once.
    param($FilePath, $FileName)
    $_ext = @( # Common file extensions, including encryption and non-encryption.
        ".pgp"
        ".asc"
        ".gpg"
        ".txt"
        ".csv"
        ".psv"
        ".dat"
    )
    $_ext = ($_ext -join "|")
    [Regex]$_ext_regex = ("(${_ext}){2,}") # Turn the extensions into a regex pattern, with the or ("|") operator.
    
    $NewName = ($FileName.ToLower() -Replace $_ext_regex, ".txt.pgp")
    $Unencrypted = ($NewName -Replace ".pgp", "")
    
    $FullName = (Join-Path $FilePath $FileName)
    $NewFulLName = (Join-Path $FilePath $NewName)
    $UnencryptedPath = (Join-Path $FilePath $Unencrypted)
    Rename-Item $FullName $NewName
    
    try { # Not all files are encrypted.
        & $GPG_PROG --passphrase "${PASSPHRASE}" -o ($UnencryptedPath) -d ($NewFullName)
        $result = $UnencryptedPath
    } catch {
        $result = $FullName
    }
    
    return $result
}

function get-ArchivedFile {
    # Get the archived file.
    param($FileMask)
    $FileMask = ($FileMask -Replace "\{.*\}", "*") # Remove the "datestamp" from the file name configuration.
    $_mask = "${ARCHIVE}*${FileMask}*"
    $_file = (gci -Path ($_mask) | Sort LastWriteTime | Select -Last 1)
    
    if ($_file -ne $null) { Copy-Item $_file -Destination $STAGE }
    return $_file.Name
}

function get-ZippedFile {
    # Fetch zipped file and unzip it for a given target file.
    Param($FileMask, $TargetMask)
    $_file = (get-ArchivedFile -FileMask $FileMask)
    $_new_file = (decrypt-File -FilePath $STAGE -FileName $_file)
    
    $_to_unzip = ($_new_file -Replace ".txt$", "")
    Rename-Item $_new_file $_to_unzip
    & $WR_PROG x $_to_unzip $STAGE
    sleep(2) # Buffer needed for directory to refresh.
    
    $_mask = "${STAGE}*${TargetMask}*"
    $_target = (gci -Path ($_mask))
    return $_target.Name
}

function format-VendorFile {
    # Rename vendor files to include the vendor's name.
    Param($VendorName, $FileMask)
    $VendorName = ($VendorName -Replace '"', "")
    $new_name = ("${VendorName}-${file}")
    Rename-Item "${STAGE}${file}" $new_name
    return $new_name
}

function get-VendorFile {
    # Function that wraps all the other vendor source file retrieval / filename
    # parsing scripts into one method.
    Param($VendorName, $Configuration)
    $VendorName = ($VendorName -Replace '"', "")
    switch ($VendorName) {
        "Vendor01" {
            $file = (get-ArchivedFile -FileMask "FILEMASK01.DAT")
        }
        "Vendor02" {
            $file = (get-ZippedFile -FileMask "FILEMASK02" -TargetMask "File")
            $file = (format-VendorFile -VendorName $VendorName -FileMask $file)
        }
        "Vendor03" {
            $file = (get-ZippedFile -FileMask "FILEMASK03" -TargetMask "Mask")
            $file = (format-VendorFile -VendorName $VendorName -FileMask $file)
        }
        Default {
            $file = (get-ArchivedFile -FileMask $Configuration)
        }
    }
    return @($STAGE, $file)
}

function push-File {
    # Push the files to the internal SFTP.
    param($CompanyName, $LocalFile)
    $RemoteDir = "${SERVER}/${CompanyName}"
    $RemoteDir = (format-String -String $RemoteDir)
    $LocalFile = (format-String -String $LocalFile)
    
    & $WINSCP_PROG `
        /log="${BASE}logs\upload_log_${TODAY}.log" /ini=nul `
        /command `
            "open sftp://${USERNAME}:${PASSWORD}@${HOSTNAME}/ -hostkey=`"`"*`"`" -rawsettings FSProtocol=2" `
            "cd `"${RemoteDir}`"" `
            "put -delete `"${LocalFile}`" -resumesupport=off" `
            "exit"
}

# Wrapper for executing everything.
foreach ($c in $CONF.Configurations.Config) {
    $vendor = (format-String -String $c.VendorName) # Fix the vendor name (for other batch scripts).
    $company = (format-String -String $c.CompanyName) # Fix the customer's name.
    $feed_configuration = (get-VendorConfigurations -Company $company -Vendor $vendor) # Get the filemask.
    $file = (get-VendorFile -VendorName $vendor -Configuration $feed_configuration) # Get the file based on the mask.
    $decrypted_file = (decrypt-File -FilePath $file[0] -FileName $file[1]) # Decrypt the file (if needed) and "flatten" the name.
    push-File -CompanyName "Customer01" -LocalFile $decrypted_file # Push the file ot the SFTP.
    gci -Path $STAGE | Remove-Item # Cleanup
}