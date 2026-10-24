terraform {
  required_version = ">= 1.0.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# 1. Grupo de Recursos
resource "azurerm_resource_group" "rg" {
  name     = "rg-loadbalancer-demo"
  location = "South Africa North"
}

# 2. Rede Virtual (VNet) e Sub-rede
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-lb"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "subnet-backend"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# 3. IP Público para o Load Balancer
resource "azurerm_public_ip" "pip_lb" {
  name                = "pip-loadbalancer"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# 4. Azure Load Balancer Standard
resource "azurerm_loadbalancer" "lb" {
  name                = "myLoadBalancer"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "myFrontendIP"
    public_ip_address_id = azurerm_public_ip.pip_lb.id
  }
}

# 5. Backend Pool
resource "azurerm_lb_backend_address_pool" "bepool" {
  loadbalancer_id = azurerm_lb.lb.id
  name            = "myBackendPool"
}

# 6. Health Probe (Sonda de Saúde)
resource "azurerm_lb_probe" "probe" {
  loadbalancer_id = azurerm_lb.lb.id
  name            = "myHealthProbe"
  port            = 80
  protocol        = "Http"
  request_path    = "/"
}

# 7. Regra de Balanceamento de Carga
resource "azurerm_lb_rule" "rule" {
  loadbalancer_id                = azurerm_lb.lb.id
  name                           = "myHTTPRule"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "myFrontendIP"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.bepool.id]
  probe_id                       = azurerm_lb_probe.probe.id
}

# 8. Placas de Rede (NICs) para as 2 VMs (usando count = 2)
resource "azurerm_network_interface" "nic" {
  count               = 2
  name                = "nic-vm-${count.index + 1}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# 9. Associação das NICs ao Backend Pool do Load Balancer
resource "azurerm_network_interface_backend_address_pool_association" "nic_assoc" {
  count                   = 2
  network_interface_id    = azurerm_network_interface.nic[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.bepool.id
}

# 10. Criação das 2 Máquinas Virtuais
resource "azurerm_linux_virtual_machine" "vm" {
  count                 = 2
  name                  = "vm-${count.index + 1}"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  size                  = "Standard_DS1_v2"
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.nic[count.index].id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa.pub") # Certifique-se de ter uma chave SSH válida na sua máquina
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }
  # Script executado no primeiro boot para instalar o Nginx e criar uma página de teste única
  custom_data = base64encode(<<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y nginx
              echo "<h1>Olá do Servidor: VM-${count.index + 1}</h1>" > /var/www/html/index.html
              systemctl restart nginx
              EOF
  )
}