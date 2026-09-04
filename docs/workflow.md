# Runbook

## 0. Prereqs (build cluster)

- OpenShift Virtualization + CDI installed; `HyperConverged` healthy.
- Export addon present: `oc get crd virtualmachineexports.export.kubevirt.io`.
- CLI on the machine running Packer: `packer` (>= 1.10), `virtctl`, `podman`,
  `qemu-img`, `oc`.
- A registry repo you can push to, e.g. `quay.io/btenneti/rhel-10-golden`.

## 1. One-time namespace + RBAC

```
oc apply -f bootstrap/packer-builder-rbac.yaml     # creates ns vm-build + Role/RoleBinding
export KUBECONFIG=~/.kube/config                   # a context with rights in vm-build
```

(For an unattended runner, mint a token instead:
`oc create token packer -n vm-build --duration=8h` and build a kubeconfig around it.)

## 2. Import the install ISO

Edit `packer/rhel/rhel-iso.yaml`, set `spec.source.http.url` to the RHEL DVD ISO
(or `virtctl image-upload` it), then:

```
oc apply -n vm-build -f packer/rhel/rhel-iso.yaml
oc wait -n vm-build dv/rhel-10-x86-64-iso --for=condition=Ready --timeout=30m
```

No web server needed for the kickstart — `ks.cfg` is attached to the build VM as an
`OEMDRV`-labelled disk (`media_files` in the template).

## 3. Build + publish

```
cd packer/rhel
export REGISTRY_USERNAME=... REGISTRY_PASSWORD=...
packer init  rhel.pkr.hcl
packer build -var registry=quay.io/btenneti \
             -var image_tag=$(date -u +%Y%m%d%H%M) \
             rhel.pkr.hcl
```

What happens: temp VM boots the ISO in `vm-build`, installer runs from `ks.cfg`, Packer
SSHes in over a port-forward (`127.0.0.1:2020`) and runs provisioners, then the
`post-processor` does `virtctl vmexport` → `qemu-img convert` → `podman build FROM scratch`
→ `podman push ${registry}/rhel-10-golden:${image_tag}`.

Note the `image_tag` you passed.

## 4. Point the cluster at the new image

Edit `clusters/dev/images-values.yaml`:

```yaml
image:
  repo: quay.io/btenneti/rhel-10-golden
  tag: "<image_tag>"        # or: digest: "sha256:..."
```

Confirm `storage.storageClassName` here and `rootDisk.storageClassName` in
`clusters/dev/vm-values.yaml` match this cluster, and set a real `sshAuthorizedKeys`.
Commit + push.

## 5. Wire up Argo CD (first time)

```
oc apply -f bootstrap/argocd-app-vm-images.yaml
oc apply -f bootstrap/argocd-app-vm.yaml
```

`vm-images-dev` creates the `DataImportCron`; CDI imports the containerDisk into a golden PVC
and publishes `DataSource/rhel9` in `vm-images`; `vm-workloads-dev` then creates VMs whose
`dataVolumeTemplates` clone from it.

Check:
```
oc get dataimportcron -n vm-images
oc get datasource rhel9 -n vm-images -o jsonpath='{.status.conditions}'
oc get dv,vmi -n vm-demo
virtctl console rhel9-0 -n vm-demo
```

## 6. Ship a new image later

```
cd packer/rhel && packer build -var registry=quay.io/btenneti \
                               -var image_tag=$(date -u +%Y%m%d%H%M) rhel.pkr.hcl
# bump clusters/dev/images-values.yaml -> image.tag, commit, push
```

`DataImportCron` re-checks on its `schedule` and imports the new tag; a fresh import updates
`DataSource/rhel9`. Existing VMs keep their current clone until recreated; new/replaced VMs
pick up the new image. To force a roll, delete the VM (Argo CD recreates it).

## 7. Add another cluster

1. `mkdir clusters/prod && cp clusters/dev/*.yaml clusters/prod/` — edit storage classes,
   counts, keys.
2. Either copy `bootstrap/argocd-app-*.yaml` with `-prod` names and a `clusters/prod/...`
   value path, or replace `bootstrap/` with an `ApplicationSet` over `clusters/*`.
3. Ensure the `registry-pull` secret exists in `vm-images` on that cluster.
4. `image.tag` stays the SAME as dev — that's the build-once guarantee.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `packer build` hangs at boot | `boot_command` keys/timing wrong for the ISO — watch VNC, adjust `boot_wait` |
| installer errors on kickstart | `ks.cfg` invalid for this RHEL version, or `user`/`rootpw` mismatch with `ssh_*` |
| `vmexport download` fails | export addon/CRD missing, or PVC still `ImportInProgress` |
| `post-processor` push fails | `REGISTRY_USERNAME`/`REGISTRY_PASSWORD` unset or wrong registry path |
| DataImportCron `Progressing` forever | pull secret missing/wrong in `vm-images`, or registry path/tag typo |
| Argo CD stuck `OutOfSync` on DataVolume | missing `ignoreDifferences` (see the Application manifests) |
| VM `WaitingForVolumeBinding` | `rootDisk.storageClassName` wrong for this cluster, or RWX unsupported |
