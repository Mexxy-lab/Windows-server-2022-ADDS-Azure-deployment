
subscription_id     = "007f175d-86d2-4836-9a1f-f752ee43f8aa"
location            = "East US"
resource_group_name = "pumej-ad-lab-rg"
project_name        = "pumej-ad"
domain_name         = "pumejlab.com"
netbios_name        = "PUMEJLAB"

vnet_address_space    = ["10.20.0.0/16"]
subnet_address_prefix = "10.20.1.0/24"

# Replace with your current trusted public IPv4 address and /32.
admin_cidr = "104.9.152.207/32"

deploy_client   = true
vm_size         = "Standard_B2ms"
admin_username  = "labadmin"
os_disk_size_gb = 60
