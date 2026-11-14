terraform {
  required_version = ">= 1.11"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # The state lives in the Azure Storage account made once with bootstrap.sh.
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  # Resource providers are registered once by bootstrap.sh.
  resource_provider_registrations = "none"
}
