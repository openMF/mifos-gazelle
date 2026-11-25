# Performance Testing and TCO Estimation

This guide covers optional performance and total-cost-of-ownership (TCO) tooling for Mifos Gazelle. For full deployment prerequisites (RAM, disk, OS), see [MIFOS-GAZELLE-README.md](MIFOS-GAZELLE-README.md).

Three scripts work together to answer two questions:

- **Performance:** how does the stack behave under load?
- **TCO:** what does it cost to run this in production on a cloud provider?

---

## Tools

| Script | What it does |
|--------|-------------|
| `src/utils/perf/collect-metrics.sh` | Collects CPU/memory usage from a live cluster and writes a JSON report |
| `src/utils/perf/tco-estimate.py` | Reads that JSON and estimates monthly/annual cloud costs |
| `src/utils/perf/run-load-test.sh` | Runs the JMeter load test headlessly and captures before/after resource snapshots |

---

## Prerequisites

```bash
# jq — JSON processor used by collect-metrics.sh
sudo apt-get install -y jq

# Python 3 — already used by Gazelle; no extra packages needed for tco-estimate.py

# JMeter — only needed for run-load-test.sh (requires a JDK on PATH)
sudo apt-get install -y default-jdk
wget https://downloads.apache.org/jmeter/binaries/apache-jmeter-5.6.3.tgz
tar -xzf apache-jmeter-5.6.3.tgz -C $HOME
mv $HOME/apache-jmeter-5.6.3 $HOME/apache-jmeter
export PATH=$HOME/apache-jmeter/bin:$PATH
```

All three tools have a `--mock` flag that runs with built-in sample data so you can test them without a live cluster.

---

## Quick Start (no cluster needed)

```bash
# 1. Collect metrics (mock mode)
bash src/utils/perf/collect-metrics.sh --mock --out /tmp/metrics.json

# 2. Estimate TCO from those metrics
python3 src/utils/perf/tco-estimate.py --metrics /tmp/metrics.json

# 3. Compare across all cloud providers
python3 src/utils/perf/tco-estimate.py --metrics /tmp/metrics.json --all-providers

# 4. See what a load test would run (mock mode, no JMeter needed)
bash src/utils/perf/run-load-test.sh --mock
```

---

## Collecting Metrics from a Live Cluster

Requires a running Gazelle deployment and `kubectl` configured.
k3s includes metrics-server by default so `kubectl top` works out of the box.

```bash
# Collect from the default kubeconfig
bash src/utils/perf/collect-metrics.sh

# Custom kubeconfig (e.g. remote cluster)
bash src/utils/perf/collect-metrics.sh --kubeconfig ~/.kube/my-cluster.yaml

# Save to a specific file
bash src/utils/perf/collect-metrics.sh --out /tmp/gazelle-metrics.json

# Include PVC requested storage per namespace (recommended for TCO)
bash src/utils/perf/collect-metrics.sh --storage --out /tmp/gazelle-metrics.json
```

The script queries `kubectl top pods` for each Gazelle namespace (`infra`, `mifosx`, `paymenthub`, `vnext`) and writes a JSON file with per-pod and per-namespace CPU/memory figures.

---

## TCO Estimation

```bash
# AWS us-east-1 (default)
python3 src/utils/perf/tco-estimate.py --metrics /tmp/gazelle-metrics.json

# GCP us-central1
python3 src/utils/perf/tco-estimate.py --metrics /tmp/gazelle-metrics.json \
  --provider gcp --region us-central1

# Azure East US
python3 src/utils/perf/tco-estimate.py --metrics /tmp/gazelle-metrics.json \
  --provider azure --region eastus

# Compare all providers and regions at once
python3 src/utils/perf/tco-estimate.py --metrics /tmp/gazelle-metrics.json \
  --all-providers

# Adjust headroom buffer (default 30%)
python3 src/utils/perf/tco-estimate.py --metrics /tmp/gazelle-metrics.json \
  --headroom 0.50

# Set monthly network egress explicitly (GiB/month)
python3 src/utils/perf/tco-estimate.py --metrics /tmp/gazelle-metrics.json \
  --egress-gib 50

# Model HA baseline (3 nodes)
python3 src/utils/perf/tco-estimate.py --metrics /tmp/gazelle-metrics.json \
  --topology ha-3node

# Use external pricing catalog (recommended for freshness)
python3 src/utils/perf/tco-estimate.py --metrics /tmp/gazelle-metrics.json \
  --pricing-file /tmp/pricing.json

# Save full JSON output for further processing
python3 src/utils/perf/tco-estimate.py --metrics /tmp/gazelle-metrics.json \
  --json-out /tmp/tco-result.json
```

