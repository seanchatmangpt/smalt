# Fixture: variable interpolation -> typed unresolved, plus an unsupported type
variable "env" {
  type    = string
  default = "dev"
}

resource "azurerm_servicebus_namespace_queue" "interp" {
  name           = "interp-queue"
  namespace_name = "sb-${var.env}"
  max_delivery_count = 10
}

resource "azurerm_linux_virtual_machine" "vm" {
  name = "not-supported"
}
