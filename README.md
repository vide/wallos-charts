# wallos-charts

A Helm chart for the Wallos subscription manager, with persistent storage and optional rclone backups.

![Version: 1.0.0](https://img.shields.io/badge/Version-1.0.0-informational?style=flat-square) ![AppVersion: 5.8.3](https://img.shields.io/badge/AppVersion-5.8.3-informational?style=flat-square)

[Wallos](https://github.com/ellite/Wallos) is a self-hosted personal subscription tracker.

## Prerequisites

- Kubernetes 1.27+ (the backup CronJob uses `spec.timeZone`)
- Helm 3.8+
- A default StorageClass, or `persistence.storageClass` / `persistence.existingClaim`

## Installing the Chart

```bash
helm repo add wallos https://vide.github.io/wallos-charts
helm repo update
helm install wallos wallos/wallos -n wallos --create-namespace \
  --set timezone=Europe/Madrid
```

On first boot Wallos creates its database and you register the admin user in the UI.

## Data

Wallos keeps everything in two directories, both on one PVC (`<fullname>-data`):

| Container path | PVC subdirectory | Content |
|---|---|---|
| `/var/www/html/db` | `db/` | `wallos.db` (SQLite) |
| `/var/www/html/images/uploads/logos` | `logos/` | uploaded subscription logos and avatars |

The PVC is annotated `helm.sh/resource-policy: keep`, so `helm uninstall` leaves it behind.
The Deployment uses the `Recreate` strategy and a single replica: SQLite allows one writer only.

Database migrations run automatically on startup, so upgrading Wallos is a matter of bumping
the chart (or `image.tag`). Take a backup first.

## Backups

With `backup.enabled`, a CronJob takes a consistent online snapshot of the database
(`sqlite3 .backup`), validates it (`PRAGMA integrity_check`, schema present), bundles it with
the logos into `<fullname>-<UTC timestamp>.tar.gz` and uploads it with
[rclone](https://rclone.org) -- so any of rclone's backends works (S3, B2, GCS, Azure, SFTP,
WebDAV, ...). Nothing is uploaded if validation fails.

The rclone remote is configured entirely through environment variables
(`RCLONE_CONFIG_<REMOTE>_<OPTION>`, see the [rclone docs](https://rclone.org/docs/#config-file)),
typically referencing a Secret. Example for Backblaze B2:

```bash
kubectl -n wallos create secret generic wallos-backup \
  --from-literal=account=<keyID> --from-literal=key=<applicationKey>
```

```yaml
backup:
  enabled: true
  schedule: "30 3 * * *"
  destination: b2:my-bucket/wallos
  env:
    - name: RCLONE_CONFIG_B2_TYPE
      value: b2
    - name: RCLONE_CONFIG_B2_ACCOUNT
      valueFrom: { secretKeyRef: { name: wallos-backup, key: account } }
    - name: RCLONE_CONFIG_B2_KEY
      valueFrom: { secretKeyRef: { name: wallos-backup, key: key } }
```

or S3-compatible storage, with every key in one Secret:

```yaml
backup:
  enabled: true
  destination: s3:my-bucket/wallos
  envFrom:
    - secretRef:
        name: wallos-backup   # RCLONE_CONFIG_S3_TYPE=s3, ..._PROVIDER, ..._ACCESS_KEY_ID, ...
```

Archives accumulate; prune them with a lifecycle rule on the backend, or set
`backup.retention.minAge` (e.g. `30d`) to have the job delete older ones itself.

Run a backup now:

```bash
kubectl -n wallos create job --from=cronjob/wallos-backup wallos-backup-manual
```

### Restoring

```bash
# 1. stop Wallos (pause any GitOps self-heal first)
kubectl -n wallos scale deploy/wallos --replicas=0

# 2. a helper pod with the volume mounted
kubectl -n wallos run restore --image=ghcr.io/ellite/wallos:5.8.3 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"restore","image":"ghcr.io/ellite/wallos:5.8.3","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"wallos-data"}}]}}'

# 3. replace db/ and logos/ with the archive's content
rclone cat b2:my-bucket/wallos/wallos-<timestamp>.tar.gz | kubectl -n wallos exec -i restore -- sh -c '
  set -e; mkdir /tmp/r && tar -xzf - -C /tmp/r
  rm -rf /data/db/* /data/logos/*
  cp /tmp/r/wallos.db /data/db/ && cp -a /tmp/r/logos/. /data/logos/
  chown -R 82:82 /data/db /data/logos'

# 4. clean up and start Wallos again; it migrates an older database on boot
kubectl -n wallos delete pod restore
kubectl -n wallos scale deploy/wallos --replicas=1
```

The same procedure imports data from a docker-compose install: tar up its `db/` and `logos/`
volumes and feed them to step 3.

## Upgrading

### From 0.x to 1.0

**0.x never persisted anything.** It mounted the PVC at `/app/storage`, a path Wallos does
not use, so the database lived in the container and was wiped on every pod restart. If an
0.x install currently holds data you care about, copy it out *before* upgrading -- the
upgrade restarts the pod:

```bash
kubectl -n wallos exec deploy/wallos -- tar -C /var/www/html -cf - db images/uploads/logos > wallos-0x.tar
```

1.0 also switches to the standard `app.kubernetes.io/*` labels. A Deployment's selector is
immutable, so delete the old Deployment before upgrading (the PVC is kept):

```bash
kubectl -n wallos delete deploy/wallos
helm upgrade wallos wallos/wallos -n wallos -f values.yaml
```

then restore `wallos-0x.tar` with the procedure above if needed. Other changes:
`replicaCount` is gone (always 1), the image tag defaults to the chart's `appVersion`
instead of `latest`, and `TZ` has its own `timezone` value.

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Davide Ferrari | <vide@fastmail.com> | <https://github.com/vide/wallos-charts> |

## Source Code

* <https://github.com/vide/wallos-charts>
* <https://github.com/ellite/Wallos>

## Requirements

Kubernetes: `>=1.27.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity |
| backup.activeDeadlineSeconds | int | `1800` | Hard time limit for a run, in seconds |
| backup.affinity | object | `{}` | Affinity for the backup job. Defaults to preferring the node running Wallos, where a ReadWriteOnce volume is mountable |
| backup.backoffLimit | int | `1` | Retries before a run is marked failed |
| backup.destination | string | `""` | rclone destination as `<remote>:<path>`, e.g. `b2:my-bucket/wallos`, `s3:bucket/prefix`, `sftp:backups/wallos`. Each run uploads one `<fullname>-<UTC timestamp>.tar.gz` holding `wallos.db` and `logos/` |
| backup.enabled | bool | `false` | Enable the scheduled backup CronJob |
| backup.env | list | `[]` | Environment for rclone. Define the remote named in `destination` with `RCLONE_CONFIG_<REMOTE>_*` variables (see https://rclone.org/docs/#config-file), any other rclone flag as `RCLONE_<FLAG>` |
| backup.envFrom | list | `[]` | Environment for rclone from whole Secrets/ConfigMaps, e.g. one holding all the `RCLONE_CONFIG_*` keys |
| backup.failedJobsHistoryLimit | int | `3` | Failed jobs to keep |
| backup.nodeSelector | object | `{}` | Node selector for the backup job. Defaults to `nodeSelector` |
| backup.podSecurityContext | object | `{"runAsGroup":82,"runAsNonRoot":true,"runAsUser":82,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context for the backup job. It only reads the data volume, so it runs unprivileged as the image's www-data (82) |
| backup.rclone.extraArgs | list | `[]` | Extra arguments for every rclone invocation |
| backup.rclone.image.pullPolicy | string | `"IfNotPresent"` | rclone image pull policy |
| backup.rclone.image.repository | string | `"rclone/rclone"` | rclone image repository |
| backup.rclone.image.tag | string | `"1.75.1"` | rclone image tag |
| backup.resources | object | `{}` | Resources for each backup container |
| backup.retention.minAge | string | `""` | If set, delete archives older than this after each upload (rclone duration, e.g. `30d`). Leave empty to let the backend handle retention, e.g. with bucket lifecycle rules -- on versioned backends such as B2, `rclone delete` only hides files |
| backup.schedule | string | `"30 3 * * *"` | Cron schedule |
| backup.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context for the backup job |
| backup.successfulJobsHistoryLimit | int | `1` | Successful jobs to keep |
| backup.timeZone | string | `""` | CronJob timezone. Defaults to `timezone` |
| backup.tolerations | list | `[]` | Tolerations for the backup job. Defaults to `tolerations` |
| env | list | `[]` | Extra environment variables, e.g. the OIDC_* or SSRF_ALLOWLIST settings documented upstream, or PUID/PGID |
| envFrom | list | `[]` | Extra environment from Secrets/ConfigMaps (e.g. OIDC client credentials) |
| fullnameOverride | string | `""` | Override the full resource name (defaults to the release name, or `<release>-wallos`) |
| image.pullPolicy | string | `"IfNotPresent"` | Container image pull policy |
| image.repository | string | `"ghcr.io/ellite/wallos"` | Container image repository |
| image.tag | string | `""` | Image tag. Defaults to the chart's `appVersion`; avoid `latest`, which makes every pod restart a silent, unreviewed upgrade |
| imagePullSecrets | list | `[]` | Image pull secrets |
| ingress.annotations | object | `{}` | Ingress annotations |
| ingress.className | string | `""` | IngressClass name. Empty uses the cluster default |
| ingress.enabled | bool | `false` | Create an Ingress |
| ingress.hosts | list | `[{"host":"wallos.local","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts |
| ingress.tls | list | `[]` | Ingress TLS configuration |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/health.php","port":"http"},"periodSeconds":30,"timeoutSeconds":3}` | Liveness probe |
| nameOverride | string | `""` | Override the chart name |
| nodeSelector | object | `{}` | Node selector |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes |
| persistence.annotations | object | `{}` | Extra PVC annotations |
| persistence.enabled | bool | `true` | Persist the database and uploaded logos. When disabled an emptyDir is used and ALL DATA IS LOST whenever the pod is replaced |
| persistence.existingClaim | string | `""` | Use an existing PVC instead of creating one. It must contain (or will get) `db/` and `logos/` subdirectories |
| persistence.retain | bool | `true` | Annotate the PVC with `helm.sh/resource-policy: keep` so it survives `helm uninstall` and Argo CD app deletion |
| persistence.size | string | `"1Gi"` | Volume size |
| persistence.storageClass | string | `""` | StorageClass. Empty uses the cluster default; `-` sets `storageClassName: ""` |
| podAnnotations | object | `{}` | Extra pod annotations |
| podLabels | object | `{}` | Extra pod labels |
| podSecurityContext | object | `{}` | Pod security context. The upstream entrypoint must start as root: it remaps the www-data UID/GID (PUID/PGID) and chowns the data directories |
| readinessProbe | object | `{"httpGet":{"path":"/health.php","port":"http"},"periodSeconds":10,"timeoutSeconds":3}` | Readiness probe |
| resources | object | `{"limits":{"memory":"256Mi"},"requests":{"cpu":"20m","memory":"64Mi"}}` | Pod resources. Wallos is a small PHP app; the memory limit guards the node |
| securityContext | object | `{}` | Container security context |
| service.annotations | object | `{}` | Service annotations |
| service.port | int | `80` | Service port |
| service.type | string | `"ClusterIP"` | Service type |
| startupProbe | object | `{"failureThreshold":24,"httpGet":{"path":"/health.php","port":"http"},"periodSeconds":5}` | Startup probe. `/health.php` is a static 200 that touches neither the database nor sessions. Allows ~2 minutes for the first-boot migrations and exchange-rate refresh |
| timezone | string | `"Etc/UTC"` | Timezone for the app and its internal cron jobs (`TZ`), and default for `backup.timeZone` |
| tolerations | list | `[]` | Tolerations |

## Development

[pre-commit](https://pre-commit.com) runs [helm-docs](https://github.com/norwoodj/helm-docs)
to regenerate this README from `values.yaml` and this template:

```bash
pre-commit install
```

CI lints the chart, installs it into a kind cluster, and fails if the README is stale.
Pushing a new `version` in `Chart.yaml` to `main` publishes a release.

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