### How the estimate works

1. Reads measured CPU and memory from the metrics file
2. Adds a headroom buffer (default 30%) for OS overhead and traffic spikes
3. Finds the cheapest cloud instance that satisfies both CPU and memory requirements
4. Computes: `instance_hourly_price × 730 hours/month`
5. Adds storage (prefer measured PVC requested capacity if present) and network egress costs
6. Breaks down costs proportionally per DPG component

### Measured inputs vs modeled costs

The dollar amounts are **not** taken from your cloud bill. They are a **model** built from:

| Input | Source |
|-------|--------|
| CPU and memory totals | **Measured** at collection time via `kubectl top pods` (point-in-time usage, not limits). |
| Per-namespace PVC sizes (`--storage`) | **Measured** as Kubernetes **requested** capacity on each PVC, summed per namespace (not actual bytes written). |
| Instance type and hourly rate | **Modeled** from the built-in catalog or `--pricing-file` (indicative on-demand Linux prices). |
| Monthly compute | `hourly_rate × 730 hours × topology multiplier` (`single-node` = 1, `ha-3node` = 3). The HA multiplier is a planning shortcut, not proof of a three-node architecture. |
| Monthly storage | `total_requested_gib × provider_storage_price_per_gib_month × topology multiplier`. |
| Monthly network | `--egress-gib` (GiB/month) × provider egress price per GiB — **you supply** egress unless you have metering data. |
| Per-component (DPG) cost share | **Heuristic:** allocated by each component’s share of **measured memory** across namespaces, not true chargeback. |

So: **workload shape is grounded in real cluster snapshots**; **prices, egress, HA shape, and allocation method are assumptions** you should tune and disclose when sharing numbers.

### Interpreting the output

- The estimate is for a **single-node demo/test deployment** by default
- A production HA deployment (3+ nodes for redundancy) would cost roughly 3× more
- Reserved instance pricing (1-year) typically cuts the compute cost by 30–40%
- Prices are on-demand rates as of early 2026 — verify against provider pricing pages before budgeting
- PVC storage values represent **requested capacity**, not actual used bytes
- Network cost accuracy depends on realistic `--egress-gib` input from observed traffic

---

## Load Testing

Requires JMeter installed and a running Gazelle deployment.

```bash
# Basic run — 10 users for 60 seconds
bash src/utils/perf/run-load-test.sh

# Higher load
bash src/utils/perf/run-load-test.sh --threads 50 --duration 300 --rampup 30

# Custom host (e.g. remote cluster)
bash src/utils/perf/run-load-test.sh --host ops.my-cluster.example.com --port 443

# Specify JMeter location explicitly
bash src/utils/perf/run-load-test.sh --jmeter $HOME/apache-jmeter/bin

# Save results to a specific directory
bash src/utils/perf/run-load-test.sh --out /tmp/my-load-test
```

The script:
1. Takes a resource snapshot before the test (`metrics-before.json`)
2. Runs `performance-testing/paymentHubEE.jmx` headlessly via JMeter CLI
3. Takes a resource snapshot after the test (`metrics-after.json`)
4. Prints a summary of request counts, pass/fail rates, and response times
5. Shows the CPU/memory delta between before and after

### Output files

