# packer/

Not hand-written. `rhel/` is the official example from
**[hashicorp/packer-plugin-kubevirt](https://github.com/hashicorp/packer-plugin-kubevirt)**
(`examples/builder/kubevirt-iso/rhel`), with the export-to-containerDisk `post-processor`
from the KubeVirt.io walkthrough
**[Building VM golden images with Packer](https://kubevirt.io/2025/Building-VM-golden-image-with-Packer.html)**.

```
rhel/
├── rhel.pkr.hcl    builder (upstream) + variables & post-processor (kubevirt.io blog)
├── ks.cfg          kickstart (upstream, verbatim) — delivered via OEMDRV label, no web server
└── rhel-iso.yaml   DataVolume that imports the install ISO (upstream, verbatim)
```

## How it works

`packer build` creates a temp VM in namespace `vm-build`, boots the RHEL DVD, drives the
installer over VNC (`boot_command`) with `ks.cfg` attached as an `OEMDRV`-labelled disk,
then SSHes in over a port-forward (`127.0.0.1:2020`) to run provisioners. The
`post-processor` exports the resulting PVC with `virtctl vmexport`, wraps the qcow2
`FROM scratch` as a containerDisk, and pushes it to `${registry}/${name}:${image_tag}`.

## Run

```sh
# 1. Prereqs on the build cluster: OpenShift Virtualization + CDI, and the
#    virtualmachineexports CRD (export addon). Log in and:
export KUBECONFIG=~/.kube/config
oc new-project vm-build      # or: oc apply -f ../bootstrap/packer-builder-rbac.yaml

# 2. Set the ISO URL in rhel/rhel-iso.yaml, then import it:
cd rhel
oc apply -n vm-build -f rhel-iso.yaml
oc wait -n vm-build dv/rhel-10-x86-64-iso --for=condition=Ready --timeout=30m

# 3. Build + publish (image_tag becomes the version you pin in clusters/<c>/images-values.yaml):
export REGISTRY_USERNAME=... REGISTRY_PASSWORD=...
packer init  rhel.pkr.hcl
packer build -var registry=quay.io/btenneti \
             -var image_tag=$(date -u +%Y%m%d%H%M) \
             rhel.pkr.hcl
```

Then set `image.repo`/`image.tag` in `clusters/<cluster>/images-values.yaml` to the
`quay.io/btenneti/rhel-10-golden:<tag>` you just pushed, commit, and let Argo CD sync.

## Tuning notes

- `preference = "rhel.10"` / `instance_type = "o1.medium"` are cluster instancetypes —
  adjust to what `oc get virtualmachineclusterpreference,virtualmachineclusterinstancetype`
  shows.
- `ssh_username = "user"` / `ssh_password = "root"` match the `user` line in `ks.cfg`.
  Change both together.
- `boot_command` timing is install-media specific; watch the VNC console if it stalls.
- For real provisioning, replace the inline `shell` provisioner with an `ansible` one.
