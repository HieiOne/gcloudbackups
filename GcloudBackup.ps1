# Name: Gcloud Backup
# Author: Alex López <arendevel@gmail.com>
# Contributor: Iván Blasco
# Version: 9.4b
# Veeam Backup And Replication V: 10+

########## Var & parms declaration #####################################################
param(
    [Parameter(Mandatory = $false)][switch]$all         = $false,
	[Parameter(Mandatory = $false)][switch]$clean		= $false, 
	[Parameter(Mandatory = $false)][switch]$removeOld	= $false,
	[Parameter(Mandatory = $false)][switch]$dryRun		= $false, # This will cause script to run without making any changes
	[Parameter(Mandatory = $false)][switch]$unattended	= $false, # Turn this flag on if script is going tu run unattended
	[Parameter(Mandatory = $false)][switch]$genCreds 	= $false  # Generate credentials only
	)
	
Push-Location (Split-Path -Path $MyInvocation.MyCommand.Definition -Parent)

$confFile = ".\GcloudConf.ps1"

# Conf loading
try {
	if (Test-Path $confFile) {
		. $confFile
	}
	else {
		Write-Host 'Configuration file not found, please reinstall!' -fore red -back black
		exit 1
	}
}
catch {
	Write-Host "Please, check your configuration file, there's something incorrect in it. " -fore red -back black
	exit 1
}
#########################################################################################

function getTime() {
	return Get-Date -UFormat "%d-%m-%Y @ %H:%M"
}

function createFolder($path) {
	
	try {
		mkdir "$path" -ErrorAction Continue 2>&1> $null
	}
	catch {
		continue
	}
	
}

function chkCredentials() {
	return (Test-Path -Path $usrFile) -and (Test-Path -Path $pwFile)
}

function genCredentials() {
	
	createFolder $credDir
	
	$creds = (Get-Credential)
	
	$creds.UserName | Out-File $usrFile
	$creds.Password | ConvertFrom-SecureString | Out-File $pwFile
	
	Write-Host "Credentials generated succesfully!" -fore green -back black
}

function getCredentials() {
	return  New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList (Get-Content $usrFile), (Get-Content $pwFile | ConvertTo-SecureString)
}

function mailLogs($jobType, $server, $startedTime, $endTime, $attachment) {
    
    $chkCredentials = chkCredentials	

	if (!$chkCredentials){
		
		if ($unattended) {
			echo "Credentials not found, please run this script again in interactive mode (No unattended flag activated) to generate them." 1> $credErrorLog
			echo "Notice that whilst you do NOT delete '$credDir' your credentials will be safely secured with Windows Data Protection API (DPAPI) which can only be used in this machine." 1>> $credErrorLog
			return $false # Creds not found and running in 'unattended mode' so we cannot send the email
		}
		else {
			Write-Host "Credentials not found, please introduce your login information." -fore yellow -back black
			Write-Host "Notice that whilst you do NOT delete '$credDir' your credentials will be safely secured with Windows Data Protection API (DPAPI) which can only be used in this machine." -fore blue -back black
			genCredentials
		}				
		
		
	}
	
	# Mail Setup
	$cred = getCredentials
	$EmailTo = $mailTo
	$EmailFrom = $cred.UserName
	
	if ($jobType -eq "upload") {
		$Subject = "[Completed] Gcloud Backups - $server" 
		$Body = "Salutations master, <br><br>Google Cloud '$server' upload job which started at $startedTime --> Finished at $endTime<br><br>Greetings, <br><br> <strong>Your automated, Gcloud Backup script.</strong>" 
	}
	elseif ($jobType -eq "remove") {
		$Subject = "[Completed] Gcloud Backups - Removing old cloud backups"
		$Body = "Salutations master, <br><br>Google Cloud 'Removing old backup files' job which started at $startedTime --> Finished at $endTime<br><br>Greetings, <br><br> <strong>Your automated, Gcloud Backup script.</strong>" 
	}
	elseif ($jobType -eq "sendErrorLog") {
		$Subject = "[Failed] Gcloud Backups - $server"
		$Body = "Bad news master, <br><br>Something just broke. I attach the error file.<br><br>Greetings, <br><br> <strong>Your automated, Gcloud Backup script.</strong>" 
	}

	# SMTP Server Setup 
	$SMTPServer = "smtp.gmail.com" 

	# SMTP Message
	$SMTPMessage = New-Object System.Net.Mail.MailMessage($EmailFrom,$EmailTo,$Subject,$Body)
	$SMTPMessage.isBodyHTML = $true
	
	if (! [string]::IsNullOrEmpty($attachment)) {
		$attachThis = new-object Net.Mail.Attachment($attachment) 
		$SMTPMessage.Attachments.Add($attachThis)
	}

	# SMTP Client Setup
	$SMTPClient = New-Object Net.Mail.SmtpClient($SmtpServer, 587) 
	$SMTPClient.EnableSsl = $true
	$SMTPClient.Credentials = New-Object System.Net.NetworkCredential($cred.UserName, $cred.Password); 
	$SMTPClient.Send($SMTPMessage)
	
	return $true
	
}

