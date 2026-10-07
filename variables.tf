variable "Pricing_Tier" {
  description   = "Target pricing tier (SKU)"
  type          = string
  default       = "premium"
  position      = 1
  allowedValues = ["standard","premium"]
}
variable "workspace" {
  description = "workspaces available in the RG"
  type  =  string
  default = "tf-testing"
  position = 2
  allowedValues = ["terratest-dbx-wvwxty", "tf-testing", "tf-demo", "demoworkspace"]
}
variable "Environment" {
  description   = "Environment tag set on the workspace during the upgrade. Replaces any existing environment tag. Not applied if no upgrade is needed"
  type          = string
  position      = 3
  allowedValues = ["Dev", "Test", "PreProd", "Prod"]
}