```
/tmp/gazelle-perf-<timestamp>/
├── report/index.html      # JMeter HTML report (open in browser)
├── results.jtl            # Raw results CSV
├── metrics-before.json    # Resource snapshot before test
├── metrics-after.json     # Resource snapshot after test
├── summary.txt            # Human-readable summary
└── jmeter.log             # JMeter execution log
```

### Full pipeline: load test → TCO under load

```bash
# Run load test
bash src/utils/perf/run-load-test.sh --threads 20 --duration 120 --out /tmp/lt

# Estimate TCO based on resource usage observed during the load test
python3 src/utils/perf/tco-estimate.py --metrics /tmp/lt/metrics-after.json
```

This gives you a TCO estimate that reflects actual resource consumption under realistic load, not just idle usage.

The bundled `performance-testing/paymentHubEE.jmx` plan may return HTTP errors until it is aligned with your deployment (correct host, paths, and authentication). The wrapper script still produces snapshots, JTL output, and an HTML report for iteration.

---

## Exporting evidence from a test VM

Artifacts are written under `/tmp` by default. To copy them to your laptop:

**Option A — one archive on the VM, then download**

Run on the VM (adjust paths if your load-test output directory differs):

```bash
cd /tmp
tar -czf gazelle-perf-evidence.tgz live-metrics.json tco-result.json live-lt
```

If `live-lt` or `tco-result.json` does not exist yet, omit those names or create them first. Then download `/tmp/gazelle-perf-evidence.tgz` from the VM (for example Google Cloud browser SSH: use the **Download file** action and enter that path).

From a machine with the Google Cloud SDK installed:
gcloud compute scp INSTANCE_NAME:/tmp/gazelle-perf-evidence.tgz . --zone YOUR_ZONE
```

**Option B — individual files with `gcloud compute scp`**

```bash
gcloud compute scp INSTANCE_NAME:/tmp/live-metrics.json ./gazelle-evidence/ --zone YOUR_ZONE
gcloud compute scp --recurse INSTANCE_NAME:/tmp/live-lt ./gazelle-evidence/live-lt --zone YOUR_ZONE
```

Keep evidence outside the git tree (for example a local `gazelle-evidence/` directory that is gitignored) unless maintainers ask for artifacts attached to an issue or PR.

---

## Data Provenance: What Comes From Where

- **CPU/Memory (live):** `kubectl top pods` across `infra`, `mifosx`, `paymenthub`, `vnext`
- **CPU/Memory (mock):** hardcoded representative pod metrics in `collect-metrics.sh`
- **Storage (live):** `kubectl get pvc` requested sizes, converted to GiB (`--storage`)
- **Storage (mock):** representative namespace-level values in `collect-metrics.sh`
- **Pricing (default):** embedded `INSTANCE_CATALOG` in `tco-estimate.py`
- **Pricing (override):** `--pricing-file` JSON catalog (supports optional metadata)
- **Egress:** user input via `--egress-gib` (defaults to a conservative baseline)
- **Topology:** `--topology single-node|ha-3node`

### Pricing File Formats

Raw catalog format:

```json
{
  "aws": {
    "us-east-1": [
      {"name": "m6i.xlarge", "vcpu": 4, "ram_gib": 16, "price_usd_hr": 0.192}
    ]
  }
}
```

Metadata-wrapped format:

```json
{
  "pricing_as_of": "2026-05",
  "source": "manual provider snapshot",
  "catalog": {
    "aws": {
      "us-east-1": [
        {"name": "m6i.xlarge", "vcpu": 4, "ram_gib": 16, "price_usd_hr": 0.192}
      ]
    }
  }
}
```

---

## Supported Cloud Providers and Regions

| Provider | Regions |
|----------|---------|
| AWS | `us-east-1`, `eu-west-1`, `ap-southeast-1` |
| GCP | `us-central1`, `europe-west1` |
| Azure | `eastus`, `westeurope` |

Pricing data is embedded in `tco-estimate.py` and reflects approximate on-demand Linux instance prices as of early 2026.
To add a region, extend the `INSTANCE_CATALOG` dictionary in that file.
