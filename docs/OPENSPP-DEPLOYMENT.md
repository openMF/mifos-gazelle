# OpenSPP Deployment Guide (GAZ-195)

This guide explains how to deploy OpenSPP as part of Mifos Gazelle.

---

## Overview

OpenSPP (Social Safety Net Platform) is integrated into Mifos Gazelle as a new DPG (Digital Public Good) that shares the existing infrastructure layer.

**Key Features:**
- Shares PostgreSQL, Redis, MinIO, Elasticsearch, NGINX, and Kafka with Mifos
- Lightweight deployment (~3GB RAM, ~10GB disk)
- Accessible at: `https://openspp.mifos.gazelle.test`
- Default credentials: `admin / admin`

---

## Prerequisites

**Hardware Requirements:**
- 19GB RAM (Mifos: 16GB + OpenSPP: 3GB)
- 60GB free disk space
- Ubuntu 22.04 or 24.04 LTS (primary tested platform)
- macOS with 16GB+ RAM (Colima k3s)

**Software:**
- Docker & Docker Compose
- Kubernetes cluster (k3s on Linux or Colima on macOS)
- Helm 3.14.4+
- kubectl 1.30.0+

---

## Deployment

### Quick Start

Enable OpenSPP in `config/config.ini`:

```ini
[openspp]
enabled = true
```

Then deploy with all components:

```bash
sudo ./run.sh -u $USER -m deploy -a all
```

Or deploy OpenSPP only (assumes infra already running):

```bash
sudo ./run.sh -u $USER -m deploy -a openspp
```

### Full Deployment Flow

```
1. Deploy Infrastructure
   └─ PostgreSQL, Redis, MinIO, Elasticsearch, NGINX, Kafka

2. Initialize OpenSPP Database
   └─ Create openspp database
   └─ Create openspp user with password
   └─ Enable PostGIS extension

3. Deploy OpenSPP via Helm
   └─ Create openspp namespace
   └─ Create secrets (DB password, admin password)
   └─ Deploy Odoo + supporting services
   └─ Configure ingress at openspp.mifos.gazelle.test

4. Wait for Pod Readiness
   └─ Poll until openspp pod is Running

5. Display Info
   └─ Show access URLs and credentials
```

---

## Configuration

All OpenSPP settings are in `config/config.ini` under the `[openspp]` section:

| Setting | Default | Description |
|---------|---------|-------------|
| `enabled` | `false` | Enable/disable OpenSPP deployment |
| `namespace` | `openspp` | Kubernetes namespace |
| `repo` | (GitHub URL) | OpenSPP docker repo |
| `branch` | `main` | Repository branch |
| `docker_repo` | `ghcr.io/openspp` | Docker image repository |
| `version` | `latest` | Docker image tag |
| `domain_suffix` | `mifos.gazelle.test` | Ingress domain |
| `admin_user` | `admin` | Odoo admin username |
| `db_host` | (shared PostgreSQL) | Database host |
| `db_port` | `5432` | Database port |
| `db_name` | `openspp` | Database name |
| `db_user` | `openspp` | Database user |
| `cpu_limit` | `1000m` | CPU limit |
| `memory_limit` | `2Gi` | Memory limit |
| `cpu_request` | `500m` | CPU request |
| `memory_request` | `1Gi` | Memory request |

---

## Architecture

### Helm Chart Structure

```
src/deployer/helm/openspp/
├── Chart.yaml                # Chart metadata
├── values.yaml               # Default configuration
└── templates/
    ├── deployment.yaml       # Odoo Kubernetes deployment
    ├── service.yaml          # Internal service
    ├── serviceaccount.yaml   # RBAC
    ├── configmap.yaml        # Odoo configuration
    ├── ingress.yaml          # NGINX ingress
    └── _helpers.tpl          # Template helpers
```

### Kubernetes Resources Created

**Namespace:** `openspp`

**Deployment:** `openspp`
- Container: OpenSPP Odoo (ghcr.io/openspp:latest)
- Port: 8069
- Replicas: 1
- Resource limits: 1 CPU, 2GB RAM
- Init container: waits for PostgreSQL readiness

**Service:** `openspp` (ClusterIP)
- Internal: `openspp.openspp.svc.cluster.local:8069`
- Allows other services to communicate with OpenSPP

**Ingress:** `openspp`
- URL: `https://openspp.mifos.gazelle.test`
- Routes to `openspp:8069`
- TLS: Uses NGINX default certificate

**ConfigMap:** `openspp`
- Mounts Odoo configuration file

**ServiceAccount:** `openspp`
- Minimal RBAC (can read configmaps, etc.)

**Secrets:**
- `openspp-db-secret` - PostgreSQL password
- `openspp-admin-secret` - Odoo admin password

---

## Accessing OpenSPP

### Web UI

**URL:** `https://openspp.mifos.gazelle.test`

**Default Credentials:**
- Username: `admin`
- Password: `admin`

