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