function sendErrorLog($subject, $errorLogFile) {
	
	if (Test-Path $errorLogFile) {
	
		$fileContents = Get-Content $errorLogFile
		
		if (! [string]::isNullOrEmpty($fileContents)) {
			$ret = mailLogs "sendErrorLog" $subject "" "" $errorLogFile
		}
		
	}
	
	return $ret
	
}

function autoClean() {

		$currYear = Get-Date -UFormat "%Y"
		$prevYear = $currYear - 1	
		
		&{
			if ($dryRun) {
				echo "Running in 'dryRun' mode: No changes will be made."
			}
				
			$timeNow = getTime
			echo ("Autocleaning started at " + $timeNow)
			
			if (!$dryRun) {
				rm "$logDir\*$prevYear*"
			}
				
			$timeNow = getTime
			echo ("Autocleaning finished at " + $timeNow)
			
		} 2>> $errorLog 1>> $logFile
		
		
}


function removeOldBackups() {
	
	$lastWeek = (Get-Date (Get-Date).AddDays($daysToKeepBK * (-1)) -UFormat "%Y%m%d") # Cambiamos a negativo el $daysToKeepBK para restar dias
	
	$files = @(gsutil -m ls -R "$serverPath" | Select-String -Pattern "\..*$")
	
	if (! [string]::IsNullOrEmpty($files)) { 
	
		$timeNow = getTime
	    $startedTime = $timeNow
		echo ("Removing old backup files' job started at " + $timeNow) 1>> $logFile
				
		&{
			if ($dryRun) {
				echo "Running in 'dryRun' mode: No changes will be made."
			}
		
			foreach ($file in $files) {
				
				$fileName = ($file -Split "/")[-1]				
				$fileExt  = ($fileName -Split "\.")[-1]
				
				if ($fileExt -ne "vbm") {
					# We skip '.vbm' files since they are always the same and don't have date on it					
					
					$fileDate = ($file -replace '[\D]').substring(0,8)												
							
							if ($fileDate -lt $lastWeek) {
								echo "The file: '$fileName' is older than $daysToKeepBK days... Wiping out!"
													
								if (!$dryRun) {				
									gsutil -m -q rm -a "$file" # -m makes the operation multithreaded. -q causes gsutil to be quiet, basically: No progress reporting, only errors
								}
							}											
					}
				 
			}
			
		} 2>> $removeErrorLog 1> $removeLogFile
		
		
		$timeNow = getTime
	    echo ("Removing old backup files' job finished at " + $timeNow) 1>> $logFile 
		
		if ($isMailingOn) {
			$isMailingOn = mailLogs "remove" "" $startedTime $timeNow $removeLogFile
		}
	}
	else {echo "Could not get the files" 1>> $errorLog}
	
}


function doUpload() {

	# We wrap all the code so we can send all the stdout and stderr to files in a single line
	&{
		if ($dryRun) {
				echo "Running in 'dryRun' mode: No changes will be made."
		}
		
		$timeNow = getTime
		echo ("Uploading Backups to Gcloud... Job started at " + $timeNow)

		foreach ($path in $backupPaths) {
			
			$dirName = $path -replace '.*\\'
			
			$timeNow = getTime
			echo ("Uploading $dirName to Gcloud... Job started at " + $timeNow)
			
			$startedTime = $timeNow
						
			createFolder "$logDir\$dateLogs"
			
			if (!$dryRun) {
				# Changed back to rsync because copy does copy all the files whether they are changed or not
				# But now, -d option is skipped since we deal with the old backup files manually with removeOldBackups
				
				if($useCygWin -eq $true) # We run the CygWin implementation
				{
					if (Test-Path $CygWinBash -PathType Leaf)
					{
						$cygWinPath = $path -replace "\\","/" # Convert to UNIX path
						& $CygWinBash --login -c "$CygWinSDKPath/gsutil -m -q rsync -r  ""$cygWinPath"" ""$serverPath/$dirName"" " 2>&1 | Out-Host
					}
					else 
					{
						echo "CygWin bash file doesn't exist, incorrect path" 1>> $errorLog
					}
				}
				else 
				{
					gsutil -m -q rsync -r "$path" "$serverPath/$dirName"
				}
			}
			
			$timeNow = getTime
			echo ("Uploading $dirName to Gcloud... Job finished at " + $timeNow)
			
			if ($isMailingOn) {
				$isMailingOn = mailLogs "upload" $dirName $startedTime $timeNow # In case that sending email fails, we switch off the mailing option until script is restarted
			}
			
		}

		$timeNow = getTime
		echo ("Uploading Backups to Gcloud... Job finished at " + $timeNow)

	}  2>> $errorLog 1>> $logFile
	
	if ($isMailingOn) {
		$isMailingOn = sendErrorLog "Upload job" $errorLog
	}
}

try {
	if ($clean) {
		createFolder "$logDir\$dateLogs"
		autoClean
	} 
	elseif ($removeOld) {
		createFolder "$logDir\$dateLogs"
		removeOldBackups
	}
	elseif ($All) {
		createFolder "$logDir\$dateLogs"
		autoClean
		doUpload
		removeOldBackups
	}
	elseif ($genCreds) {
		genCredentials
	}
	else {
		createFolder "$logDir\$dateLogs"
		doUpload
	}
}
catch [System.IO.DirectoryNotFoundException] {
	Write-Host 'Please, check that file paths are well configured' -fore red -back black
}
