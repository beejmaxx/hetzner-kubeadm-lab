# Hetzner kubeadm lab

A disposable, three-node Kubernetes lab for learning how a cluster is installed
and operated. Terraform provisions the machines; explicit scripts install
containerd, run kubeadm, and configure Calico. You can provision only the VMs
and do the Kubernetes installation yourself.

## What it builds

- Three CAX11 ARM64 VMs running Debian 13 in Helsinki: one control plane and
  two workers.
- A private node network, with only SSH and ICMP allowed through the public
  firewall. The Kubernetes API stays private.
- Kubernetes **1.37.1**, Debian's **containerd 1.7**, and **Calico 3.33.0** using
  VXLAN, the iptables dataplane, and MTU 1400.
- Optional demo workloads for cross-node HTTP, Service routing, DNS, and
  NetworkPolicy enforcement.

| Address range | Purpose |
| --- | --- |
| `10.110.0.0/16` | Private node network; nodes use `.2`, `.3`, `.4` |
| `10.244.0.0/16` | Pod network |
| `10.96.0.0/16` | Service network |

The Service range deliberately uses `/16`: the usual `10.96.0.0/12` would
contain this lab's node network.

## Prerequisites

- A **dedicated Hetzner Cloud project** with a read/write API token, sufficient
  quota, and CAX11 capacity in `hel1`.
- Terraform 1.6+ (below 2.0), Python 3.11+, the `hcloud` CLI, and OpenSSH.
- An SSH key at `~/.ssh/id_ed25519`, with its public key uploaded to the project.
- A local macOS or Linux machine. The original integration tests ran from macOS.

These are real, billable VMs and public IPv4 addresses. Check current Hetzner
pricing before creating them. Stopping VMs does not end billing; destroy the
lab when finished. This is a single-control-plane learning cluster, with no
backups or production availability guarantees.

## Configure credentials

Use a dedicated CLI configuration so ambient credentials for another project
cannot accidentally be used. This command prompts for the token; do not put
its value into a shell command, source file, or Terraform variable:

```sh
mkdir -p "$HOME/.config/hcloud"
env -u HCLOUD_TOKEN hcloud --config "$HOME/.config/hcloud/lab.toml" context create lab
chmod 600 "$HOME/.config/hcloud/lab.toml"
```

The wrappers always select the `lab` context in that file. The Terraform
wrapper loads its token into the provider's environment; it never puts the
token in a Terraform configuration or state variable.

Copy the example and set the **name of the SSH public key already uploaded to
that project**:

```sh
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform/terraform.tfvars:
# ssh_key_name = "my-lab-key"
```

The private key and API token stay outside this repository. Local `.tfvars`,
Terraform state, generated SSH configuration, and host keys are gitignored.

## Build and use the cluster

```sh
./scripts/lab plan             # Review infrastructure changes
./scripts/lab up               # Terraform apply, then bootstrap Kubernetes
./scripts/lab status           # Check nodes, system Pods, and Calico
ssh -F hetzner/ssh_config k8s-cp
```

On the control plane, `kubectl get nodes` works immediately: bootstrap installs
root's kubeconfig there. No administrator kubeconfig is copied to your laptop
or the workers. Terraform apply asks for confirmation; `up --yes` skips it for
explicit unattended runs.

For manual installation practice:

```sh
./scripts/lab infra            # Only create Debian VMs
ssh -F hetzner/ssh_config k8s-cp
# Follow/read the bootstrap files and run the installation yourself.
# Or complete it automatically later:
./scripts/lab bootstrap
```

Scripts regenerate `hetzner/ssh_config` from Terraform outputs. New public IPs
are expected after a rebuild. Use `ssh -F` as above, or add an absolute-path
`Include` to your own SSH config. Host keys are associated with server IDs,
with trust-on-first-use via `accept-new`. The scripts check live server IDs,
names, labels, and addresses before running remote commands.

## Test networking and policies

```sh
./scripts/lab demo
./scripts/lab policy-test
```

`demo` creates two nginx replicas on worker1 and a BusyBox client on worker2.
It tests direct Pod-to-Pod HTTP, DNS, and HTTP through a Service. Placement is
intentional: traffic must cross nodes. This command replaces the named demo
client and any standalone web Pod in `network-lab`.

