#Requires -Version 3
Function Test-SqlImportSpeed {
<#
.SYNOPSIS
Demonstrates high performance inserts using PowerShell, Runspaces, and SqlBulkCopy. The secret sauce are batched dataset imports and runspaces within the streamreader.

.DESCRIPTION
This script is intended to demonstrate the efficiency of really cool programming technique. It also proves PowerShell's performance capabilities. It is an accompaniment to
the blog post SqlImportSpeed at netnerds.net

There are three datasets to choose from, long/lat data from geonames.org, customers data from the Chinook sample database, and a really small two column table. Each dataset has exactly 1,000,000 rows and the datasets are realistic; the geonames dataset has 19 columns and customers dataset has 12, all with varied and accurate datatypes.

If the csv files do not reside in the expected location (My Documents), they'll be automatically downloaded. 

By default, Test-SqlImportSpeed creates a database called pssqlbulkcopy, then uploads one dataset to a table called speedtest.

When ran against SQL Server 2014 or greater, it can support memory optimized tables. The actual execution doesn't have a lot of error handling (like SqlBulkCopy itself) because 
that slows stuff down.  The blog post will explain how to troubleshoot.

Warning: This script leaves behind the CSV files it downloads, and the database it created.

THIS CODE IS PROVIDED "AS IS", WITH NO WARRANTIES.

.PARAMETER SqlServer
Required. You must have db creator rights. By default, Windows Authentication is used.

.PARAMETER SqlCredential
Optional. Use SQL Server login instead of Windows Authentication.

.PARAMETER Database
Optional. You can change the database name, but you'll be prompted to confirm unless you use -Force. This is because the script drops and recreates the specified database with
bulk optimized options.

The table name will always be speedtest if you'd like to see the resulting data.

.PARAMETER Dataset
Optional. This script tests against one of three million-row datasets. The default one is longitudes and logitudes data from geonames.org. The second one is a Customer table from the Chinook sample database, stuffed with fake data. The third one, SuperSmall, just has two fields, an int and a varchar(10). This can import 25,335,534 rows/min.

.PARAMETER BatchSize
Optional. Default batchsize is 2000. That's what worked fastest for me.

.PARAMETER MinRunspaces
Optional. Minium Runspaces. Default is 1.

.PARAMETER MaxRunspaces
Optional. Maximum Runspace throttle. Default is 5.

.PARAMETER MemoryOptimized
Optional. Only works on SQL Server 2014 and above. This smokes - I've gotten 184,239 rows a second with this setting. Uses the Customer dataset. 

.PARAMETER Force
Optional. If you use the -Database parameter, it'll warn you that the database will be dropped and recreated, then prompt to confirm. If you use -Force, there will be no prompt.

.NOTES 
Author  : Chrissy LeMaire (@cl), netnerds.net
Requires:     PowerShell Version 3.0, db creator privs on destination SQL Server
DateUpdated: 2016-1-1
Version: 0.6.0

.EXAMPLE   
Test-SqlImportSpeed -SqlServer sqlserver2014a

Imports a million row dataset filled with longitude and latitude data. Once it's downloaded and extracted, you can find it in Documents\longlats.csv

.EXAMPLE   
Test-SqlImportSpeed -SqlServer sqlserver2014a -Dataset Customers

Just another million row dataset, but this one contains a classic customer table. Once it's downloaded and extracted, you can find it in Documents\customers.csv

.EXAMPLE   
$cred = Get-Credential
Test-SqlImport -SqlServer sqlserver2014a -SqlCredential $cred -MinRunspaces 5 -MaxRunspaces 10 -BatchSize 50000

This allows you to login using SQL auth, and sets the MinRunspaces to 5 and the MaxRunspaces to 10. Sets the batchsize to 50000 rows.

#>
[CmdletBinding()] 
param(
	[parameter(Mandatory = $true)]
	[object]$SqlServer,
	[object]$SqlCredential,
	[string]$Database = "pssqlbulkcopy",
	[ValidateSet("Longlats","Customers","SuperSmall")] 
	[string]$Dataset,
	[int]$BatchSize = 2000,
	[int]$MinRunspaces = 1,
	[int]$MaxRunspaces = 5,
	[switch]$MemoryOptimized,
	[switch]$Force
)

BEGIN {
	
	Function Get-SqlDefaultPath {
		$sql = "select SERVERPROPERTY('InstanceDefaultDataPath') as physical_name"
		$cmd.CommandText = $sql
		$filepath = $cmd.ExecuteScalar()
		
		if ($filepath.length -lt 2) {
			$sql = "SELECT physical_name FROM model.sys.database_files where physical_name like '%.mdf'"
			$cmd.CommandText = $sql
			$filepath = $cmd.ExecuteScalar()
			$filepath = Split-Path $filepath
		}
		
		$filepath = $filepath.TrimEnd("\")
		return $filepath
	}
	
	Function Get-SqlVersion {
		$sql = "SELECT SERVERPROPERTY('productversion') as version"
		$cmd.CommandText = $sql
		$sqlversion = $cmd.ExecuteScalar()
		$sqlversion = ([version]$sqlversion).Major
		return $sqlversion 
	}
	
	Function Get-SqlPacketSize {
		$sql = "EXEC sp_configure 'show advanced option', '1'
				RECONFIGURE
				CREATE TABLE #packetsize (name varchar(25),minimum int,maximum int,config int,run int)
				INSERT INTO #packetsize	EXEC sp_configure 'network packet size'
				SELECT run from  #packetsize"
		$cmd.CommandText = $sql
		try { $packetsize = $cmd.ExecuteScalar() } catch { $packetsize = 4096 }
		return $packetsize 
	}

	Function Restore-TestDb {
		if ($memoryOptimized -eq $true) {
			$defaultpath = Get-SqlDefaultPath  $conn
			$mosql = "ALTER DATABASE [$database] ADD FILEGROUP [memoptimized] CONTAINS MEMORY_OPTIMIZED_DATA
					  ALTER DATABASE [pssqlbulkcopy] ADD FILE ( NAME = N'pssqlbulkcopy_mo', FILENAME = N'$defaultpath\$database_mo.ndf' ) TO FILEGROUP [memoptimized]"
		}
	
		$sql = "IF  EXISTS (SELECT name FROM master.dbo.sysdatabases WHERE name = N'$database')
				BEGIN
					ALTER DATABASE [$database] SET  SINGLE_USER WITH ROLLBACK IMMEDIATE
					DROP DATABASE [$database]
				END
				CREATE DATABASE  [$database]
				ALTER DATABASE [$database] MODIFY FILE ( NAME = N'$database', SIZE = 20GB )
				$mosql

				ALTER DATABASE [$database] SET RECOVERY SIMPLE WITH NO_WAIT
				ALTER DATABASE [$database] SET PAGE_VERIFY NONE
				ALTER DATABASE [$database] SET AUTO_UPDATE_STATISTICS OFF
				ALTER DATABASE [$database] SET AUTO_CREATE_STATISTICS OFF"
		Write-Verbose $sql
		$cmd.CommandText = $sql
		try {
			$cmd.ExecuteNonQuery() > $null
		} catch {
			throw $_.Exception.Message.ToString()
		}
	}
	
	Function New-Table {
		$conn.ChangeDatabase($database)
		
		switch ($dataset) {
			"supersmall" {
							if ($memoryOptimized -eq $true) {
								$sql = "CREATE TABLE[dbo].[speedtest](id int INDEX ix_cid NONCLUSTERED NOT NULL, data varchar(10))"
							} else {
								$sql = "CREATE TABLE[dbo].[speedtest](id int, data varchar(10))"
							}
			}
			"customers" {
							if ($memoryOptimized -eq $true) {
								$customerid = "[CustomerId] int INDEX ix_cid NONCLUSTERED NOT NULL,"
								$with = "WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_ONLY)"
							} else {
								$customerid = "[CustomerId] int,"
							}
							
							$sql = "CREATE TABLE[dbo].[speedtest](
							$customerid
							[FirstName] [nvarchar](40) NOT NULL,
							[LastName] [nvarchar](20) NOT NULL,
							[Company] [nvarchar](80) NULL,
							[Address] [varchar](70) NULL,
							[City] [nvarchar](40) NULL,
							[State] [varchar](40) NULL,
							[Country] [varchar](40) NULL,
							[PostalCode] [nvarchar](10) NULL,
							[Phone] [nvarchar](24) NULL,
							[Fax] [nvarchar](24) NULL,
							[Email] [nvarchar](60) NOT NULL
						) $with"
						}
			"longlats" {
					$sql = "CREATE TABLE [dbo].[speedtest](
						[GeoNameId] [int],
						[Name] [nvarchar](200),
						[AsciiName] [nvarchar](200),
						[AlternateNames] [nvarchar](max),
						[Latitude] [float],
						[Longitude] [float],
						[FeatureClass] [char](1),
						[FeatureCode] [varchar](10),
						[CountryCode] [char](2),
						[Cc2] [varchar](255),
						[Admin1Code] [varchar](20),
						[Admin2Code] [varchar](80),
						[Admin3Code] [varchar](20),
						[Admin4Code] [varchar](20),
						[Population] [bigint],
						[Elevation] [varchar](255),
						[Dem] [int],
						[Timezone] [varchar](40),
						[ModificationDate] [smalldatetime]
					)"
			}
			
		}
		
		Write-Verbose $sql
		$cmd.CommandText = $sql

		try { $cmd.ExecuteNonQuery() > $null} 
		catch { throw $_.Exception.Message.ToString() }
	}
}

