terraform {
  required_version = ">= 1.6.0, < 2.0.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.68.0"
    }
  }
}

# The wrapper supplies HCLOUD_TOKEN from the saved lab context.
provider "hcloud" {}

variable "ssh_key_name" {
  type        = string
  description = "Name of your existing SSH public key in the dedicated Hetzner project."
}

variable "ssh_source_cidrs" {
  description = "Public SSH sources; matches the current lab. Narrow if desired."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

locals {
  nodes = {
    k8s-cp      = { ip = "10.110.0.2", role = "control-plane" }
    k8s-worker1 = { ip = "10.110.0.3", role = "worker" }
    k8s-worker2 = { ip = "10.110.0.4", role = "worker" }
  }
}

# Reuse the existing public key. Destroying the lab does not delete it.
data "hcloud_ssh_key" "admin" {
  name = var.ssh_key_name
}

resource "hcloud_network" "lab" {
  name     = "lab-k8s"
  ip_range = "10.110.0.0/16"
  labels   = { purpose = "k8s-lab" }
}

resource "hcloud_network_subnet" "lab" {
  network_id   = hcloud_network.lab.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.110.0.0/24"
}

resource "hcloud_firewall" "lab" {
  name   = "lab-k8s"
  labels = { purpose = "k8s-lab" }
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.ssh_source_cidrs
    description = "SSH key access for lab administration"
  }
  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Lab network diagnostics"
  }
}

resource "hcloud_server" "node" {
  for_each     = local.nodes
  name         = each.key
  server_type  = "cax11"
  location     = "hel1"
  image        = "debian-13"
  ssh_keys     = [data.hcloud_ssh_key.admin.id]
  backups      = false
  firewall_ids = [hcloud_firewall.lab.id]
  labels       = { purpose = "k8s-lab", role = each.value.role }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }
  network {
    network_id = hcloud_network.lab.id
    ip         = each.value.ip
    alias_ips  = []
  }
  depends_on = [hcloud_network_subnet.lab]

  # Hetzner does not return the originally injected SSH keys on import.
  # Changes to keys require an explicit rebuild, not accidental replacement.
  lifecycle {
    ignore_changes = [ssh_keys]
  }
}

output "nodes" {
  value = {
    for name, server in hcloud_server.node : name => {
      id         = server.id
      public_ip  = server.ipv4_address
      private_ip = local.nodes[name].ip
    }
  }
}
