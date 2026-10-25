# Runbook: remove the sealed-secrets-controller from a WAMP cluster

## Why

WAMP secrets moved from Bitnami SealedSecrets to SOPS, decrypted in Argo CD
through KSOPS (DDO-1946). The `sealed-secrets` ApplicationSet, its controller,
its CRD and its sealing key are no longer used, but deleting the
ApplicationSet alone does not remove them: the generated Application has no
`resources-finalizer.argocd.argoproj.io`, so the workload, RBAC and CRD are
orphaned rather than pruned. This runbook removes them by hand, in the order
below, on one cluster at a time.

## Clusters

| Cluster      | Branch              |
| ------------ | -------------------|
| wamp-nonprod | `release/dev`        |
| wamp-prod    | `release/production` |

Do **wamp-nonprod first**. Only start on wamp-prod once every check in
"Done" below holds for wamp-nonprod.

## Precondition — stop if any SealedSecret remains

Before anything else is deleted, confirm no `SealedSecret` object is left on
the cluster:

```sh
kubectl get sealedsecrets -A
```

- If this returns any object, **stop here**. Do not continue, and do not
  delete the CRD later — deleting the CRD while a `SealedSecret` still
  exists cascades through its `ownerReferences` and deletes the `Secret` it
  produced. Migrate the object to SOPS under DDO-1946 first, then re-run this
  check.
- If the command errors because the CRD is already gone, treat that the same
  way: stop and find out what happened to any Secrets it was managing before
  going further.
- Only continue once this returns no resources.

## Step 1 — merge and let the app-of-apps prune

Merge the MR that removes the `sealed-secrets` ApplicationSet file
(`applications/applicationsets/sealed-secrets.yaml`) into the cluster's
branch, and wait for the app-of-apps that syncs `applications/applicationsets/`
(with prune) to pick it up.

Confirm the ApplicationSet and the Application it generated are both gone:

```sh
argocd appset get sealed-secrets
argocd app get local-sealed-secrets
```

Both commands should report "not found" before moving on.

## Step 2 — remove the orphaned controller resources

Select everything by the Helm release label
(`app.kubernetes.io/instance=sealed-secrets`), not by name, so nothing the
chart created is missed. Every command uses `--ignore-not-found` so the step
is safe to run again if it is interrupted or partially cleaned up already.

Namespaced resources, in `kube-system`:

```sh
kubectl delete deployment,service,serviceaccount,role,rolebinding \
  -n kube-system -l app.kubernetes.io/instance=sealed-secrets --ignore-not-found
```

Cluster-scoped resources:

```sh
kubectl delete clusterrole,clusterrolebinding \
  -l app.kubernetes.io/instance=sealed-secrets --ignore-not-found
```

## Step 3 — back up the sealing key, then delete it

Back up the sealing key Secret(s) to a file on your own machine, **outside
git**, before deleting anything:

```sh
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > ~/sealed-secrets-key-backup-<cluster-name>-<date>.yaml
```

Check the file is valid YAML and holds every key before deleting anything:

```sh
kubectl apply --dry-run=client -f ~/sealed-secrets-key-backup-<cluster-name>-<date>.yaml
grep -c '^kind: Secret' ~/sealed-secrets-key-backup-<cluster-name>-<date>.yaml
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o name | wc -l
```

The two counts above must match. Only once they do, delete the Secrets from
the cluster:

```sh
kubectl delete secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key --ignore-not-found
```

Keep the backup file on an encrypted disk and limit who can read it — it
holds the plaintext private key. It is not committed to git, and this ticket
does not store it anywhere else (e.g. a secrets manager or vault); that is
separate work if it's ever needed.

## Step 4 — delete the CRD last

Only after Steps 1–3 are done:

```sh
kubectl delete crd sealedsecrets.bitnami.com --ignore-not-found
```

## Done — verify and record the result in the MR

All of the following must hold before this cluster counts as done:

- No pod, Deployment or Service in `kube-system` carries
  `app.kubernetes.io/instance=sealed-secrets`:
  ```sh
  kubectl get pod,deployment,service -n kube-system -l app.kubernetes.io/instance=sealed-secrets
  ```
  (expect no resources)
- The CRD is gone:
  ```sh
  kubectl get crd sealedsecrets.bitnami.com
  ```
  (expect "not found")
- No `sealed-secrets-key*` Secret is left:
  ```sh
  kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key
  ```
  (expect no resources)
- Every Argo CD Application on the cluster is `Synced`/`Healthy`:
  ```sh
  argocd app list
  ```
- The Secrets KSOPS generates still exist with the same data, e.g.:
  ```sh
  kubectl get secret -n apisix-system
  kubectl get secret -n kube-prometheus-stack
  kubectl get secret -n logging
  kubectl get secret -n datadog
  ```

Record which checks passed (and on which cluster) in the MR before opening
the next one — wamp-prod is only started once wamp-nonprod passes all of the
above.