**Note:** Accept the self-signed certificate warning on first visit.

### Database Access

Connect to OpenSPP database:

```bash
# Port-forward PostgreSQL
kubectl port-forward -n infra svc/postgresql 5432:5432

# Connect from local machine
psql -h localhost -U openspp -d openspp -W
```

### Logs

View OpenSPP deployment logs:

```bash
# Real-time logs
kubectl logs -f -n openspp deployment/openspp

# All pod logs
kubectl logs -n openspp --all-containers=true deployment/openspp
```

### Pod Status

Check pod status:

```bash
kubectl get pods -n openspp
kubectl describe pod -n openspp <pod-name>
```

---

## Testing

### Smoke Tests

After deployment, verify OpenSPP is working:

```bash
# 1. Check pod is running
kubectl get pods -n openspp

# 2. Check service endpoints
kubectl get svc -n openspp

# 3. Check ingress
kubectl get ingress -n openspp

# 4. Port-forward and test HTTP
kubectl port-forward -n openspp svc/openspp 8069:8069
curl http://localhost:8069/web/login
# Should return HTML login page

# 5. Visit web UI
# Open browser: https://openspp.mifos.gazelle.test
# Login with admin/admin
```

### Integration Tests

Verify OpenSPP works with other DPGs:

```bash
# Check cross-namespace communication
kubectl run test-curl \
  --image=curlimages/curl \
  --namespace=openspp \
  --rm -it \
  --restart=Never \
  -- curl http://openspp:8069/web/login

# Should return HTML
```

### Resource Monitoring

Check resource usage:

```bash
# View current usage
kubectl top pods -n openspp

# View resource requests/limits
kubectl describe deployment -n openspp openspp
```

---

## Troubleshooting

### Pod Not Starting

**Symptom:** Pod stays in `Pending` or `CrashLoopBackOff`

**Diagnosis:**
```bash
kubectl describe pod -n openspp <pod-name>
kubectl logs -n openspp <pod-name>
```

**Common Causes:**
- PostgreSQL not ready: Check infra namespace
- Insufficient resources: Increase node capacity
- Image pull errors: Check Docker Hub rate limits

### Database Connection Failures

**Symptom:** Pod crashes with "could not connect to database"

**Solution:**
```bash
# Verify database is running
kubectl get pods -n infra

# Check PostgreSQL is accessible
kubectl run psql-test \
  --image=postgres:16-alpine \
  --namespace=openspp \
  --env="PGPASSWORD=openspp" \
  --rm -it \
  --restart=Never \
  -- psql -h postgresql.infra -U openspp -d openspp -c "SELECT 1"
```

### Ingress Not Accessible

**Symptom:** Cannot reach `https://openspp.mifos.gazelle.test`

**Solution:**
```bash
# Check ingress is created
kubectl get ingress -n openspp

# Check NGINX is running
kubectl get pods -n infra | grep nginx

# Check /etc/hosts has entry
cat /etc/hosts | grep openspp.mifos.gazelle.test
# Should show: 127.0.0.1 openspp.mifos.gazelle.test
# (or Colima VM IP on macOS: 192.168.68.x)
```

### High Memory Usage

**Symptom:** Pod getting OOMKilled despite limits

**Solution:**
```bash
# Reduce worker threads in Odoo config
# Edit values.yaml:
# openspp.odoo.workers = 2
# openspp.odoo.threads = 1

# Redeploy
helm upgrade openspp src/deployer/helm/openspp -n openspp
```

---

## Cleanup

### Remove OpenSPP Only

```bash
kubectl delete namespace openspp
```

### Remove All (Gazelle + OpenSPP)

```bash
sudo ./run.sh -u $USER -m cleanall -a all
```

---

## Performance Tuning

### For Low-Resource Machines (12GB RAM)

Reduce OpenSPP footprint:

```ini
[openspp]
cpu_limit = 500m
memory_limit = 1Gi
cpu_request = 250m
memory_request = 512Mi
```

Then reconfigure:
```bash
helm upgrade openspp src/deployer/helm/openspp \
  --set resources.limits.memory=1Gi \
  --set resources.limits.cpu=500m \
  -n openspp
```

### For High-Performance Machines

Increase capacity:

```ini
[openspp]
cpu_limit = 2000m
memory_limit = 4Gi
```

---

## References

- [OpenSPP Documentation](https://docs.openspp.org/)
- [OpenSPP GitHub](https://github.com/OpenSPP)
- [Mifos Gazelle Architecture](./ARCHITECTURE.md)
- [Mifos Gazelle README](./MIFOS-GAZELLE-README.md)

---

## Support

For issues or questions:

1. Check the [Troubleshooting](#troubleshooting) section
2. Review OpenSPP logs: `kubectl logs -n openspp deployment/openspp`
3. Check Jira issue: GAZ-195
4. Contact: [Mifos Slack #mifos-gazelle](https://mifos.slack.com)
