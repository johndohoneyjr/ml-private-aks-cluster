#! /bin/bash

# Variables
resourceGroup="ml-servicenow-rg"
location="westus2"
aksName="servicenowaks"
vnetName="aksvnet"
subnetName="akssubnet"

identityName="servicenowaksidentity"
KUBERNETES_VM_SKU="Standard_D4_v2"
AZURE_ML_NAME="azureml"
AZURE_ML_NAMEWS="azuremlws"
storageAccountName="servicenowmlstore"
keyVaultName="servicenowakskeyvault"
acrName="servicenowaksacr"


# Create a resource group
az group create --name $resourceGroup --location $location

az ml workspace create --name $AZURE_ML_NAMEWS --resource-group $resourceGroup

# Create a managed identity
az identity create --resource-group $resourceGroup --name $identityName

# Get the ID of the managed identity
identityId=$(az identity show --resource-group $resourceGroup --name $identityName --query id --output tsv)

az aks create -n $aksName -g $resourceGroup --node-count 2  -s $KUBERNETES_VM_SKU --generate-ssh-keys --enable-oidc-issuer  --load-balancer-sku standard --enable-private-cluster --enable-managed-identity --private-dns-zone system --disable-public-fqdn --assign-identity $identityId 

echo "Adding Machine Learning extenstion to Kubernetes Cluster ..."
az k8s-extension create --name $AZURE_ML_NAME \
--extension-type Microsoft.AzureML.Kubernetes \
--config enableTraining=True enableInference=True inferenceRouterServiceType=LoadBalancer allowInsecureConnections=True inferenceLoadBalancerHA=False \
--cluster-type managedClusters 
--cluster-name $aksName \
--scope cluster -g $resourceGroup


az acr create --name $acrName --resource-group $resourceGroup --location $location --sku Standard --admin-enabled true
az aks update -n $aksName -g $resourceGroup --attach-acr $acrName


# Get the ID of the VNet created by AKS
vnetId=$(az network vnet list | jq -r .[0].subnets[].id)

storageAccountNameId=$(az storage account list --resource-group $resourceGroup --query [].name -o tsv)
keyVaultNameId=$(az keyvault list --resource-group $resourceGroup --query [].name -o tsv)
acrNameId=$(az acr list --resource-group $resourceGroup --query [].name -o tsv)

nodeResourceGroup=$(az aks show -g $resourceGroup -n $aksName -o tsv --query nodeResourceGroup)
vnetName=$(az network vnet list -g $nodeResourceGroup -o tsv --query "[].name")
subnetName=$(az network vnet list -g $nodeResourceGroup -o tsv --query "[].subnets[].name")


# Create a private endpoint for the storage account
az network private-endpoint create --resource-group $nodeResourceGroup \
--connection-name "${storageAccountName}PrivateEndpoint" \
--name "${storageAccountName}PrivateEndpoint" \
--vnet-name $vnetName --subnet $subnetName \
--private-connection-resource-id $(az storage account show --name $storageAccountNameId --query id --output tsv) \
--group-ids blob --location $location

# Create a private endpoint for the key vault
az network private-endpoint create --resource-group $nodeResourceGroup \
--connection-name "${keyVaultName}PrivateEndpoint" \
 --name "${keyVaultName}PrivateEndpoint" \
 --vnet-name $vnetName --subnet $subnetName \
 --private-connection-resource-id $(az keyvault show --name $keyVaultNameId --query id --output tsv) \
 --group-ids vault --location $location

# Update to Premium SKU -- So it can have a private endpoint
az acr update --name $acrNameId  --sku Premium

# Create a private endpoint for the container registry
az network private-endpoint create --resource-group $nodeResourceGroup \
--connection-name "${acrName}PrivateEndpoint" \
--name "${acrName}PrivateEndpoint" \
--vnet-name $vnetName --subnet $subnetName \
--private-connection-resource-id $(az acr show --name $acrNameId --query id --output tsv) \
--group-ids registry --location $location

mlName=$(az ml workspace list --resource-group $resourceGroup --query [].name -o tsv)

APP_CLIENT_ID=$(az ad sp list --display-name $identityName --query '[0].appId' -otsv)
resourceID=$(az ml workspace show  --resource-group $resourceGroup --name $mlName --query id -otsv)

az role assignment create --assignee $APP_CLIENT_ID \
--role "AzureML Data Scientist" \
--scope $resourceID


# Create a private endpoint for the machine learning workspace
az network private-endpoint create --resource-group $nodeResourceGroup \
--connection-name "${mlName}PrivateEndpoint" \
--name "${mlName}PrivateEndpoint" \
--vnet-name $vnetName --subnet $subnetName \
--private-connection-resource-id $(az ml workspace show --resource-group $resourceGroup --name $mlName --query id --output tsv) \
--group-ids amlworkspace --location $location

## Not disabled for experimentation

# Disable public internet access to the storage account
az storage account update --name $storageAccountNameId --default-action Deny

# Disable public internet access to the key vault
az keyvault update --name $keyVaultNameId --default-action Deny

# Disable public access to the Azure Machine Learning workspace
az ml workspace update --resource-group $resourceGroup --name $mlName --public-network-access Disabled