`policy-test` proves the sequence **allowed → timeout → allowed** by adding and
removing an ingress-deny NetworkPolicy. It checks that the client and web
workload remain healthy and removes the policy on ordinary failure or success.
A policy object being accepted by the API is not proof of enforcement.

## Reset or tear down

Keep the VMs but erase and reinstall Kubernetes:

```sh
./scripts/lab reset-k8s
./scripts/lab bootstrap
```

Reset deletes Kubernetes/runtime data and images, purges packages, and reboots
all three nodes. It is intended only for these dedicated lab machines.

Delete the infrastructure, then recreate it:

```sh
./scripts/lab destroy
./scripts/lab up
```

Both `destroy` and `reset-k8s` require confirmation; `--yes` skips it. Destroy
removes the managed VMs, their automatically allocated primary IPs, firewall,
and network/subnet. It preserves the project and existing SSH public key.
Remaining servers/IPs are listed afterward for inspection. All cluster and
application data on the VMs is lost.

**Keep `terraform/terraform.tfstate` until teardown.** It tracks the objects
Terraform owns. Do not commit it or copy another project's state into this lab.
Terraform only destroys resources it manages, not arbitrary project resources.

## How it is organized

| File | Responsibility |
| --- | --- |
| `terraform/main.tf` | Infrastructure and SSH key lookup |
| `scripts/terraform-lab` | Terraform with the dedicated project's credential |
| `scripts/hcloud-lab` | Project-scoped hcloud commands |
| `scripts/lab` | Lifecycle orchestration and optional integration tests |
| `bootstrap/prepare-node.sh` | Swap, forwarding, containerd, Kubernetes packages |
| `bootstrap/kubeadm-init.yaml` | Control-plane endpoint and cluster CIDRs |
| `bootstrap/calico-installation.yaml` | Private node selection, VXLAN, MTU, policy dataplane |
| `bootstrap/demo.yaml` | Cross-node demo workloads and Service |
| `bootstrap/deny-web.yaml` | Test ingress policy |

Terraform does not run remote-exec provisioners. Infrastructure and guest
configuration are separate so you can inspect or repeat the kubeadm steps.

## Reproducibility and limits

The underlying scripts were tested with two live rebuilds: Kubernetes was
removed and reinstalled on existing VMs, then the infrastructure was destroyed
and recreated from empty Terraform state. Both passed node readiness,
cross-node HTTP, DNS, Service routing, and policy enforcement. The public copy
uses generic project names and contains none of that deployment's credentials,
state, resource inventories, or host keys.

The provider is pinned to 1.68.0 with a committed lockfile; Kubernetes packages
are pinned to `1.37.1-1.1` and held; Calico manifests are pinned to `v3.33.0`.
The Debian image and OS packages can change, as can the demo image tags. This
reproduces the architecture and configuration, not bit-identical disk images.
Upstream packages and release manifests must remain available.

Containerd 1.7's CRI RuntimeConfig warning is expected with this Kubernetes
version. Upgrade the runtime and review its configuration before moving to
Kubernetes 1.38. The preparation script fails if Debian changes containerd to
a different minor version. It explicitly configures systemd cgroups,
`/opt/cni/bin`, and pause image `3.10.2`.

Bootstrap can resume ordinary failures by skipping already initialized/joined
nodes. It is not a Kubernetes upgrade or cluster-migration tool. After a
partial kubeadm initialization or invalid existing membership, reset/rebuild
instead of relying on the presence of `kubelet.conf`.

`import-existing` is available for manually provisioned labs that match these
names, private addresses, and `purpose=k8s-lab` labels. It imports into local
state and displays a plan without applying cloud changes. Review that plan;
provider defaults and imported network attributes can require reconciliation.

## References

- [kubeadm cluster creation](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [Calico operator installation](https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises)
- [Hetzner Terraform provider](https://registry.terraform.io/providers/hetznercloud/hcloud/1.68.0/docs)

## License

MIT. See [LICENSE](LICENSE).
