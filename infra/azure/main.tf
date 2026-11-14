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

# The generated password exists only while Terraform runs. It goes straight into the database and
# the Key Vault through write-only arguments, so it is not in the state, the plan or any file.
ephemeral "random_password" "db" {
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
  administrator_password_wo         = ephemeral.random_password.db.result
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
  value_wo         = "postgres://ckhub:${ephemeral.random_password.db.result}@${azurerm_postgresql_flexible_server.this.fqdn}:5432/${azurerm_postgresql_flexible_server_database.hub.name}?sslmode=require"
  value_wo_version = var.db_password_version
  content_type     = "text/plain"
  tags             = var.tags

  depends_on = [time_sleep.rbac]
}

resource "azurerm_user_assigned_identity" "hub" {
  name                = "id-${local.base}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "hub_reads_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.hub.principal_id
}

# The Container App reads the secret as soon as it starts, so wait for this role to apply too.
resource "time_sleep" "hub_rbac" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.hub_reads_secrets]
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
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = var.tags
}

resource "azurerm_container_app" "hub" {
  name                         = "ca-${local.base}"
  resource_group_name          = data.azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.hub.id]
  }

  secret {
    name                = "database-url"
    key_vault_secret_id = azurerm_key_vault_secret.database_url.versionless_id
    identity            = azurerm_user_assigned_identity.hub.id
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

  depends_on = [time_sleep.hub_rbac]
}
