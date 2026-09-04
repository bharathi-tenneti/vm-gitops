# Golden RHEL image built on OpenShift Virtualization / KubeVirt with the
# official HashiCorp `kubevirt-iso` builder.
#
# Provenance (keep the builder block as upstream; only the variables differ):
#   * source "kubevirt-iso" block, ks.cfg, rhel-iso.yaml
#       -> github.com/hashicorp/packer-plugin-kubevirt
#          examples/builder/kubevirt-iso/rhel   (verbatim)
#   * variable "namespace" / "name" / registry vars and the
#     post-processor "shell-local" export-to-containerDisk block
#       -> https://kubevirt.io/2025/Building-VM-golden-image-with-Packer.html
#
# Run:
#   export KUBECONFIG=~/.kube/config
#   # edit rhel-iso.yaml -> set the ISO url, then:
#   kubectl apply -n vm-build -f rhel-iso.yaml
#   packer init  rhel.pkr.hcl
#   packer build -var registry=quay.io/btenneti \
#                -var image_tag=$(date -u +%Y%m%d%H%M) \
#                rhel.pkr.hcl

packer {
  required_plugins {
    kubevirt = {
      source  = "github.com/hashicorp/kubevirt"
      version = ">= 0.8.0"
    }
  }
}

variable "kube_config" {
  type    = string
  default = "${env("KUBECONFIG")}"
}

variable "namespace" {
  type    = string
  default = "vm-build"
}

variable "name" {
  type    = string
  default = "rhel-10-golden"
}

variable "registry" {
  type    = string
  default = "quay.io/btenneti"
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "registry_username" {
  type    = string
  default = "${env("REGISTRY_USERNAME")}"
}

variable "registry_password" {
  type      = string
  default   = "${env("REGISTRY_PASSWORD")}"
  sensitive = true
}

source "kubevirt-iso" "rhel" {
  # Kubernetes configuration
  kube_config = var.kube_config
  name        = var.name
  namespace   = var.namespace

  # ISO configuration
  iso_volume_name = "rhel-10-x86-64-iso"

  # VM type and preferences
  disk_size          = "10Gi"
  instance_type      = "o1.medium"
  instance_type_kind = "virtualmachineclusterinstancetype" # or "virtualmachineinstancetype"
  preference         = "rhel.10"
  preference_kind    = "virtualmachineclusterpreference" # or "virtualmachinepreference"
  os_type            = "linux"

  # Files to include in the ISO installation
  media_files = [
    "./ks.cfg"
  ]

  # Boot process configuration
  # A set of commands to send over VNC connection
  boot_command = [
    "<up>e",                            # Modify GRUB entry
    "<down><down><end>",                # Navigate to kernel line
    " inst.ks=hd:LABEL=OEMDRV:/ks.cfg", # Set kickstart file location
    "<leftCtrlOn>x<leftCtrlOff>"        # Boot with modified command line
  ]
  boot_wait                 = "10s"     # Time to wait after boot starts
  installation_wait_timeout = "15m"     # Timeout for installation to complete

  # SSH configuration
  communicator     = "ssh"
  ssh_host         = "127.0.0.1"
  ssh_local_port   = 2020
  ssh_remote_port  = 22
  ssh_username     = "user"
  ssh_password     = "root"
  ssh_wait_timeout = "20m"
}

build {
  sources = ["source.kubevirt-iso.rhel"]

  provisioner "shell" {
    inline = [
      "echo 'Install packages / configure services here, or swap in an ansible provisioner.'"
    ]
  }

  # --- Export the built PVC and publish it as a containerDisk ---
  # Verbatim command pattern from
  # https://kubevirt.io/2025/Building-VM-golden-image-with-Packer.html
  post-processor "shell-local" {
    inline = [
      "virtctl -n ${var.namespace} vmexport download ${var.name}-export --pvc=${var.name} --output=${var.name}.img.gz",
      "gunzip -k ${var.name}.img.gz",
      "qemu-img convert -c -O qcow2 ${var.name}.img ${var.name}.qcow2",
      "echo 'FROM scratch' > ${var.name}.Containerfile",
      "echo 'COPY ${var.name}.qcow2 /disk/' >> ${var.name}.Containerfile",
      "podman login -u ${var.registry_username} -p ${var.registry_password} ${var.registry}",
      "podman build -t ${var.registry}/${var.name}:${var.image_tag} -f ${var.name}.Containerfile .",
      "podman push ${var.registry}/${var.name}:${var.image_tag}"
    ]
  }
}
