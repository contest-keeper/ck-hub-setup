data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix = random_string.suffix.result
  base   = "${var.name}-${local.suffix}"
}

# The generated password is kept in the Terraform state (private, Azure AD only) because the Container
# App takes its database address as a plain secret: this subscription allows only one regular
# Container Apps environment, so the Hub runs in an express environment, which cannot read Key Vault.
resource "random_password" "db" {
  length  = 40
  special = false
}

# Made by bootstrap.sh, so the identity that deploys needs rights on this one group only.
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# ---------------------------------------------------------------- database

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "psql-${local.base}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  version             = "16"
  sku_name            = "B_Standard_B1ms"
  storage_mb          = 32768

  administrator_login               = "ckhub"
  administrator_password_wo         = random_password.db.result
  administrator_password_wo_version = var.db_password_version

  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true
  tags                          = var.tags

  lifecycle {
    # The zone Azure picks at creation must not make Terraform want to move the server.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "hub" {
  name      = "ckhub"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Plain connections are refused: the Hub connects over TLS (sslmode=require in its address).
resource "azurerm_postgresql_flexible_server_configuration" "require_tls" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "min_tls" {
  name      = "ssl_min_protocol_version"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "TLSv1.2"
}

# The special range 0.0.0.0 means "Azure services": the Container App reaches the database
# without a fixed address. The database still needs the generated password and TLS.
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "client" {
  count            = length(var.allowed_client_ips)
  name             = "client-${count.index}"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = var.allowed_client_ips[count.index]
  end_ip_address   = var.allowed_client_ips[count.index]
}

# ---------------------------------------------------------------- secrets

resource "azurerm_key_vault" "this" {
  name                       = "kv-${var.name}-${local.suffix}"
  resource_group_name        = data.azurerm_resource_group.this.name
  location                   = data.azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 30
  tags                       = var.tags
}

resource "azurerm_role_assignment" "deployer_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# New role assignments take a moment to apply.
resource "time_sleep" "rbac" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "database_url" {
  name             = "database-url"
  key_vault_id     = azurerm_key_vault.this.id
  value_wo         = "postgres://ckhub:${random_password.db.result}@${azurerm_postgresql_flexible_server.this.fqdn}:5432/${azurerm_postgresql_flexible_server_database.hub.name}?sslmode=require"
  value_wo_version = var.db_password_version
  content_type     = "text/plain"
  tags             = var.tags

  depends_on = [time_sleep.rbac]
}

# ---------------------------------------------------------------- downloads

# Installers live in a private container. The Hub sends visitors to a link that works for a few
# minutes, signed with this account's key, so the storage address is never public.
resource "azurerm_storage_account" "downloads" {
  name                            = "${var.name}dl${local.suffix}"
  resource_group_name             = data.azurerm_resource_group.this.name
  location                        = data.azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = merge(var.tags, { component = "downloads" })
}

resource "azurerm_storage_container" "downloads" {
  name                  = "downloads"
  storage_account_id    = azurerm_storage_account.downloads.id
  container_access_type = "private"
}

# ---------------------------------------------------------------- the Hub

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.base}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${local.base}"
  resource_group_name        = data.azurerm_resource_group.this.name
  location                   = data.azurerm_resource_group.this.location
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = var.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_container_app" "hub" {
  name                         = "ca-${local.base}"
  resource_group_name          = data.azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  tags                         = var.tags

  secret {
    name  = "database-url"
    value = "postgres://ckhub:${random_password.db.result}@${azurerm_postgresql_flexible_server.this.fqdn}:5432/${azurerm_postgresql_flexible_server_database.hub.name}?sslmode=require"
  }

  secret {
    name  = "download-key"
    value = azurerm_storage_account.downloads.primary_access_key
  }

  # The image is private, so Azure signs in to ghcr.io with a token that can only read packages.
  dynamic "secret" {
    for_each = var.registry_password != "" ? [1] : []

    content {
      name  = "registry-password"
      value = var.registry_password
    }
  }

  dynamic "registry" {
    for_each = var.registry_password != "" ? [1] : []

    content {
      server               = "ghcr.io"
      username             = "contest-keeper"
      password_secret_name = "registry-password"
    }
  }

  ingress {
    external_enabled           = true
    target_port                = 8088
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  # One copy only: login lockouts are counted in the Hub's memory.
  template {
    min_replicas = var.min_replicas
    max_replicas = 1

    container {
      name   = "hub"
      image  = var.image
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name        = "CK_DATABASE_URL"
        secret_name = "database-url"
      }

      env {
        name  = "CK_DOWNLOAD_ACCOUNT"
        value = azurerm_storage_account.downloads.name
      }

      env {
        name  = "CK_DOWNLOAD_CONTAINER"
        value = azurerm_storage_container.downloads.name
      }

      env {
        name        = "CK_DOWNLOAD_KEY"
        secret_name = "download-key"
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/"
        port      = 8088
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/"
        port      = 8088
      }
    }
  }

}
