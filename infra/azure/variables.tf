variable "name" {
  description = "Short name used in resource names. Lowercase letters and digits."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.name))
    error_message = "Use 3 to 12 lowercase letters or digits."
  }
}

variable "resource_group_name" {
  description = "The resource group bootstrap.sh made for the Hub. Everything is created inside it, in its region."
  type        = string
}

variable "image" {
  description = "The Hub image to run, for example ghcr.io/contest-keeper/ck-hub:0.1.0. Pin a version; avoid latest."
  type        = string

  validation {
    condition     = can(regex("^ghcr\\.io/contest-keeper/ck-hub:[0-9A-Za-z._-]+$", var.image))
    error_message = "Use an image from ghcr.io/contest-keeper/ck-hub with a tag."
  }
}

variable "min_replicas" {
  description = "0 lets the Hub sleep when idle (the first request then waits a few seconds). 1 keeps it always on."
  type        = number
  default     = 1

  validation {
    condition     = var.min_replicas == 0 || var.min_replicas == 1
    error_message = "The Hub keeps login lockouts in memory, so it runs as at most one copy: use 0 or 1."
  }
}

variable "db_password_version" {
  description = "Raise this number to make a new database password. The password is kept in the private Terraform state."
  type        = number
  default     = 1
}

variable "allowed_client_ips" {
  description = "Public IPv4 addresses allowed to reach the database directly, for example yours while you make the first organizer account. Leave empty otherwise."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = { project = "contest-keeper", component = "hub" }
}

variable "registry_password" {
  description = "A GitHub token with read:packages, so the Container App can pull a private image. Leave empty for a public image."
  type        = string
  default     = ""
  sensitive   = true
}

variable "custom_domain" {
  description = "A hostname the Hub also answers on, for example hub.dev.contestkeeper.com. Azure makes and renews its certificate. The DNS records in docs/azure.md must exist before this is applied. Leave empty to use only Azure's own address."
  type        = string
  default     = ""

  validation {
    condition     = var.custom_domain == "" || can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,}$", var.custom_domain))
    error_message = "Use a lowercase hostname such as hub.dev.contestkeeper.com."
  }
}

variable "cloudflare_zone_id" {
  description = "The Cloudflare zone that holds custom_domain. When both are set, Terraform makes the CNAME and the asuid TXT record there; leave empty to make them yourself. Not a secret."
  type        = string
  default     = ""

  validation {
    condition     = var.cloudflare_zone_id == "" || can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "A Cloudflare zone id is 32 lowercase hex characters (domain Overview page, API section)."
  }
}

variable "shared_environment_name" {
  description = "Name of an existing Container Apps environment to run the Hub in, instead of making one. The deploy identity needs the join permission on it (docs/azure.md). Leave empty to make the Hub its own environment."
  type        = string
  default     = ""
}

variable "shared_environment_resource_group" {
  description = "The resource group of shared_environment_name."
  type        = string
  default     = ""

  validation {
    condition     = var.shared_environment_name == "" || var.shared_environment_resource_group != ""
    error_message = "Name the resource group of the shared environment too."
  }
}
