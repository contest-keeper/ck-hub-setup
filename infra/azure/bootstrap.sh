#!/usr/bin/env bash
# One-time setup for deploying Keeper Hub to Azure. Run it yourself, signed in with `az login`, in
# the subscription that will hold the Hub. It makes:
#
#   - a resource group per environment (rg-ckhub-dev for develop, rg-ckhub for production) and one
#     for the Terraform state;
#   - a storage account for the state (no public access, no shared keys, versioned);
#   - per environment, an Entra application that GitHub Actions signs in as through OIDC. There is
#     NO client secret and nothing to rotate: GitHub proves who it is with a short-lived token, and
#     Azure only accepts it for that environment of the listed repositories. Each application has
#     rights on its own resource group only, so a develop deploy can never touch production.
#
# It prints the values to set as GitHub variables. They are identifiers, not secrets.
# Safe to run twice: what exists is reused.
#
# Usage: bash bootstrap.sh [location] [github-owner]
set -euo pipefail

location="${1:-westeurope}"
owner="${2:-contest-keeper}"
# The repositories whose workflows deploy: ck-hub after its builds and releases, ck-hub-setup by hand.
repos=("ck-hub" "ck-hub-setup")
state_group="rg-ckhub-tfstate"
# environment -> resource group (must match infra/azure/environments/*.tfvars)
declare -A groups=([develop]="rg-ckhub-dev" [production]="rg-ckhub")

subscription_id=$(az account show --query id -o tsv)
tenant_id=$(az account show --query tenantId -o tsv)
echo "Subscription: $(az account show --query name -o tsv) ($subscription_id)"
read -r -p "Set up Keeper Hub (develop and production) in this subscription? [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "Stopped."; exit 1; }

# Resource providers are registered here, once, because the identities GitHub signs in as have no
# rights outside their resource group (the Terraform provider is told not to register them).
for namespace in Microsoft.App Microsoft.DBforPostgreSQL Microsoft.KeyVault Microsoft.OperationalInsights \
  Microsoft.ManagedIdentity Microsoft.Storage Microsoft.Authorization; do
  az provider register --namespace "$namespace" --wait
done

az group create --name "$state_group" --location "$location" --output none
for environment in develop production; do
  az group create --name "${groups[$environment]}" --location "$location" --output none
done

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
state_group_id=$(az group show --name "$state_group" --query id -o tsv)

# Your own account needs the blob role to make the container (the shared key is off).
me=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee-object-id "$me" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" --scope "$storage_id" --output none
echo "Waiting for the role to apply..."
sleep 45
az storage container create --name tfstate --account-name "$storage_account" --auth-mode login --output none

# One identity per environment.
declare -A client_ids
for environment in develop production; do
  app_name="ck-hub-deploy-${environment}"
  client_id=$(az ad app list --display-name "$app_name" --query "[0].appId" -o tsv)
  if [[ -z "$client_id" ]]; then
    client_id=$(az ad app create --display-name "$app_name" --query appId -o tsv)
  fi
  if [[ -z "$(az ad sp list --filter "appId eq '$client_id'" --query "[0].id" -o tsv)" ]]; then
    az ad sp create --id "$client_id" --output none
  fi
  principal_id=$(az ad sp show --id "$client_id" --query id -o tsv)

  # Azure accepts a GitHub token only for this environment of these repositories.
  for repo in "${repos[@]}"; do
    subject="repo:${owner}/${repo}:environment:${environment}"
    if [[ -z "$(az ad app federated-credential list --id "$client_id" --query "[?subject=='$subject'].name" -o tsv)" ]]; then
      az ad app federated-credential create --id "$client_id" --parameters "{
        \"name\": \"github-${repo}-${environment}\",
        \"issuer\": \"https://token.actions.githubusercontent.com\",
        \"subject\": \"${subject}\",
        \"audiences\": [\"api://AzureADTokenExchange\"]
      }" --output none
    fi
  done

  # Rights on this environment's resource group only. "Role Based Access Control Administrator"
  # lets Terraform give the Hub's identity read access to the Key Vault; it cannot reach anything
  # outside the group.
  group_id=$(az group show --name "${groups[$environment]}" --query id -o tsv)
  for role in "Contributor" "Role Based Access Control Administrator"; do
    az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$group_id" --output none
  done
  az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Contributor" --scope "$storage_id" --output none
  # Terraform looks the state account up through its resource group before it reads the blob.
  az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
    --role "Reader" --scope "$state_group_id" --output none
  client_ids[$environment]="$client_id"
done

cat <<EOF

Done. Set these as GitHub variables (identifiers, not secrets). Organization level is easiest, so
ck-hub and ck-hub-setup both see them:

  gh variable set AZURE_TENANT_ID           --org ${owner} --visibility all --body "${tenant_id}"
  gh variable set AZURE_SUBSCRIPTION_ID     --org ${owner} --visibility all --body "${subscription_id}"
  gh variable set TFSTATE_RESOURCE_GROUP    --org ${owner} --visibility all --body "${state_group}"
  gh variable set TFSTATE_STORAGE           --org ${owner} --visibility all --body "${storage_account}"
  gh variable set AZURE_CLIENT_ID_DEVELOP    --org ${owner} --visibility all --body "${client_ids[develop]}"
  gh variable set AZURE_CLIENT_ID_PRODUCTION --org ${owner} --visibility all --body "${client_ids[production]}"

Then, in each of ${repos[*]} (Settings > Environments), make the environments develop and
production. Production: add yourself as a required reviewer and allow deployments from the main
branch only. Develop: allow the develop branch only. See docs/azure.md.

For a deploy from your own PC, copy backend.hcl.example to backend.hcl with the same state values.
EOF
