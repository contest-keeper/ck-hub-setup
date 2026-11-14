variable "name" {
  description = "Short name used in resource names. Lowercase letters and digits, at most 14."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,14}$", var.name))
    error_message = "Use 3 to 14 lowercase letters or digits."
  }
}

variable "resource_group_name" {
  description = "The resource group bootstrap.sh made for this environment. Everything is created inside it, in its region."
  type        = string
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = { project = "contest-keeper", component = "website" }
}
