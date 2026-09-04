# vm-gitops

Build a golden VM image **once** with Packer (KubeVirt `kubevirt-iso` builder), publish it
to an OCI registry as a containerDisk, and let **CDI + Argo CD** roll it out to one or more
OpenShift Virtualization clusters.

```
packer (kubevirt-iso)  ─build in-cluster─►  qcow2  ─podman─►  registry:<tag>
                                                                  │
                                        DataImportCron per cluster │  (CDI import once)
                                                                  ▼
                                                    golden PVC + DataSource "rhel9"
                                                                  │  (local clone)
                                                                  ▼
                                              VirtualMachine(s)  (Helm chart, synced by Argo CD)
```

Registry is the only thing that crosses clusters. Argo CD ships manifests, never disk images.

## Layout

| Path | What |
|---|---|
| `packer/rhel/` | Upstream `kubevirt-iso` example (`hashicorp/packer-plugin-kubevirt`) + containerDisk export post-processor from the [kubevirt.io walkthrough](https://kubevirt.io/2025/Building-VM-golden-image-with-Packer.html). See `packer/README.md`. |
| `charts/vm-images/` | Helm chart: namespace + `DataImportCron` that pulls the registry image into a golden PVC / `DataSource` |
| `charts/vm/` | Helm chart: the `VirtualMachine`(s) that clone from the `DataSource` |
| `clusters/dev/` | per-cluster values (`images-values.yaml`, `vm-values.yaml`) — add `clusters/prod/` etc. later |
| `bootstrap/` | Argo CD `Application`s + the one-time Packer RBAC manifest |
| `docs/workflow.md` | end-to-end runbook |

Single cluster today. Multi-cluster later = add `clusters/<name>/` value files and either
duplicate the `Application`s or switch `bootstrap/` to an `ApplicationSet` cluster generator.
Nothing else changes; `image.tag` stays identical across every cluster.

## One-time setup

1. Install **OpenShift Virtualization** + **CDI**; confirm a working `StorageClass` and that
   the export addon is present (`oc get crd virtualmachineexports.export.kubevirt.io`).
2. Build namespace + RBAC (build cluster):
   ```
   oc apply -f bootstrap/packer-builder-rbac.yaml
   ```
3. Put a registry pull secret named `registry-pull` in the `vm-images` namespace of each
   consumer cluster (use Sealed Secrets / External Secrets — do **not** commit it).

## Build an image

See `packer/README.md`. Short version:

```
export KUBECONFIG=~/.kube/config
cd packer/rhel
# set the ISO url in rhel-iso.yaml, then:
oc apply -n vm-build -f rhel-iso.yaml
export REGISTRY_USERNAME=... REGISTRY_PASSWORD=...
packer init  rhel.pkr.hcl
packer build -var registry=quay.io/btenneti \
             -var image_tag=$(date -u +%Y%m%d%H%M) \
             rhel.pkr.hcl
```

The post-processor pushes `quay.io/btenneti/rhel-10-golden:<tag>`.

## Deploy

```
oc apply -f bootstrap/argocd-app-vm-images.yaml
oc apply -f bootstrap/argocd-app-vm.yaml
```

Argo CD (auto-sync) creates the `DataImportCron`; CDI imports the image into a golden PVC and
publishes `DataSource/rhel9`; the VM chart then brings up VMs that clone from it.

## Promote a new image

Set `image.tag` (or pin `image.digest`) in `clusters/<cluster>/images-values.yaml` to the tag
you just pushed, commit, push. The `DataImportCron` picks it up on its schedule.

## Notes / assumptions

- The Packer builder block, `ks.cfg`, and `rhel-iso.yaml` are copied **verbatim** from
  `hashicorp/packer-plugin-kubevirt`. Only variable values and the export post-processor
  were added — see the header of `packer/rhel/rhel.pkr.hcl` for provenance.
- The builder's output is a PVC **in the build cluster**; the post-processor does the
  `virtctl vmexport` → `podman build/push`.
- `containerDisk` is consumed only as a **DataVolume source** (persistent clone), never as an
  ephemeral `containerDisk` volume.
