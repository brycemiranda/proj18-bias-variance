This directory contains the ArgoCD deployment path for the recovered `proj18` stack.

The intended grading flow is:

1. Run the Chameleon Jupyter notebook only until the VM is created, Docker and K3s are installed, the persistent block volume is attached, and this repository is cloned.
2. SSH into the VM.
3. Run one command: `bash scripts/bootstrap-argocd.sh`

This recovery-mode path assumes the persisted MinIO, MLflow, and Postgres state already exists on the attached block volume, including the trained `production/tag_to_vector.pkl`. It does not require Kaggle ingestion.

## TA Rebuild Steps

### 1. Provision infrastructure from the notebook

In `integration_chameleon_setup_iac1.ipynb`:

- create a new lease and VM
- attach the persistent block volume
- install Docker and K3s
- clone this repository

Stop after the clone step. Do not use the notebook to deploy Kubernetes workloads.

### 2. SSH into the VM

```bash
ssh cc@<floating-ip>
cd /home/cc/proj18-bias-variance
git checkout <submission-branch>
git pull --ff-only
```

The branch used here must already be pushed to GitHub. ArgoCD will pull the same branch directly from the remote repository.

### 3. Create the bootstrap secrets file

Create `scripts/secrets.env` with the recovery-mode bootstrap values:

```bash
cat > scripts/secrets.env <<'EOF'
DB_USERNAME=mealie
DB_PASSWORD=mealie_pass
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=minioadmin123
GRAFANA_ADMIN_PASSWORD=admin123
EOF
```

Kaggle credentials are not required for this path.

### 4. Verify the recovered block volume

```bash
lsblk
sudo mkdir -p /mnt/block
sudo mount /dev/vdb1 /mnt/block || true
ls /mnt/block
```

If the recovered filesystem is present, continue.

### 5. Run the ArgoCD bootstrap

```bash
bash scripts/bootstrap-argocd.sh
```

The script performs the full deployment:

1. mounts the block volume for K3s local-path storage
2. creates namespaces and secrets
3. builds the local project images and imports them into K3s
4. installs ArgoCD
5. creates ArgoCD Applications for `core`, `platform`, `serving`, `data`, `training`, `mealie`, and `monitoring`
6. waits for the critical rollouts to finish

### 6. Verify the system

```bash
kubectl get applications -n argocd
kubectl get pods -A
kubectl get svc -A
```

Expected URLs:

- ArgoCD: `https://<floating-ip>:30443`
- Mealie: `http://<floating-ip>:30090`
- Inference API: `http://<floating-ip>:30800/health`
- MLflow: `http://<floating-ip>:30500`
- MinIO API: `http://<floating-ip>:30900`
- MinIO UI: `http://<floating-ip>:30901`
- Prometheus: `http://<floating-ip>:30091`
- Grafana: `http://<floating-ip>:30300`
- Alertmanager: `http://<floating-ip>:30903`

To get the ArgoCD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo
```

### 7. Verify serving uses the persisted production artifact

```bash
curl http://<floating-ip>:30800/health
```

The response should show:

- `"status":"ok"`
- `"artifact_source":"minio"`
- `"artifact_key":"production/tag_to_vector.pkl"`

## Notes

- This path is recovery-oriented. It intentionally does not run Food.com ingestion, batch bootstrap, or initial ALS retraining.
- If the ArgoCD path fails during grading, the imperative fallback remains `bash scripts/bootstrap.sh`.
