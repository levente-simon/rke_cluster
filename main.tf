terraform {
  backend "http" {
    retry_max      = 15
    retry_wait_min = 10
  }
}

provider "vault" {
  max_lease_ttl_seconds = 3600
}

data "vault_generic_secret" "config" {
  path = "${var.vault_config_path}"
}

module "infra" {
  source   = "github.com/levente-simon/terraform-proxmox-vm"

  pm_api_host         = data.vault_generic_secret.config.data["pm_api_host"]
  pm_api_port         = data.vault_generic_secret.config.data["pm_api_port"]
  pm_api_token_id     = data.vault_generic_secret.config.data["pm_api_token_id"]
  pm_api_token_secret = data.vault_generic_secret.config.data["pm_api_token_secret"]
  dns_server          = data.vault_generic_secret.config.data["dns_server"]
  dns_port            = data.vault_generic_secret.config.data["dns_port"]
  searchdomain        = data.vault_generic_secret.config.data["searchdomain"]
  os_user             = data.vault_generic_secret.config.data["os_user"]
  hosts               = local.cluster_hosts
}

resource "time_sleep" "wait_90_seconds" {
  depends_on      = [ module.infra ]
  create_duration = "90s"
}

module "rke" {
  source                 = "github.com/levente-simon/terraform-rke-cluster"
  module_depends_on      = [ time_sleep.wait_90_seconds ]

  os_user                = data.vault_generic_secret.config.data["os_user"]
  ssh_private_key        = module.infra.ssh_private_key
  cluster_hosts          = local.cluster_hosts
}

module "cluster_tools" {
  module_depends_on              = [ module.rke ]
  source                         = "github.com/levente-simon/terraform-k8s-cluster-tools"

  k8s_host                       = module.rke.cluster_kube_api_server_url
  k8s_client_certificate         = module.rke.cluster_client_cert
  k8s_client_key                 = module.rke.cluster_client_key
  k8s_cluster_ca_certificate     = module.rke.cluster_ca_crt
  longhorn_default_replica_count = 2
  metallb_address_pool           = data.vault_generic_secret.config.data["metallb_address_pool"]
  dns_server                     = data.vault_generic_secret.config.data["dns_server"]
  dns_port                       = data.vault_generic_secret.config.data["dns_port"]
  searchdomain                   = data.vault_generic_secret.config.data["searchdomain"]
}

resource "vault_mount" "transit" {
  path        = data.vault_generic_secret.config.data["vault_unseal_mount_path"]
  type        = "transit"
}

resource "vault_transit_secret_backend_key" "unseal_key" {
  depends_on       = [ vault_mount.transit ]
  backend          = data.vault_generic_secret.config.data["vault_unseal_mount_path"]
  name             = data.vault_generic_secret.config.data["vault_unseal_key_name"]
  deletion_allowed = true
}

resource "vault_policy" "unseal_policy" {
  name       = data.vault_generic_secret.config.data["vault_unseal_policy_name"]
  # policy     = local.vault_unseal_policy
  policy     = <<-EOT
    path "${data.vault_generic_secret.config.data["vault_unseal_mount_path"]}/encrypt/${data.vault_generic_secret.config.data["vault_unseal_key_name"]}" { capabilities = [ "update" ] }
    path "${data.vault_generic_secret.config.data["vault_unseal_mount_path"]}/decrypt/${data.vault_generic_secret.config.data["vault_unseal_key_name"]}" { capabilities = [ "update" ] }
    EOT
}

resource "vault_token" "unseal_token" {
  depends_on = [ vault_policy.unseal_policy,
                 vault_transit_secret_backend_key.unseal_key ]
  renewable  = true
  no_parent  = true
  policies   = [ data.vault_generic_secret.config.data["vault_unseal_policy_name"] ]
}

module "vault" {
  source                     = "github.com/levente-simon/terraform-k8s-vault-cluster"
  module_depends_on          = [ vault_token.unseal_token,
                                 module.cluster_tools ]

  vault_host                 = data.vault_generic_secret.config.data["vault_host"]
  vault_ui_host              = data.vault_generic_secret.config.data["vault_ui_host"]
  k8s_host                   = module.rke.cluster_kube_api_server_url
  k8s_cluster_ca_certificate = module.rke.cluster_ca_crt
  k8s_client_certificate     = module.rke.cluster_client_cert
  k8s_client_key             = module.rke.cluster_client_key
  tls_crt                    = base64decode(data.vault_generic_secret.config.data["vault_tls_crt"])
  tls_key                    = base64decode(data.vault_generic_secret.config.data["vault_tls_key"])
  vault_ha_enabled           = false
  vault_autounseal           = true
  vault_unseal_token         = vault_token.unseal_token.client_token
  vault_unseal_address       = data.vault_generic_secret.config.data["vault_unseal_address"]
  vault_unseal_key_name      = data.vault_generic_secret.config.data["vault_unseal_key_name"]
  vault_unseal_mount_path    = data.vault_generic_secret.config.data["vault_unseal_mount_path"]
}

resource "vault_generic_secret" "k8s_config" {
  path = "${var.vault_k8s_config_path}"

  data_json = <<-EOT
    {
      "ssh_private_key": "${base64encode(module.infra.ssh_private_key)}",
      "cluster_ca_crt": "${base64encode(module.rke.cluster_ca_crt)}",
      "cluster_client_cert": "${base64encode(module.rke.cluster_client_cert)}",
      "cluster_client_key": "${base64encode(module.rke.cluster_client_key)}",
      "cluster_kube_admin_user": "${module.rke.cluster_kube_admin_user}",
      "cluster_kube_api_server_url": "${module.rke.cluster_kube_api_server_url}",
      "cluster_kubeconfig": "${base64encode(module.rke.cluster_kubeconfig)}"
    }
    EOT
}

