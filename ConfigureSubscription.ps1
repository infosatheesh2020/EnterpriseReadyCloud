param([string]$SubscriptionId)
Select-AzureRmSubscription -SubscriptionId $SubscriptionId
$scope = "/subscriptions/$SubscriptionId"

$expressRoutePolicy    = "$PSScriptRoot\RestrictERCircuit.json"
$supportedRegionPolicy = "$PSScriptRoot\RestrictRegions.json"
$serviceCatalogPolicy  = "$PSScriptRoot\ServiceCatalog.json"

Write-Host "Applying Service Catalog Policy" -ForegroundColor Green
New-AzureRmPolicyDefinition -Name "ServiceCatalog" `
                            -DisplayName "Service Catalog Policy" `
                            -Policy $serviceCatalogPolicy `
                            -Description "Trey Research Service Catalog Policy"


$scPolicy = Get-AzureRmPolicyDefinition -Name "ServiceCatalog"
New-AzureRmPolicyAssignment -Name "ServiceCatalog" `
                            -Scope $scope `
                            -DisplayName "Trey Research - Service Catalog Policy" `
                            -PolicyDefinition $scPolicy

Write-Host "Applying ExpressRoute Restriction Policy" -ForegroundColor Green
New-AzureRmPolicyDefinition -Name "RestrictERCircuit" `
                            -DisplayName "RestrictERCircuit" `
                            -Policy $expressRoutePolicy `
                            -Description "Restrict ExpressRoute Circuit"


$erPolicy = Get-AzureRmPolicyDefinition -Name "RestrictERCircuit"
New-AzureRmPolicyAssignment -Name "RestrictERCircuit" `
                            -Scope $scope `
                            -DisplayName "RestrictERCircuit" `
                            -PolicyDefinition $erPolicy


Write-Host "Applying Supported Regions Policy" -ForegroundColor Green
New-AzureRmPolicyDefinition -Name "SupportedRegions" `
                            -DisplayName "SupportedRegions" `
                            -Policy $supportedRegionPolicy `
                            -Description "Trey Research Supported Regions"


$regionsPolicy = Get-AzureRmPolicyDefinition -Name "SupportedRegions"
New-AzureRmPolicyAssignment -Name "SupportedRegions" `
                            -Scope $scope `
                            -DisplayName "Trey Research Supported Regions" `
                            -PolicyDefinition $regionsPolicy
