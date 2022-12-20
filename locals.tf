locals {
  exec =  [
    "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for boot-finished...'; sleep 5; done",
    "sudo grep -Elrs 'AllowTcpForwarding .*$' /etc/ssh | while read cfg; do sudo sed -ri 's/(AllowTcpForwarding .*$)/# \\1/' $cfg; done",
    "echo 'AllowTcpForwarding yes' | sudo tee /etc/ssh/sshd_config.d/k8s.conf",
    "sudo systemctl restart ssh"
  ]
  
  cluster_hosts = {
    k8s-mg-01 = {
      id                 = 1
      fqdn               = "k8s-mg-01.corp"
      roles              = ["controlplane", "worker", "etcd"]
      description        = "Kube mgmt 01"
      pm_node            = "cow01"
      template_name      = "ubuntu-22.04-docker-tmpl"
      ip                 = "192.168.20.131"
      mask               = "24"
      gw                 = "192.168.20.1"
      vlan_id            = "20"
      storage_size       = "100G"
      memory             = "6144"
      sockets            = 2
      cores              = 2
      exec               = local.exec
    }
    k8s-mg-02 = {
      id                 = 2
      fqdn               = "k8s-mg-02.corp"
      roles              = ["worker"]
      description        = "Kube mgmt 02"
      pm_node            = "cow01"
      template_name      = "ubuntu-22.04-docker-tmpl"
      ip                 = "192.168.20.132"
      mask               = "24"
      gw                 = "192.168.20.1"
      vlan_id            = "20"
      storage_size       = "100G"
      memory             = "6144"
      sockets            = 2
      cores              = 2
      exec               = local.exec
    }
  }
}

