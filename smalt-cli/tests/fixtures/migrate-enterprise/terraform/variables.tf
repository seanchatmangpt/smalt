# ------------------------------------------------------------------------------
# orders-payments-inventory platform -- shared variables (Fortune-5 demo estate)
# ------------------------------------------------------------------------------

variable "environment" {
  type    = string
  default = "prod"
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "resource_group" {
  type    = string
  default = "rg-orders-prod"
}
