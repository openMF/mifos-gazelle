# Performance Testing and TCO Estimation

This guide covers the performance and cost tooling added to Mifos Gazelle.
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

# JMeter — only needed for run-load-test.sh
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
