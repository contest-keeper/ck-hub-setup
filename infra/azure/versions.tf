terraform {
  # 1.11 added write-only arguments, which keep the database password out of the state file.
  required_version = ">= 1.11"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.29"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }

  # The state lives in an Azure Storage account made once with bootstrap.sh. Pass its name
  # with: terraform init -backend-config=backend.hcl
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  # Resource providers are registered once by bootstrap.sh. The deploy identity only has rights
  # on its own resource group, so it must not try to register them at subscription level.
  resource_provider_registrations = "none"
  # The subscription comes from ARM_SUBSCRIPTION_ID (the deploy workflow sets it) or `az login`.
  # Nothing in this folder holds a credential: the workflow signs in with OIDC.
}

# The token comes from CLOUDFLARE_API_TOKEN (the deploy workflow sets it from a GitHub secret). Without a
# zone id no record is made, and then the provider is never used, so no token is needed.
provider "cloudflare" {}
