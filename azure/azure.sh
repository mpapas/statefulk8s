
resourceGroup="YOUR RESOURCE GROUP"
location="YOUR LOCATION"
aksClusterName="YOUR AKS CLUSTER NAME"
LogAnalyticsWorkspaceName="YOUR LOG ANALYTICS WORKSPACE NAME"
storageAccountName="YOUR STORAGE ACCOUNT" # Be sure to use the same value in the azurefiles-pv.yaml file
shareName="YOUR SHARE NAME" # Be sure to use the same value in the azurefiles-pv.yaml file
tags="Owner=XYZ,Environment=Dev" # Add your own tags

# create resource group
az group create --name $resourceGroup --location $location --tags $tags

# create log analytics workspace
LogAnalyticsWorkspaceResourceId=$(az monitor log-analytics workspace create --resource-group $resourceGroup --workspace-name $LogAnalyticsWorkspaceName --query id -o tsv)
echo $LogAnalyticsWorkspaceResourceId

# create AKS cluster
az aks create --name $aksClusterName \
    --resource-group $resourceGroup \
    --generate-ssh-keys \
    --node-count 1 \
    --min-count 1 \
    --max-count 10 \
    --workspace-resource-id $LogAnalyticsWorkspaceResourceId \
    --enable-msi-auth-for-monitoring true  \
    --enable-addons monitoring \
    --enable-cluster-autoscaler \
    --os-sku Ubuntu \
    --load-balancer-sku standard \
    --tier Standard \
    --node-vm-size Standard_DS2_v2 \
    --auto-upgrade-channel patch \
    --tags $tags

az aks get-credentials --resource-group $resourceGroup --name $aksClusterName

# create a storage account
az storage account create -n $storageAccountName -g $resourceGroup -l $location --sku Standard_LRS

# export the connection string - this is used when creating the Azure file share
AZURE_STORAGE_CONNECTION_STRING=$(az storage account show-connection-string -n $storageAccountName -g $resourceGroup -o tsv)

# create the Azure file share
az storage share create -n $shareName --connection-string $AZURE_STORAGE_CONNECTION_STRING

# export the storage account key
STORAGE_KEY=$(az storage account keys list --resource-group $resourceGroup --account-name $storageAccountName --query "[0].value" -o tsv)

# create a Kubernetes secret
kubectl create secret generic azure-storage-secret --from-literal=azurestorageaccountname=$storageAccountName --from-literal=azurestorageaccountkey=$STORAGE_KEY

# create PV
# make sure to update the volumeHandle and shareName in the azurefiles-pv.yaml file
kubectl create -f azurefiles-pv.yaml
kubectl get pv -w

# create PVC
kubectl apply -f azurefiles-pvc.yaml

# verify PVC is created
kubectl get pvc cloudfilepvc

# deploy the workload
