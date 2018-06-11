#*****************************************************************************************************#
#                                                                                                     #
#  This script migrates Azure Virtual Machines with managed disks from one region to another across   #
#  geography in same subscription where Azure site recovery with Azure to Azure DR is not possible    #
#                                                                                                     #
#  Make sure VM is in stopped/deallocated state before starting migration                             #
#  Target Resource group, target VNET and subnet should be pre-created before execution               #
#  Pass other required values as parameters, otherwise it will prompt                                 #
#                                                                                                     #
# © Satheeshkumar Manoharan, Anyone can use without any warranty in non-production environment        #
#                                                                                                     #
#*****************************************************************************************************#


# Declare required parameters
param (
    [Parameter(Mandatory=$true)][string]$resourceGroupName,
    [Parameter(Mandatory=$true)][string]$vmName,
    [Parameter(Mandatory=$true)][string]$tgt_region,
    [Parameter(Mandatory=$true)][string]$tgt_resourceGroupName,
    [Parameter(Mandatory=$true)][string]$tgt_storageAccountName,
    [Parameter(Mandatory=$true)][string]$imageContainerName,
    [Parameter(Mandatory=$true)][string]$tgt_vnet,
    [Parameter(Mandatory=$true)][string]$tgt_subnet,
    [Parameter(Mandatory=$false)][string]$os_type = "Linux",
    [Parameter(Mandatory=$false)][string]$av_set
 )


# Exit if VM is not found or not in deallocated state
$vm = Get-AzureRmVM -ResourceGroupName $resourceGroupName -Name $vmName -Status -ErrorAction Ignore
If(!$vm){
    throw "VM $vmName not found!"
}
ElseIf ($vm.Statuses[1].DisplayStatus -match "VM deallocated"){
    $vm = Get-AzureRmVM -ResourceGroupName $resourceGroupName -Name $vmName
}
Else{
    throw "VM $vmName is not in deallocated state"
}

# Set up the target storage account in the other region
$storage = Get-AzureRmStorageAccount -ResourceGroupName $tgt_resourceGroupName -Name $tgt_storageAccountName  -ErrorAction Ignore
if(!$storage){
    New-AzureRmStorageAccount -ResourceGroupName $tgt_resourceGroupName -Name $tgt_storageAccountName -Location $tgt_region -SkuName 'Premium_LRS'
}
$targetStorageContext = (Get-AzureRmStorageAccount -ResourceGroupName $tgt_resourceGroupName -Name $tgt_storageAccountName).Context
$container = Get-AzureStorageContainer -Name $imageContainerName -Context $targetStorageContext -ErrorAction Ignore
if(!$container){
    New-AzureStorageContainer -Name $imageContainerName -Context $targetStorageContext 
}

########################## COPY OS DISK - STARTS ########################################################

# Set variables to create OS snapshot
$os_disk = Get-AzureRmDisk -ResourceGroupName $resourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name
$os_snapshotName = $vmName + "-" + $vm.Location + "-os-snap"

# Create OS snapshot in source RG if not already available, else get existing snapshot
# Supressing error has issues, so we will see error in console : https://github.com/Azure/azure-powershell/issues/6433
$os_snap = Get-AzureRmSnapshot -ResourceGroupName $resourceGroupName -SnapshotName $os_snapshotName -ErrorAction Ignore
if(!$os_snap)
{
    $os_snapshotConfig = New-AzureRmSnapshotConfig -SourceUri $os_disk.Id -CreateOption Copy -Location $vm.Location
    $os_snap = New-AzureRmSnapshot -ResourceGroupName $resourceGroupName -Snapshot $os_snapshotConfig -SnapshotName $os_snapshotName
}

# prepare to copy 
 
# Create a Shared Access Signature (SAS) for the source snapshot
$os_snapSasUrl = Grant-AzureRmSnapshotAccess -ResourceGroupName $resourceGroupName -SnapshotName $os_snapshotName -DurationInSecond 3600 -Access Read

 
# Use the SAS URL to copy the blob to the target storage account (and thus region)
$os_blobName = $vmName + "-os-blob"
Start-AzureStorageBlobCopy -AbsoluteUri $os_snapSasUrl.AccessSAS -DestContainer $imageContainerName -DestContext $targetStorageContext -DestBlob $os_blobName
Get-AzureStorageBlobCopyState -Container $imageContainerName -Blob $os_blobName -Context $targetStorageContext -WaitForComplete

