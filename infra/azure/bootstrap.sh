#!/usr/bin/env bash
# One-time setup for deploying Keeper Hub to Azure. Run it yourself, signed in with `az login`, in
# the subscription that will hold the Hub. It makes:
#
#   - the resource group the Hub lives in (rg-ckhub) and one for the Terraform state;
#   - a storage account for the state (no public access, no shared keys, versioned);
#   - an Entra application that GitHub Actions signs in as through OIDC. There is NO client secret
#     and nothing to rotate: GitHub proves who it is with a short-lived token, and only for the
#     environment named below.
#
# It prints the values to put in the GitHub environment. They are identifiers, not secrets.
# Safe to run twice: what exists is reused.
#
# Usage: bash bootstrap.sh [location] [github-repo] [github-environment]
set -euo pipefail

location="${1:-westeurope}"
repo="${2:-contest-keeper/ck-hub-setup}"
environment="${3:-production}"
hub_group="rg-ckhub"
state_group="rg-ckhub-tfstate"
app_name="ck-hub-deploy"

subscription_id=$(az account show --query id -o tsv)
tenant_id=$(az account show --query tenantId -o tsv)
echo "Subscription: $(az account show --query name -o tsv) ($subscription_id)"
read -r -p "Set up Keeper Hub in this subscription? [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "Stopped."; exit 1; }

# Resource providers are registered here, once, because the identity GitHub signs in as has no
# rights outside the Hub's resource group (the Terraform provider is told not to register them).
for namespace in Microsoft.App Microsoft.DBforPostgreSQL Microsoft.KeyVault Microsoft.OperationalInsights \
  Microsoft.ManagedIdentity Microsoft.Storage Microsoft.Authorization; do
  az provider register --namespace "$namespace" --wait
done

az group create --name "$hub_group" --location "$location" --output none
az group create --name "$state_group" --location "$location" --output none

# The state account name must be globally unique: keep the one made earlier, if there is one.
storage_account=$(az storage account list --resource-group "$state_group" --query "[0].name" -o tsv)
if [[ -z "$storage_account" ]]; then
  storage_account="ckhubtf$(head -c 100 /dev/urandom | tr -dc 'a-z0-9' | head -c 10)"
  az storage account create --name "$storage_account" --resource-group "$state_group" \
    --location "$location" --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access false \
    --output none
  az storage account blob-service-properties update --account-name "$storage_account" \
    --resource-group "$state_group" --enable-versioning true --output none
fi
storage_id=$(az storage account show --name "$storage_account" --resource-group "$state_group" --query id -o tsv)

# Your own account needs the blob role to make the container (the shared key is off).
me=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee-object-id "$me" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" --scope "$storage_id" --output none
echo "Waiting for the role to apply..."
sleep 45
az storage container create --name tfstate --account-name "$storage_account" --auth-mode login --output none

# The identity GitHub Actions signs in as.
client_id=$(az ad app list --display-name "$app_name" --query "[0].appId" -o tsv)
if [[ -z "$client_id" ]]; then
  client_id=$(az ad app create --display-name "$app_name" --query appId -o tsv)
fi
if [[ -z "$(az ad sp list --filter "appId eq '$client_id'" --query "[0].id" -o tsv)" ]]; then
  az ad sp create --id "$client_id" --output none
fi
principal_id=$(az ad sp show --id "$client_id" --query id -o tsv)

subject="repo:${repo}:environment:${environment}"
if [[ -z "$(az ad app federated-credential list --id "$client_id" --query "[?subject=='$subject'].name" -o tsv)" ]]; then
  az ad app federated-credential create --id "$client_id" --parameters "{
    \"name\": \"github-${environment}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${subject}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none
fi

# Rights on the Hub's resource group only. "Role Based Access Control Administrator" lets Terraform
# give the Hub's identity read access to the Key Vault; it cannot reach anything outside the group.
hub_group_id=$(az group show --name "$hub_group" --query id -o tsv)
for role in "Contributor" "Role Based Access Control Administrator"; do
  az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "$hub_group_id" --output none
done
az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "$storage_id" --output none
# Terraform looks the state account up through its resource group before it reads the blob.
state_group_id=$(az group show --name "$state_group" --query id -o tsv)
az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
  --role "Reader" --scope "$state_group_id" --output none

cat <<EOF

Done. In GitHub, open ${repo} > Settings > Environments > ${environment} (make it, and add
yourself as a required reviewer so every deploy needs your approval), and add these as
environment VARIABLES (not secrets):

  AZURE_CLIENT_ID        ${client_id}
  AZURE_TENANT_ID        ${tenant_id}
  AZURE_SUBSCRIPTION_ID  ${subscription_id}
  TFSTATE_RESOURCE_GROUP ${state_group}
  TFSTATE_STORAGE        ${storage_account}

For a deploy from your own PC, copy backend.hcl.example to backend.hcl with the same state values.
EOF
