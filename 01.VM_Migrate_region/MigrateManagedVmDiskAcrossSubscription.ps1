#*****************************************************************************************************#
#                                                                                                     #
#  This script migrates Azure Virtual Machines managed disks from one subscription to another         #
#  subscription in the same geography. User should have access to both subscripotions                 #
#                                                                                                     #
#  Pass required values as parameters, otherwise it will prompt                                       #
#                                                                                                     #
# © Satheeshkumar Manoharan, Anyone can use without any warranty in non-production environment        #
#                                                                                                     #
#*****************************************************************************************************#

param (
    [Parameter(Mandatory=$true)][string]$sourceSubscriptionId,
    [Parameter(Mandatory=$true)][string]$sourceResourceGroupName,
    [Parameter(Mandatory=$true)][string]$managedDiskName,
    [Parameter(Mandatory=$true)][string]$targetResourceGroupName,
    [Parameter(Mandatory=$true)][string]$targetSubscriptionId
 )

#Set the context to the subscription Id where Managed Disk exists
Select-AzureRmSubscription -Subscription $sourceSubscriptionId
 
#Get the source managed disk
$managedDisk= Get-AzureRMDisk -ResourceGroupName $sourceResourceGroupName -DiskName $managedDiskName
 
#Set the context to the subscription Id where managed disk will be copied to
Select-AzureRmSubscription -Subscription $targetSubscriptionId
 
$diskConfig=New-AzureRmDiskConfig -SourceResourceId $managedDisk.Id -Location $managedDisk.Location -CreateOption Copy
 
#Create a new managed disk in the target subscription and resource group
New-AzureRmDisk -Disk $diskConfig -DiskName $managedDiskName -ResourceGroupName $targetResourceGroupName