# =============================================================================
#  vm/main.tf - run the heliograph agent on a VM, no container at all
# =============================================================================
#  The Terraform twin of vm/main.bicep. Same shape, same traps, same result -
#  see that file's header for the full reasoning. Creates a NIC and a VM and
#  nothing else: no data disk, no load balancer, no public IP.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "name" {
  description = "Name for the VM (also becomes its hostname and NIC/OS-disk name prefix)."
  type        = string
  default     = "vm-heliograph"
}

variable "location" {
  description = "Location."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group to deploy into."
  type        = string
}

variable "vnetName" {
  description = "Existing VNet."
  type        = string
}

variable "subnetName" {
  description = "Existing subnet. No delegation needed - a VM NIC is not a delegated workload."
  type        = string
}

variable "repoUrl" {
  description = "The transport repo to clone, https:// or git@."
  type        = string
}

variable "gitToken" {
  description = "Token for an https:// transport repo. Leave empty for a public repo or an ssh:// remote."
  type        = string
  default     = ""
  sensitive   = true
}

variable "gitTokenUser" {
  description = "Basic username for the token. GitHub wants x-access-token, GitLab oauth2, Azure DevOps empty."
  type        = string
  default     = ""
}

variable "image" {
  description = "VM OS image URN (publisher:offer:sku:version). NOT a container image - see main.bicep's matching comment for why this parameter's meaning changes on this one host."
  type        = string
  default     = "Canonical:ubuntu-24_04-lts:server:latest"
}

variable "startArgs" {
  description = "Arguments for start.sh, and after --, for agent.sh."
  type        = list(string)
  default     = []
}

variable "cpu" {
  description = "Accepted for parameter parity with the other hosts in this PR, but NOT actionable here: sizing comes from vmSize (below)."
  type        = number
  default     = 1
}

variable "memory" {
  description = "See cpu above: not actionable for this host, kept only for parameter parity."
  type        = number
  default     = 1
}

variable "vmSize" {
  description = "VM size. B1s (1 vCPU, 1 GiB) is the cheapest size that can run bash, git and a small agent loop."
  type        = string
  default     = "Standard_B1s"
}

variable "adminUsername" {
  description = "Admin username for SSH access."
  type        = string
  default     = "azureuser"
}

variable "adminSshPublicKey" {
  description = "SSH public key for adminUsername."
  type        = string
}

data "azurerm_subnet" "this" {
  name                 = var.subnetName
  virtual_network_name = var.vnetName
  resource_group_name  = var.resource_group_name
}

locals {
  image_parts = split(":", var.image)

  cloud_init_filled = replace(
    replace(
      replace(
        replace(
          file("${path.module}/cloud-init.sh"),
          "__REPO_URL__", var.repoUrl
        ),
        "__GIT_TOKEN__", var.gitToken
      ),
      "__GIT_TOKEN_USER__", var.gitTokenUser
    ),
    "__START_ARGS__", join(" ", var.startArgs)
  )
}

resource "azurerm_network_interface" "this" {
  name                = "${var.name}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = data.azurerm_subnet.this.id
    private_ip_address_allocation = "Dynamic"
    # No public_ip_address_id at all - see main.bicep's header. Nothing
    # reaches this VM from outside the VNet.
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.vmSize
  admin_username      = var.adminUsername
  network_interface_ids = [
    azurerm_network_interface.this.id,
  ]

  disable_password_authentication = true
  admin_ssh_key {
    username   = var.adminUsername
    public_key = var.adminSshPublicKey
  }

  # Cloud-init reads custom_data on first boot only - see main.bicep's
  # header on why this VM is meant to be replaced, not reconfigured in
  # place, exactly like every other host in this PR.
  custom_data = base64encode(local.cloud_init_filled)

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    # No separate data disk - the OS disk is deleted with the VM, which is
    # the right default for a host whose whole story is "nothing here
    # needs to survive a rebuild".
  }

  source_image_reference {
    publisher = local.image_parts[0]
    offer     = local.image_parts[1]
    sku       = local.image_parts[2]
    version   = local.image_parts[3]
  }
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.this.name
}

output "run_command" {
  value = "az vm run-command invoke -g ${var.resource_group_name} -n ${azurerm_linux_virtual_machine.this.name} --command-id RunShellScript --scripts \"journalctl -u heliograph -n 100 --no-pager\""
}