PROCESS {
	
	# Ensure Longlats dataset isn't selected if -MemoryOptimized is set
	if ($dataset.length -eq 0 -and $memoryOptimized -eq $false) { $dataset =  "Longlats" }
	if ($dataset.length -eq 0 -and $memoryOptimized -eq $true) { $dataset =  "Customers" }

	# Show warning if db name is not pssqlbulkcopy and -Force was not specified
	if ($database -ne "pssqlbulkcopy" -and $force -eq $false) {
		$message = "This script will drop the database '$database' and recreate it."
		$question = "Are you sure you want to continue?"
		$choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
		$choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
		$choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))
		
		$decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
		if ($decision -eq 1) { return }
	}

	# Create Connection String
	if ($SqlCredential.count -eq 0) {
			$connectionString = "Data Source=$sqlserver;Integrated Security=True;Connection Timeout=3;Initial Catalog=master"
	} else {
			$username = ($SqlCredential.UserName).TrimStart("\")
			$connectionString = "Data Source=$sqlserver;User Id=$($username); Password=$($SqlCredential.GetNetworkCredential().Password);Connection Timeout=3;Initial Catalog=master"
	}
	
	# Build the SQL Server Connection
	try {
		$conn = New-Object System.Data.SqlClient.SqlConnection
		$conn.ConnectionString = $connectionString
		$conn.Open()
	} catch {
		$message = $_.Exception.Message.ToString()
		Write-Verbose $message
		if ($message -match "A network") { $message = "Can't connect to $sqlserver." }
		elseif ($message -match "Login failed for user") { $message = "Login failed for $username." }
		throw $message
	}
	
	# Build the SQL Server Command
	$cmd = New-Object System.Data.SqlClient.SqlCommand
	$cmd.Connection = $conn
	
	# If -MemoryOptimized is specified, ensure the SQL Server supports it.
	if ($memoryOptimized -eq $true) {
		if ($dataset -eq "Longlats") { throw "In-Memory testing can only be performed with the Customers dataset"}
		$sqlversion = Get-SqlVersion $conn
		if ($sqlversion -lt 12) { throw "In-Memory OLTP is only supported in SQL Server 2014 and above" }
		$bulkoptions = "Default"
	} else { $bulkoptions = "TableLock" }
	
	Write-Output "Dropping and recreating database $database. This ensures that the database has optimized properties."
	Restore-TestDb
	
	Write-Output "Creating table speedtest"
	New-Table
	
	# Check network packetsize. This doesn't make a big impact for me but it may in other environments.
	$packetsize = Get-SqlPacketSize
	if ($packetsize -ne 4096) {
		Write-Output "Changing connectionstring's default packet size to match SQL Server: $packetsize"
		$conn.Close()
		$connectionString = "$connectionString;Packet Size=$packetsize"
		$conn.ConnectionString = $connectionString
		$conn.Open()
		$cmd.Connection = $conn
	}
	
	# Set dataset info
	if ($dataset -eq "Longlats") {
		$csvfile = "$([Environment]::GetFolderPath('MyDocuments'))\longlats.csv"
		$onedriveurl = "http://1drv.ms/1JgLnC6"
	} elseif ($dataset -eq "supersmall") {
		$csvfile = "$([Environment]::GetFolderPath('MyDocuments'))\supersmall.csv"
		$onedriveurl = "http://1drv.ms/1YRAjCM"
	} else {
		$csvfile = "$([Environment]::GetFolderPath('MyDocuments'))\customers.csv"
		$onedriveurl = "http://1drv.ms/1kvOtqc"
	}
	
	# Check for CSV
	if ((Test-Path $csvfile) -eq $false) {
		Write-Output "Going grab the CSV zip file from OneDrive."
		Write-Output "This will only happen once unless $csvfile is deleted."
		Write-Output "Unfortunately there's no progress bar."
		Write-Output "Invoke-WebRequest has one but it drastically slows the transfer and Start-BitsTransfer doesn't work."
		Add-Type -Assembly "System.Io.Compression.FileSystem"
		$zipfile = "$([Environment]::GetFolderPath('MyDocuments'))\pssqlbulkinsert-speedtest.zip"
		$WebClient = New-Object System.Net.WebClient
		$WebClient.DownloadFile($onedriveurl,$zipfile)
		Write-Output "Download complete. Unzipping."
		[Io.Compression.ZipFile]::ExtractToDirectory($zipfile, [Environment]::GetFolderPath('MyDocuments'))
		Remove-Item $zipfile
	}
	
<#

	Data processing section

#>

	# Setup datatable since SqlBulkCopy.WriteToServer can consume it
	$datatable = New-Object System.Data.DataTable
	$columns = (Get-Content $csvfile -First 1).Split("`t") 
	foreach ($column in $columns) { 
		$null = $datatable.Columns.Add()
	}

	# Update connection string for bulkinsert
	$connectionString = $connectionString -Replace "master", $database
	
	# Setup runspace pool and the scriptblock that runs inside each runspace
	$pool = [RunspaceFactory]::CreateRunspacePool($MinRunspaces,$MaxRunspaces)
	#$pool.ApartmentState = "MTA"
	$pool.Open()
	$jobs = @()
	
	# This is the workhorse.
	$scriptblock = {
	   Param (
		[string]$connectionString,
		[object]$dtbatch,
		[string]$bulkoptions,
		[int]$batchsize
		  
	   )
	   
		$bulkcopy = New-Object Data.SqlClient.SqlBulkCopy($connectionstring,$bulkoptions)
		$bulkcopy.DestinationTableName = "speedtest"
		$bulkcopy.BatchSize = $batchsize
		$bulkcopy.WriteToServer($dtbatch)
		$bulkcopy.Close()
		$dtbatch.Clear()
		$bulkcopy.Dispose()
		$dtbatch.Dispose()
	}

	Write-Output "Starting insert. Timer begins now."
	$elapsed = [System.Diagnostics.Stopwatch]::StartNew()

	# Use StreamReader to process csv file. Efficiently add each row to the datatable.
	# Once batchsize is reached, send it off to a runspace to be processed, then create a new datatable.
	# so that the one in the runspace doesn't get altered. Thanks Dave Wyatt for that suggestion!
	 
	$reader = New-Object System.IO.StreamReader($csvfile)

	while (($line = $reader.ReadLine()) -ne $null)  {
		$null = $datatable.Rows.Add($line.Split("`t"))
		
		if ($datatable.rows.count % $batchsize -eq 0) {
		   $job = [PowerShell]::Create()
		   $null = $job.AddScript($scriptblock)
		   $null = $job.AddArgument($connectionString)
		   $null = $job.AddArgument($datatable)
		   $null = $job.AddArgument($bulkoptions)
		   $null = $job.AddArgument($batchsize)
		   $job.RunspacePool = $pool
		   $jobs += [PSCustomObject]@{ Pipe = $job; Status = $job.BeginInvoke() }
		   
		   # So good
		   $datatable = New-Object System.Data.DataTable
		   foreach ($column in $columns) { $datatable.Columns.Add() > $null }
		}
	}

	$reader.close()

	# Process any remaining rows
	if ($datatable.rows.count -gt 0) {
		$bulkcopy = New-Object Data.SqlClient.SqlBulkCopy($connectionstring)
		$bulkcopy.DestinationTableName = "speedtest"
		$bulkcopy.BulkCopyTimeout = 0
		$bulkcopy.WriteToServer($datatable)
		$bulkcopy.Close()
		$datatable.Clear()
	}

	# Wait for runspaces to complete
	while ($jobs.Status.IsCompleted -notcontains $true) {}
	$secs = $elapsed.Elapsed.TotalSeconds
	
	# if you'd like to see any resulting errors, uncomment this section, and add a return $error[0] after $dtbatch.Dispose() on line 360.
	# Don't forget to comment out the subsequent foreach statement
	<#
	$errors = @()
	foreach ($job in $jobs) { $results += $job.Pipe.EndInvoke($job.Status) }
	$errors 
	#>
	
	foreach ($job in $jobs ) { 
		$null = $job.Pipe.EndInvoke($job.Status)
		$job.Pipe.Dispose()
	}
	
	$pool.Close() 
	$pool.Dispose()
	
}

END {
	
	if ($secs -gt 0) {
		# verylarge (25 million row) dataset coming soon
		if ($dataset -eq "verylarge") { $total = 25000000 } else { $total = 1000000}
		# Write out stats for million row csv file
		$rs = "{0:N0}" -f [int]($total / $secs)
		$rm = "{0:N0}" -f [int]($total / $secs * 60)
		$mill = "{0:N0}" -f $total
		Write-Output "$mill rows imported in $([math]::round($secs,2)) seconds ($rs rows/sec and $rm rows/min)"	
		if ($dataset -eq "verylarge") { Write-Output "Ypu can now run '1..3 | foreach { [System.GC]::Collect() }' to clear memory." }
	}
}

}