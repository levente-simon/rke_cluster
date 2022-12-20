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
  k8s_config_path        = "${path.root}/${var.k8s_config_path}"
  ssh_private_key        = module.infra.ssh_private_key
  cluster_hosts          = local.cluster_hosts
}

resource "vault_generic_secret" "k8s_config" {
  path = "${var.vault_k8s_config_path}"
  data_json = <<-EOT
    {
      "ssh_private_key": "${module.infra.ssh_private_key}"
      "cluster_ca_crt": "${base64encode(module.rke.cluster_ca_crt)}",
      "cluster_client_cert": "${base64encode(module.rke.cluster_client_cert)}",
      "cluster_client_key": "${base64encode(module.rke.cluster_client_key)}",
      "cluster_kube_admin_user": "${module.rke.cluster_kube_admin_user}",
      "cluster_kube_api_server_url": "${module.rke.cluster_kube_api_server_url}",
      "cluster_kubeconfig": ${base64encode(module.rke.cluster_kubeconfig)}
    }
    EOT
}