# Delete OS source snapshot after copy to destination storage account
Revoke-AzureRmSnapshotAccess -ResourceGroupName $resourceGroupName -SnapshotName $os_snapshotName
Remove-AzureRmSnapshot -ResourceGroupName $resourceGroupName -SnapshotName $os_snapshotName -Force

# Get the full URI to the page blob of OS disk
$osDiskVhdUri = ($targetStorageContext.BlobEndPoint + $imageContainerName + "/" + $os_blobName)

# Create the new snapshot in the target region if not available
$tgt_osSnapshotName = $vmName + "-os-snap"
$os_snapshot = Get-AzureRmSnapshot -ResourceGroupName $tgt_resourceGroupName -SnapshotName $tgt_osSnapshotName -ErrorAction Ignore
if(!$os_snapshot){
    # Build up the snapshot configuration, using the target storage account's resource ID
    $osSnapshotConfig = New-AzureRmSnapshotConfig -AccountType StandardLRS `
                                            -OsType $os_type `
                                            -Location $tgt_region `
                                            -CreateOption Import `
                                            -SourceUri $osDiskVhdUri `
                                            -StorageAccountId (Get-AzureRmStorageAccount -ResourceGroupName $tgt_resourceGroupName -Name $tgt_storageAccountName).Id
    # Create snapshot using configuration
    $os_snapshot = New-AzureRmSnapshot -ResourceGroupName $tgt_resourceGroupName -SnapshotName $tgt_osSnapshotName -Snapshot $osSnapshotConfig
}

# Create OS disk from snapshot in destination resource group if not already exists
$dest_osDisk = Get-AzureRmDisk -ResourceGroupName $tgt_resourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name -ErrorAction Ignore
if(!$dest_osDisk){
    $dest_osDiskConfig = New-AzureRmDiskConfig -Location $os_snapshot.Location -SourceResourceId $os_snapshot.Id -CreateOption Copy
    $dest_osDisk = New-AzureRmDisk -Disk $dest_osDiskConfig -ResourceGroupName $tgt_resourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name
}
# Remove OS snapshot in destination after creating the disk from snapshot
Remove-AzureRmSnapshot -ResourceGroupName $tgt_resourceGroupName -SnapshotName $tgt_osSnapshotName -Force

########################## COPY OS DISK - ENDS ##########################################################


# Check if data disk is present
$count = (Get-AzureRmVM -ResourceGroupName $resourceGroupName -Name $vmName -Status).Disks.Count
Write-Output "VM $vmName has $($count -1) Data disk(s) attached"

########################## COPY DATA DISK - STARTS ######################################################

for ($i=1; $i -lt $count; $i++) {
    # data_disk1 #Get-Variable -Name "data_disk$i" -ValueOnly
    New-Variable -Name "data_disk$i" -Value (Get-AzureRmDisk -ResourceGroupName $resourceGroupName -DiskName $vm.StorageProfile.DataDisks[$i-1].Name -ErrorAction Ignore) -Force
    # data_snapshotName1 #Get-Variable -Name "data_snapshotName$i" -ValueOnly
    New-Variable -Name "data_snapshotName$i" -Value ($vmName + "-" + $vm.Location + "-data-snap$i") -Force
    
    # Create Data snapshot in source RG if not already available, else get existing snapshot
    # data_snap1 #Get-Variable -Name "data_snap$i" -ValueOnly
    New-Variable -Name "data_snap$i" -Value (Get-AzureRmSnapshot -ResourceGroupName $resourceGroupName -SnapshotName (Get-Variable -Name "data_snapshotName$i" -ValueOnly) -ErrorAction Ignore) -Force

    if(!(Get-Variable -Name "data_snap$i" -ValueOnly))
    {
        # data_snapshotConfig1 #Get-Variable -Name "data_snapshotConfig$i" -ValueOnly
        New-Variable -Name "data_snapshotConfig$i" -Value (New-AzureRmSnapshotConfig -SourceUri (Get-Variable -Name "data_disk$i" -ValueOnly).Id -CreateOption Copy -Location $vm.Location) -Force
        # data_snap1 #Get-Variable -Name "data_snap$i" -ValueOnly
        New-Variable -Name "data_snap$i" -Value (New-AzureRmSnapshot -ResourceGroupName $resourceGroupName -Snapshot (Get-Variable -Name "data_snapshotConfig$i" -ValueOnly) -SnapshotName (Get-Variable -Name "data_snapshotName$i" -ValueOnly)) -Force
    }

    # prepare to copy 
 
    # Create a Shared Access Signature (SAS) for the source snapshot
    # data_snapSasUrl1 #Get-Variable -Name "data_snapSasUrl$i" -ValueOnly
    New-Variable -Name "data_snapSasUrl$i" -Value (Grant-AzureRmSnapshotAccess -ResourceGroupName $resourceGroupName -SnapshotName (Get-Variable -Name "data_snapshotName$i" -ValueOnly) -DurationInSecond 3600 -Access Read) -Force
    
    # Use the SAS URL to copy the blob to the target storage account (and thus region)
    # data_blobName1 #Get-Variable -Name "data_blobName$i" -ValueOnly
    New-Variable -Name "data_blobName$i" -Value ($vmName + "-data-blob$i") -Force

    Start-AzureStorageBlobCopy -AbsoluteUri (Get-Variable -Name "data_snapSasUrl$i" -ValueOnly).AccessSAS -DestContainer $imageContainerName -DestContext $targetStorageContext -DestBlob (Get-Variable -Name "data_blobName$i" -ValueOnly)
    Get-AzureStorageBlobCopyState -Container $imageContainerName -Blob (Get-Variable -Name "data_blobName$i" -ValueOnly) -Context $targetStorageContext -WaitForComplete

    # Delete Data disk source snapshot after copy to destination storage account
    Revoke-AzureRmSnapshotAccess -ResourceGroupName $resourceGroupName -SnapshotName (Get-Variable -Name "data_snapshotName$i" -ValueOnly)
    Remove-AzureRmSnapshot -ResourceGroupName $resourceGroupName -SnapshotName (Get-Variable -Name "data_snapshotName$i" -ValueOnly) -Force

    # Get the full URI to the page blob of data disk
    # dataDiskVhdUri1 #Get-Variable -Name "dataDiskVhdUri$i" -ValueOnly
    New-Variable -Name "dataDiskVhdUri$i" -Value ($targetStorageContext.BlobEndPoint + $imageContainerName + "/" + (Get-Variable -Name "data_blobName$i" -ValueOnly)) -Force
    
    # Create the new snapshot in the target region if not available
    # tgt_dataSnapshotName1 #Get-Variable -Name "tgt_dataSnapshotName$i" -ValueOnly
    New-Variable -Name "tgt_dataSnapshotName$i" -Value ($vmName + "-data-snap$i") -Force
    # data_snapshot1 #Get-Variable -Name "data_snapshot$i" -ValueOnly
    New-Variable -Name "data_snapshot$i" -Value (Get-AzureRmSnapshot -ResourceGroupName $tgt_resourceGroupName -SnapshotName (Get-Variable -Name "tgt_dataSnapshotName$i" -ValueOnly)) -Force
    if(!(Get-Variable -Name "data_snapshot$i" -ValueOnly)){
        $dataSnapshotConfig = New-AzureRmSnapshotConfig -AccountType StandardLRS `
                                            -Location $tgt_region `
                                            -CreateOption Import `
                                            -SourceUri (Get-Variable -Name "dataDiskVhdUri$i" -ValueOnly) `
                                            -StorageAccountId (Get-AzureRmStorageAccount -ResourceGroupName $tgt_resourceGroupName -Name $tgt_storageAccountName).Id
        New-Variable -Name "data_snapshot$i" -Value (New-AzureRmSnapshot -ResourceGroupName $tgt_resourceGroupName -SnapshotName (Get-Variable -Name "tgt_dataSnapshotName$i" -ValueOnly) -Snapshot $dataSnapshotConfig) -Force
    }

    # Create Data disk from snapshot in destination resource group if not already exists
    # dest_dataDisk1 #Get-Variable -Name "dest_dataDisk$i" -ValueOnly
    New-Variable -Name "dest_dataDisk$i" -Value (Get-AzureRmDisk -ResourceGroupName $tgt_resourceGroupName -DiskName $vm.StorageProfile.DataDisks[$i-1].Name -ErrorAction Ignore) -Force
    if(!(Get-Variable -Name "dest_dataDisk$i" -ValueOnly)){
        $dest_dataDiskConfig = New-AzureRmDiskConfig -Location (Get-Variable -Name "data_snapshot$i" -ValueOnly).Location -SourceResourceId (Get-Variable -Name "data_snapshot$i" -ValueOnly).Id -CreateOption Copy
        New-Variable -Name "dest_dataDisk$i" -Value (New-AzureRmDisk -Disk $dest_dataDiskConfig -ResourceGroupName $tgt_resourceGroupName -DiskName $vm.StorageProfile.DataDisks[$i-1].Name) -Force
    }

    # Remove data snapshot in destination after creating the disk from snapshot
    Remove-AzureRmSnapshot -ResourceGroupName $tgt_resourceGroupName -SnapshotName (Get-Variable -Name "tgt_dataSnapshotName$i" -ValueOnly) -Force
}

########################## COPY DATA DISK - ENDS ########################################################


#Get the virtual network where virtual machine will be hosted
$vnet = Get-AzureRmVirtualNetwork -Name $tgt_vnet -ResourceGroupName $tgt_resourceGroupName -ErrorAction Ignore
if(!$vnet){
    throw "Target VNET $tgt_vnet not found. Please create it and execute the migration script again"
}

# Get the destination subnet configurations
$subnet = Get-AzureRmVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $tgt_subnet -ErrorAction Ignore
if(!$subnet){
    throw "Target Subnet $tgt_subnet not found. Please create it and execute the migration script again"
}

$nicName = $vm.NetworkProfile.NetworkInterfaces[0].Id.split('/')[-1]

# Create NIC in the correct subnet of the virtual network if not found already
$nic = Get-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $tgt_resourceGroupName -ErrorAction Ignore
if(!$nic){
    $nic = New-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $tgt_resourceGroupName -Location $os_snapshot.Location -SubnetId $subnet.Id
}

# Check VM size availability in destination, and if not found prompt user
$vmSize = $vm.HardwareProfile.VmSize
if (!((Get-AzureRmVMSize -Location $os_snapshot.Location).Name -contains $vmSize)){
    Write-Output "VM hardware size $vmSize not found in the region, provide a right size from below ones.."
    (Get-AzureRmVMSize -Location $os_snapshot.Location).Name
    $vmSize = Read-Host 'Enter VM size '
}

# use existing AV set name if source VM has AV set and no new AV set name is passed as input
if($vm.AvailabilitySetReference){
    if(!$av_set){
        $av_set = $vm.AvailabilitySetReference.Id.split('/')[-1]
    }
}

# Initialize VM configuration based on AV set is passed
if($av_set){
    # Create new availability set if it does not exist
    $availSet = Get-AzureRmAvailabilitySet -ResourceGroupName $tgt_resourceGroupName -Name $av_set -ErrorAction Ignore
    if (-Not $availSet) {
        $availSet = New-AzureRmAvailabilitySet -Location $os_snapshot.Location -Name $av_set -ResourceGroupName $tgt_resourceGroupName -PlatformFaultDomainCount 2 -PlatformUpdateDomainCount 5 -Sku Aligned
    }
    #Initialize virtual machine configuration with AV set
    $VirtualMachine = New-AzureRmVMConfig -VMName $vmName -VMSize $vmSize -AvailabilitySetId $availSet.Id
}
else {
    #Initialize virtual machine configuration without AV set
    $VirtualMachine = New-AzureRmVMConfig -VMName $vmName -VMSize $vmSize
}

#Use the Managed Disk Resource Id to attach it to the virtual machine. Please change the OS type to linux if OS disk has linux OS
If($os_type -eq "Linux"){
    $VirtualMachine = Set-AzureRmVMOSDisk -VM $VirtualMachine -ManagedDiskId $dest_osDisk.Id -CreateOption Attach -Linux
}
Else{
    $VirtualMachine = Set-AzureRmVMOSDisk -VM $VirtualMachine -ManagedDiskId $dest_osDisk.Id -CreateOption Attach -Windows
}

$VirtualMachine = Add-AzureRmVMNetworkInterface -VM $VirtualMachine -Id $nic.Id

# Add data disk in VM config if present
for ($i=1; $i -lt $count; $i++) {
    $VirtualMachine = Add-AzureRmVMDataDisk -VM $VirtualMachine -CreateOption Attach -ManagedDiskId (Get-Variable -Name "dest_dataDisk$i" -ValueOnly).Id -Lun ($i-1)
}

#Create the virtual machine with Managed Disk
if(!(Get-AzureRmVM -ResourceGroupName $tgt_resourceGroupName -Name $vmName -ErrorAction Ignore)){
    New-AzureRmVM -VM $VirtualMachine -ResourceGroupName $tgt_resourceGroupName -Location $os_snapshot.Location
}

#Cleanup resources

# Delete storage account used to copy files
Remove-AzureRmStorageAccount -ResourceGroupName $tgt_resourceGroupName -Name $tgt_storageAccountName -Force