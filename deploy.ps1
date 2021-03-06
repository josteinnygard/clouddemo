﻿#Requires -Version 3
Param(
        [string] $ResourceGroupName,

        [ValidateSet('West Europe','North Europe','East US','East US 2','Central US','North Central US','South Central US','West Central US','West US','West US 2')]
        [string]
        $ResourceGroupLocation = 'West Europe',

        [string] $MGMTResourceGroupName

    )
	
#region Login to Azure
$RMContext = Get-AzureRmContext -ErrorAction SilentlyContinue
if (!$RMContext)
{
    Login-AzureRmAccount
}
#endregion

#region Pick Subscription/TenantID
$AzureInfo = 
    (Get-AzureRmSubscription `
        -ErrorAction Stop |
     Out-GridView `
        -Title 'Select a Subscription/Tenant ID for deployment...' `
        -PassThru)

# Select Subscription
Select-AzureRmSubscription `
    -SubscriptionId $AzureInfo.SubscriptionId `
    -TenantId $AzureInfo.TenantId `
    -ErrorAction Stop| Out-Null
#endregion

#Try Catch block for deployment
Try {
	#region Main Template
	[string] $TemplateFile = '\project\AzureFoundationLite\azuredeploy.json'
	[string] $TemplateParametersFile = '\project\AzureFoundationLite\azuredeploy.parameters.json'
	[string] $AzCopyPath = 'project\AzureFoundationLite\Tools\AzCopy.exe'
	[string] $NestedTempaltes = 'project\AzureFoundationLite\nested'
	[string] $DSCSourceFolder = 'project\AzureFoundationLite\dsc'
	$OptionalParameters = New-Object -TypeName Hashtable
	$TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath $TemplateFile
	$TemplateParametersFile = Join-Path -Path $PSScriptRoot -ChildPath $TemplateParametersFile
	$DSCSourceFolder = Join-Path -Path $PSScriptRoot -ChildPath $DSCSourceFolder
	$NestedFolder = Join-Path -Path $PSScriptRoot -ChildPath $NestedTempaltes
	Set-Variable -Name ArtifactsLocationName -Value '_artifactsLocation' -Option ReadOnly -Force
	Set-Variable -Name ArtifactsLocationSasTokenName -Value '_artifactsLocationSasToken' -Option ReadOnly -Force
	$OptionalParameters.Add($ArtifactsLocationName, $null)
	$OptionalParameters.Add($ArtifactsLocationSasTokenName, $null)

	$AzCopyPath = Join-Path -Path $PSScriptRoot -ChildPath $AzCopyPath
	#endregion

	#region MGMT template variables
	[string] $TemplateFileMGMT = '\project\AzureFoundationLite\azuredeploymanagement.json'
	[string] $TemplateParametersFileMGMT = '\project\AzureFoundationLite\azuredeploymanagement.parameters.json'
	[string] $RunbooksSourceFolder = 'project\AzureFoundationLite\runbooks'
	$OptionalParametersMGMT = New-Object -TypeName Hashtable
	$TemplateFileMGMT = Join-Path -Path $PSScriptRoot -ChildPath $TemplateFileMGMT
	$TemplateParametersFileMGMT = Join-Path -Path $PSScriptRoot -ChildPath $TemplateParametersFileMGMT
	$RunbooksSourceFolder  = Join-Path -Path $PSScriptRoot -ChildPath $RunbooksSourceFolder

	$OptionalParametersMGMT.Add($ArtifactsLocationName, $null)
	$OptionalParametersMGMT.Add($ArtifactsLocationSasTokenName, $null)

	#endregion

	#region Diagnostics template variables
	[string] $TemplateFileDiag = '\project\AzureFoundationLite\azuredeployvmdiagnostics.json'
	[string] $TemplateParametersFileDiag = '\project\AzureFoundationLite\azuredeployvmdiagnostics.parameters.json'
	$OptionalParametersDiag = New-Object -TypeName Hashtable
	$TemplateFileDiag = Join-Path -Path $PSScriptRoot -ChildPath $TemplateFileDiag
	$TemplateParametersFileDiag = Join-Path -Path $PSScriptRoot -ChildPath $TemplateParametersFileDiag
	#endregion

	#region Create Main Resource Group
	Try
	{
		Get-AzureRmResourceGroup -Name $ResourceGroupName `
								 -Location $ResourceGroupLocation `
								 -ErrorAction Stop
	}
	Catch
	{
		New-AzureRmResourceGroup -Name $ResourceGroupName `
								 -Location $ResourceGroupLocation `
								 -Force `
								 -ErrorAction Stop
	}
	#endregion

	#region Create Temporary storage account and container
	# to store nested tempaltes and DSC cofigs

	$EnvUserName = ($Env:UserName).replace(' ','')
	$EnvUserName = $EnvUserName.substring(0, [Math]::Min(8, $EnvUserName.Length))
	$StorageAccountName = (($ResourceGroupName.substring(0, [Math]::Min(6, $ResourceGroupName.Length))) + $EnvUserName + 'articfacts' ).ToLower()
	Try
	{
		Get-AzureRmStorageAccount -ResourceGroupName $ResourceGroupName  `
								  -Name $StorageAccountName `
								  -ErrorAction Stop
	}
	Catch
	{
		New-AzureRmStorageAccount -ResourceGroupName $ResourceGroupName `
								  -Name $StorageAccountName `
								  -SkuName Standard_LRS `
								  -Location $ResourceGroupLocation `
								  -ErrorAction Stop | Out-Null
	}

	$StorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName)[0].Value
	$StorageAccountContext = (Get-AzureRmStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName).Context
	$StorageContainerName = $ResourceGroupName.ToLowerInvariant() + '-stageartifacts'

	Try
	{
		Get-AzureStorageContainer -Name $StorageContainerName `
								  -Context $StorageAccountContext `
								  -ErrorAction Stop
	}
	Catch
	{
		New-AzureStorageContainer -Name $StorageContainerName `
								  -Permission Off `
								  -Context $StorageAccountContext `
								  -ErrorAction Stop | Out-Null
	}

	#endregion

	#region Upload nested templates and dscconfigs to Storage container
	$StorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName)[0].Value
	$StorageAccountContext = (Get-AzureRmStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName).Context

	$ArtifactsLocation = $StorageAccountContext.BlobEndPoint + $StorageContainerName

	# Use AzCopy to copy nested templates
	& $AzCopyPath """$NestedFolder""", $ArtifactsLocation, "/DestKey:$StorageAccountKey", '/S', '/Y', "/Z:$env:LocalAppData\Microsoft\Azure\AzCopy\$ResourceGroupName"
	if ($LASTEXITCODE -ne 0) { return }

	# Use AzCopy to copy dsc configs
	& $AzCopyPath """$DSCSourceFolder""", $ArtifactsLocation, "/DestKey:$StorageAccountKey", '/S', '/Y', "/Z:$env:LocalAppData\Microsoft\Azure\AzCopy\$ResourceGroupName"
	if ($LASTEXITCODE -ne 0) { return }

	# Use AzCopy to copy runbooks
	& $AzCopyPath """$RunbooksSourceFolder""", $ArtifactsLocation, "/DestKey:$StorageAccountKey", '/S', '/Y', "/Z:$env:LocalAppData\Microsoft\Azure\AzCopy\$ResourceGroupName"
	if ($LASTEXITCODE -ne 0) { return }
	#endregion

	#region Create a SAS token for the storage container
	# this gives temporary read-only access to the container
	$ArtifactsLocationSasToken = New-AzureStorageContainerSASToken -Container $StorageContainerName `
																   -Context $StorageAccountContext `
																   -Permission r `
																   -ExpiryTime (Get-Date).AddHours(8) `
																   -ErrorAction Stop
	#endregion

	#region Main and MGMT Template Construct Optional paremeters for Artificats location and sas token
	$OptionalParameters[$ArtifactsLocationName] = $ArtifactsLocation
	$OptionalParametersMGMT[$ArtifactsLocationName] = $ArtifactsLocation
	$ArtifactsLocationSasToken = ConvertTo-SecureString -String $ArtifactsLocationSasToken -AsPlainText -Force
	$OptionalParameters[$ArtifactsLocationSasTokenName] = $ArtifactsLocationSasToken
	$OptionalParametersMGMT[$ArtifactsLocationSasTokenName] = $ArtifactsLocationSasToken
	#endregion

	#region Start Main Template Deployment
	New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem -Path $TemplateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
									   -ResourceGroupName $ResourceGroupName `
									   -TemplateFile $TemplateFile `
									   -TemplateParameterFile $TemplateParametersFile `
									   @OptionalParameters `
									   -Force -Verbose -ErrorAction Stop
	#endregion

	#region Create MGMT Resource Group
	Try
	{
		Get-AzureRmResourceGroup -Name $MGMTResourceGroupName `
								 -Location $ResourceGroupLocation `
								 -ErrorAction Stop
	}
	Catch
	{
		New-AzureRmResourceGroup -Name $MGMTResourceGroupName `
								 -Location $ResourceGroupLocation `
								 -Force `
								 -ErrorAction Stop
	}
	#endregion

	#region Parameters for MGMT Template Deployment
	# Set omsRecoveryServicesVaultLocation parameter
	Set-Variable -Name omsRecoveryServicesVaultLocation -Value 'omsRecoveryServicesVaultLocation' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($omsRecoveryServicesVaultLocation, $ResourceGroupLocation)

	# Set runbookJobIdSetRecoveryVaultStorage parameter
	$GUID = (New-guid).Guid.ToString()
	Set-Variable -Name runbookJobIdSetRecoveryVaultStorage -Value 'runbookJobIdSetRecoveryVaultStorage' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($runbookJobIdSetRecoveryVaultStorage, $GUID)

	# Set backupScheduleRunTime parameter / You can change the default value of 02:00 local time if needed
	$cultureSet = New-Object -TypeName System.Globalization.CultureInfo -ArgumentList ('en-US')
	[string]$backupScheduleRunTimeValue = ([datetime]'02:00').ToUniversalTime().ToString('HH:mm',$cultureSet)
	Set-Variable -Name backupScheduleRunTime -Value 'backupScheduleRunTime' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($backupScheduleRunTime, $backupScheduleRunTimeValue)

	# Set dailyRetentionDurationCount parameter
	Set-Variable -Name dailyRetentionDurationCount -Value 'dailyRetentionDurationCount' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($dailyRetentionDurationCount, 180)

	# Read Main Template Parameters file
	$azureDeployParams = Get-Content -Path $TemplateParametersFile | ConvertFrom-Json

	# Set adVmName parameter
	$adVMValue = $azureDeployParams.parameters.adVmName.value
	Set-Variable -Name adVmName -Value 'adVmName' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($adVmName, $adVMValue)

	# Set adVmResourceGroupName parameter
	Set-Variable -Name adVmResourceGroupName -Value 'adVmResourceGroupName' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($adVmResourceGroupName, $ResourceGroupName)

	# Set rdsVmName parameter
	$rdsVMValue = $azureDeployParams.parameters.rdsVmName.value
	Set-Variable -Name rdsVmName -Value 'rdsVmName' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($rdsVmName, $rdsVMValue)

	# Set rdsVmResourceGroupName parameter
	Set-Variable -Name rdsVmResourceGroupName -Value 'rdsVmResourceGroupName' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($rdsVmResourceGroupName, $ResourceGroupName)

	# Set appVmName parameter
	$appVMValue = $azureDeployParams.parameters.appVmName.value
	Set-Variable -Name appVmName -Value 'appVmName' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($appVmName, $appVMValue)

	# Set appVmResourceGroupName parameter
	Set-Variable -Name appVmResourceGroupName -Value 'appVmResourceGroupName' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($appVmResourceGroupName, $ResourceGroupName)

	# Set domainName parameter
	$domainNameValue = $azureDeployParams.parameters.domainName.value
	Set-Variable -Name domainName -Value 'domainName' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($domainName, $domainNameValue)

	# Set domainUsername parameter
	$domainUsernameValue = $azureDeployParams.parameters.domainUsername.value
	Set-Variable -Name domainUsername -Value 'domainUsername' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($domainUsername, $domainUsernameValue)

	# Set domainPassword parameter
	$domainPasswordValue = $azureDeployParams.parameters.domainPassword.value
	$domainPasswordValueSS = ConvertTo-SecureString -String $domainPasswordValue -AsPlainText -Force
	Set-Variable -Name domainPassword -Value 'domainPassword' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($domainPassword, $domainPasswordValueSS)

	# Set localAdminUsername parameter
	$localAdminUsernameValue = $azureDeployParams.parameters.localAdminUsername.value
	Set-Variable -Name localAdminUsername -Value 'localAdminUsername' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($localAdminUsername, $localAdminUsernameValue)

	# Set localAdminPassword parameter
	$localAdminPasswordValue = $azureDeployParams.parameters.localAdminPassword.value
	$localAdminPasswordValueSS = ConvertTo-SecureString -String $localAdminPasswordValue -AsPlainText -Force
	Set-Variable -Name localAdminPassword -Value 'localAdminPassword' -Option ReadOnly -Force
	$OptionalParametersMGMT.Add($localAdminPassword, $localAdminPasswordValueSS)
	#endregion

	#region Start MGMT Template Deployment
	New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem -Path $TemplateFileMGMT).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
									   -ResourceGroupName $MGMTResourceGroupName `
									   -TemplateFile $TemplateFileMGMT `
									   -TemplateParameterFile $TemplateParametersFileMGMT `
									   @OptionalParametersMGMT `
									   -Force `
									   -Verbose `
									   -ErrorAction Stop `
									   -OutVariable MGMTOutput
	#endregion


	#region Diagnostics Templates Deployment
	# Get Diagnostics Storage account from MGMT Template output
	[string]$diagStorageAccountName = $MGMTOutput[0].Outputs.Get_Item('diagStorageAccountName').Value

	If ([string]::IsNullOrEmpty($diagStorageAccountName))
	{
		Write-Error -Message 'Diagnostics account is not created.' -ErrorAction Stop
	}
	Else
	{
		# Set existingdiagnosticsStorageAccountName parameter
		Set-Variable -Name existingdiagnosticsStorageAccountName -Value 'existingdiagnosticsStorageAccountName' -Option ReadOnly -Force
		$OptionalParametersDiag.Add($existingdiagnosticsStorageAccountName, $diagStorageAccountName)

		# Set existingdiagnosticsStorageAccountName parameter
		Set-Variable -Name existingdiagnosticsStorageAccountResourceGroup -Value 'existingdiagnosticsStorageAccountResourceGroup' -Option ReadOnly -Force
		$OptionalParametersDiag.Add($existingdiagnosticsStorageAccountResourceGroup, $MGMTResourceGroupName)

		# Set vmName parameter
		Set-Variable -Name vmName -Value 'vmName' -Option ReadOnly -Force
		$OptionalParametersDiag.Add($vmName, $adVMValue)

		# Diagnostics Template Deployment
		New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem -Path $TemplateFileDiag).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
										   -ResourceGroupName $ResourceGroupName `
										   -TemplateFile $TemplateFileDiag `
										   -TemplateParameterFile $TemplateParametersFileDiag `
										   @OptionalParametersDiag `
										   -Force -Verbose -ErrorAction Stop

		# Set vmName parameter
		Set-Variable -Name vmName -Value 'vmName' -Option ReadOnly -Force
		$OptionalParametersDiag.Remove($vmName)
		$OptionalParametersDiag.Add($vmName, $rdsVMValue)

		# Diagnostics Template Deployment
		New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem -Path $TemplateFileDiag).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
										   -ResourceGroupName $ResourceGroupName `
										   -TemplateFile $TemplateFileDiag `
										   -TemplateParameterFile $TemplateParametersFileDiag `
										   @OptionalParametersDiag `
										   -Force -Verbose -ErrorAction Stop

		# Set vmName parameter
		Set-Variable -Name vmName -Value 'vmName' -Option ReadOnly -Force
		$OptionalParametersDiag.Remove($vmName)
		$OptionalParametersDiag.Add($vmName, $appVMValue)

		# Diagnostics Template Deployment
		New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem -Path $TemplateFileDiag).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
										   -ResourceGroupName $ResourceGroupName `
										   -TemplateFile $TemplateFileDiag `
										   -TemplateParameterFile $TemplateParametersFileDiag `
										   @OptionalParametersDiag `
										   -Force `
										   -Verbose `
										   -ErrorAction Stop
	}
	#endregion
}
catch {
    $ErrorMessage = 'An error occurred while deploying Azure Foundation CSP edition;'
    $ErrorMessage += " `n"
    $ErrorMessage += 'Error: '
    $ErrorMessage += $_
    Write-Error -Message $ErrorMessage
}
Finally
{
	#region Remove Temporary Storage Account
	Remove-AzureRmStorageAccount -ResourceGroupName $ResourceGroupName `
	-Name $StorageAccountName `
	-Force `
	-Confirm:$false
	#endregion
}