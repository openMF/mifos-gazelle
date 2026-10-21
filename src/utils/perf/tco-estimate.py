#!/usr/bin/env python3
"""
tco-estimate.py -- Total Cost of Ownership calculator for Mifos Gazelle

Reads a metrics JSON file produced by collect-metrics.sh and estimates
the monthly/annual cloud infrastructure cost to run the Gazelle stack.

Usage:
    python3 src/utils/perf/tco-estimate.py --metrics /tmp/gazelle-metrics-*.json
    python3 src/utils/perf/tco-estimate.py --mock
    python3 src/utils/perf/tco-estimate.py --metrics <file> --provider aws --region us-east-1

How the estimate works:
    1. Read actual CPU + memory consumption from the metrics file
    2. Add a headroom buffer (default 30%) for OS overhead and traffic spikes
    3. Find the cheapest cloud instance that satisfies both CPU and memory
    4. Multiply instance hourly price × 730 hours/month
    5. Add estimated storage and network costs
    6. Output a breakdown per DPG and a grand total

Pricing data is embedded (no API calls needed) and reflects approximate
on-demand prices as of early 2026. Prices are indicative — always verify
against the provider's current pricing page before making budget decisions.
"""

import argparse
import json
import sys
from datetime import datetime, timezone

# ── embedded cloud pricing ────────────────────────────────────────────────────
# Format: {provider: {region: [{name, vcpu, ram_gib, price_per_hour_usd}]}}
# Sources (approximate on-demand Linux prices, early 2026):
#   AWS:   https://aws.amazon.com/ec2/pricing/on-demand/
#   GCP:   https://cloud.google.com/compute/vm-instance-pricing
#   Azure: https://azure.microsoft.com/en-us/pricing/details/virtual-machines/linux/
#
# To use updated pricing: pass --pricing-file <path> pointing to a JSON file
# with the same structure as INSTANCE_CATALOG below.
PRICING_LAST_UPDATED = "2026-01"  # update this when you refresh prices

INSTANCE_CATALOG = {
    "aws": {
        "us-east-1": [
            {"name": "t3.medium",   "vcpu": 2,  "ram_gib": 4,   "price_usd_hr": 0.0416},
            {"name": "t3.large",    "vcpu": 2,  "ram_gib": 8,   "price_usd_hr": 0.0832},
            {"name": "t3.xlarge",   "vcpu": 4,  "ram_gib": 16,  "price_usd_hr": 0.1664},
            {"name": "t3.2xlarge",  "vcpu": 8,  "ram_gib": 32,  "price_usd_hr": 0.3328},
            {"name": "m6i.large",   "vcpu": 2,  "ram_gib": 8,   "price_usd_hr": 0.096},
            {"name": "m6i.xlarge",  "vcpu": 4,  "ram_gib": 16,  "price_usd_hr": 0.192},
            {"name": "m6i.2xlarge", "vcpu": 8,  "ram_gib": 32,  "price_usd_hr": 0.384},
            {"name": "r6i.large",   "vcpu": 2,  "ram_gib": 16,  "price_usd_hr": 0.126},
            {"name": "r6i.xlarge",  "vcpu": 4,  "ram_gib": 32,  "price_usd_hr": 0.252},
        ],
        "eu-west-1": [
            {"name": "t3.medium",   "vcpu": 2,  "ram_gib": 4,   "price_usd_hr": 0.0464},
            {"name": "t3.large",    "vcpu": 2,  "ram_gib": 8,   "price_usd_hr": 0.0928},
            {"name": "t3.xlarge",   "vcpu": 4,  "ram_gib": 16,  "price_usd_hr": 0.1856},
            {"name": "t3.2xlarge",  "vcpu": 8,  "ram_gib": 32,  "price_usd_hr": 0.3712},
            {"name": "m6i.xlarge",  "vcpu": 4,  "ram_gib": 16,  "price_usd_hr": 0.214},
            {"name": "m6i.2xlarge", "vcpu": 8,  "ram_gib": 32,  "price_usd_hr": 0.428},
        ],
        "ap-southeast-1": [
            {"name": "t3.medium",   "vcpu": 2,  "ram_gib": 4,   "price_usd_hr": 0.0464},
            {"name": "t3.xlarge",   "vcpu": 4,  "ram_gib": 16,  "price_usd_hr": 0.1856},
            {"name": "m6i.xlarge",  "vcpu": 4,  "ram_gib": 16,  "price_usd_hr": 0.222},
            {"name": "m6i.2xlarge", "vcpu": 8,  "ram_gib": 32,  "price_usd_hr": 0.444},
        ],
    },
    "gcp": {
        "us-central1": [
            {"name": "e2-standard-2",  "vcpu": 2,  "ram_gib": 8,   "price_usd_hr": 0.0670},
            {"name": "e2-standard-4",  "vcpu": 4,  "ram_gib": 16,  "price_usd_hr": 0.1340},
            {"name": "e2-standard-8",  "vcpu": 8,  "ram_gib": 32,  "price_usd_hr": 0.2680},
            {"name": "n2-standard-4",  "vcpu": 4,  "ram_gib": 16,  "price_usd_hr": 0.1900},
            {"name": "n2-standard-8",  "vcpu": 8,  "ram_gib": 32,  "price_usd_hr": 0.3800},
            {"name": "n2-highmem-4",   "vcpu": 4,  "ram_gib": 32,  "price_usd_hr": 0.2960},
        ],
        "europe-west1": [
            {"name": "e2-standard-4",  "vcpu": 4,  "ram_gib": 16,  "price_usd_hr": 0.1474},
            {"name": "e2-standard-8",  "vcpu": 8,  "ram_gib": 32,  "price_usd_hr": 0.2948},
            {"name": "n2-standard-4",  "vcpu": 4,  "ram_gib": 16,  "price_usd_hr": 0.2090},
            {"name": "n2-highmem-4",   "vcpu": 4,  "ram_gib": 32,  "price_usd_hr": 0.3256},
        ],
    },
    "azure": {
        "eastus": [
            {"name": "Standard_D2s_v3",  "vcpu": 2,  "ram_gib": 8,   "price_usd_hr": 0.096},
            {"name": "Standard_D4s_v3",  "vcpu": 4,  "ram_gib": 16,  "price_usd_hr": 0.192},
            {"name": "Standard_D8s_v3",  "vcpu": 8,  "ram_gib": 32,  "price_usd_hr": 0.384},
            {"name": "Standard_E4s_v3",  "vcpu": 4,  "ram_gib": 32,  "price_usd_hr": 0.252},
            {"name": "Standard_E8s_v3",  "vcpu": 8,  "ram_gib": 64,  "price_usd_hr": 0.504},
        ],
        "westeurope": [
            {"name": "Standard_D4s_v3",  "vcpu": 4,  "ram_gib": 16,  "price_usd_hr": 0.211},
            {"name": "Standard_D8s_v3",  "vcpu": 8,  "ram_gib": 32,  "price_usd_hr": 0.422},
            {"name": "Standard_E4s_v3",  "vcpu": 4,  "ram_gib": 32,  "price_usd_hr": 0.277},
        ],
    },
}

# Storage cost per GiB/month (SSD/block storage)
STORAGE_PRICE_PER_GIB_MONTH = {
    "aws":   0.10,   # gp3 EBS
    "gcp":   0.17,   # SSD persistent disk
    "azure": 0.115,  # Premium SSD LRS
}

# Estimated storage per namespace in GiB (persistent volumes)
NAMESPACE_STORAGE_GIB = {
    "infra":       50,   # MySQL, Elasticsearch, Kafka, MongoDB data
    "mifosx":      10,   # Fineract DB (shared with infra MySQL but separate PV)
    "paymenthub":  10,   # Zeebe data, MinIO
    "vnext":       10,   # MongoDB collections for vNext BCs
}

# Network egress cost per GiB (outbound only; inbound is free on all providers)
NETWORK_EGRESS_PRICE_PER_GIB = {
    "aws":   0.09,
    "gcp":   0.08,
    "azure": 0.087,
}

# Assumed monthly outbound traffic in GiB for a demo/test deployment
ESTIMATED_EGRESS_GIB_MONTH = 10

HOURS_PER_MONTH = 730

# ── topology multipliers ──────────────────────────────────────────────────────
# single-node: dev/demo baseline (1 node, no redundancy)
# ha-3node:    production minimum (3 nodes, stateful services replicated)
TOPOLOGY_MULTIPLIERS = {
    "single-node": 1.0,
    "ha-3node":    3.0,
}


# ── DPG namespace mapping ─────────────────────────────────────────────────────
DPG_NAMESPACES = {
    "MifosX (Core Banking)":          ["mifosx"],
    "Payment Hub EE":                  ["paymenthub"],
    "Mojaloop vNext (Payment Switch)": ["vnext"],
    "Shared Infrastructure":           ["infra"],
}


def find_cheapest_instance(required_vcpu: float, required_ram_gib: float,
                            provider: str, region: str, catalog: dict) -> dict | None:
    """Return the cheapest instance that satisfies both CPU and RAM requirements."""
    instances = catalog.get(provider, {}).get(region)
    if not instances:
        return None
    candidates = [
        i for i in instances
        if i["vcpu"] >= required_vcpu and i["ram_gib"] >= required_ram_gib
    ]
    if not candidates:
        return None
    return min(candidates, key=lambda i: i["price_usd_hr"])


def calculate_tco(metrics: dict, provider: str, region: str,
                  headroom_pct: float, egress_gib: float,
                  topology: str, catalog: dict,
                  pricing_as_of: str, pricing_source: str) -> dict:
    """
    Core TCO calculation.

    Args:
        metrics:      parsed JSON from collect-metrics.sh
        provider:     'aws', 'gcp', or 'azure'
        region:       cloud region string
        headroom_pct: fractional overhead buffer, e.g. 0.30 for 30%
        egress_gib:   estimated monthly outbound traffic in GiB
        topology:     'single-node' or 'ha-3node'
        catalog:      instance pricing catalog (INSTANCE_CATALOG or loaded from file)

    Returns:
        dict with full cost breakdown
    """
    summary = metrics.get("summary", {})
    ns_data = {ns["namespace"]: ns for ns in metrics.get("namespaces", [])}

    # Total measured resource consumption
    measured_cpu_cores = summary.get("total_cpu_cores", 0)
    measured_mem_gib   = summary.get("total_memory_gib", 0)

    # Apply headroom buffer
    required_cpu = measured_cpu_cores * (1 + headroom_pct)
    required_mem = measured_mem_gib   * (1 + headroom_pct)

    # Find the right instance
    instance = find_cheapest_instance(required_cpu, required_mem, provider, region, catalog)

    if not instance:
        all_instances = catalog.get(provider, {}).get(region, [])
        candidates = [i for i in all_instances if i["ram_gib"] >= required_mem]
        instance = min(candidates, key=lambda i: i["price_usd_hr"]) if candidates else None

    # Topology multiplier (single-node vs HA)
    topo_mult = TOPOLOGY_MULTIPLIERS.get(topology, 1.0)

    # Use measured PVC storage from metrics if available, else fall back to defaults
    storage_measured = metrics.get("storage_gib", {})
    storage_per_ns = {
        ns: storage_measured.get(ns, NAMESPACE_STORAGE_GIB.get(ns, 0))
        for ns in NAMESPACE_STORAGE_GIB
    }
    total_storage_gib = sum(storage_per_ns.values())

    # Compute costs
    compute_monthly = (instance["price_usd_hr"] * HOURS_PER_MONTH * topo_mult) if instance else 0
    storage_monthly = total_storage_gib * STORAGE_PRICE_PER_GIB_MONTH.get(provider, 0.10) * topo_mult
    network_monthly = egress_gib * NETWORK_EGRESS_PRICE_PER_GIB.get(provider, 0.09)

    total_monthly  = compute_monthly + storage_monthly + network_monthly
    total_annually = total_monthly * 12

    # Per-DPG breakdown (proportional to memory share)
    dpg_breakdown = []
    for dpg_name, namespaces in DPG_NAMESPACES.items():
        dpg_cpu_m = sum(
            ns_data[ns]["total_cpu_millicores"]
            for ns in namespaces if ns in ns_data
        )
        dpg_mem_mib = sum(
            ns_data[ns]["total_memory_mib"]
            for ns in namespaces if ns in ns_data
        )
        mem_share = (dpg_mem_mib / 1024) / measured_mem_gib if measured_mem_gib > 0 else 0
        dpg_monthly = total_monthly * mem_share

        dpg_breakdown.append({
            "component":          dpg_name,
            "namespaces":         namespaces,
            "cpu_cores":          round(dpg_cpu_m / 1000, 2),
            "memory_gib":         round(dpg_mem_mib / 1024, 2),
            "memory_share_pct":   round(mem_share * 100, 1),
            "estimated_monthly_usd": round(dpg_monthly, 2),
        })

    return {
        "generated_at":    datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "provider":        provider,
        "region":          region,
        "topology":        topology,
        "headroom_pct":    headroom_pct * 100,
        "egress_gib_month": egress_gib,
        "pricing_as_of":   pricing_as_of,
        "pricing_source":  pricing_source,
        "measured": {
            "cpu_cores":   round(measured_cpu_cores, 2),
            "memory_gib":  round(measured_mem_gib, 2),
        },
        "required_with_headroom": {
            "cpu_cores":   round(required_cpu, 2),
            "memory_gib":  round(required_mem, 2),
        },
        "recommended_instance": instance,
        "costs": {
            "compute_monthly_usd": round(compute_monthly, 2),
            "storage_monthly_usd": round(storage_monthly, 2),
            "network_monthly_usd": round(network_monthly, 2),
            "total_monthly_usd":   round(total_monthly, 2),
            "total_annual_usd":    round(total_annually, 2),
            "topology_multiplier": topo_mult,
            "storage_breakdown_gib": storage_per_ns,
            "storage_source": "measured" if storage_measured else "estimated",
        },
        "dpg_breakdown": dpg_breakdown,
    }


def print_report(result: dict) -> None:
    """Print a human-readable TCO report to stdout."""
    sep = "─" * 60

    print()
    print("  Mifos Gazelle — TCO Estimate")
    print(f"  Generated: {result['generated_at']}")
    print(f"  Provider:  {result['provider'].upper()}  |  Region: {result['region']}")
    print(f"  Topology:  {result['topology']}  |  Headroom: {result['headroom_pct']:.0f}%")
    print(f"  Egress:    {result['egress_gib_month']:.0f} GiB/month  |  Pricing as of: {result['pricing_as_of']}")
    print(f"  Pricing:   {result['pricing_source']}")
    print()
    print(f"  {sep}")
    print("  Measured Resource Consumption")
    print(f"  {sep}")
    m = result["measured"]
    r = result["required_with_headroom"]
    print(f"  CPU (cores):   {m['cpu_cores']:.2f} measured  →  {r['cpu_cores']:.2f} with headroom")
    print(f"  Memory (GiB):  {m['memory_gib']:.2f} measured  →  {r['memory_gib']:.2f} with headroom")
    print()

    inst = result.get("recommended_instance")
    if inst:
        print(f"  {sep}")
        print("  Recommended Instance")
        print(f"  {sep}")
        print(f"  Type:          {inst['name']}")
        print(f"  vCPU:          {inst['vcpu']}")
        print(f"  RAM:           {inst['ram_gib']} GiB")
        print(f"  On-demand:     ${inst['price_usd_hr']:.4f}/hr")
        print()

    print(f"  {sep}")
    print("  Cost Breakdown (per month)")
    print(f"  {sep}")
    costs = result["costs"]
    storage_label = f"({sum(costs['storage_breakdown_gib'].values()):.0f} GiB SSD, {costs['storage_source']})"
    print(f"  Compute:       ${costs['compute_monthly_usd']:>8.2f}  (×{costs['topology_multiplier']:.0f} nodes)")
    print(f"  Storage:       ${costs['storage_monthly_usd']:>8.2f}  {storage_label}")
    print(f"  Network:       ${costs['network_monthly_usd']:>8.2f}  ({result['egress_gib_month']:.0f} GiB egress)")
    print(f"  {'─'*40}")
    print(f"  Monthly total: ${costs['total_monthly_usd']:>8.2f}")
    print(f"  Annual total:  ${costs['total_annual_usd']:>8.2f}")
    print()

    print(f"  {sep}")
    print("  Cost by Component")
    print(f"  {sep}")
    print(f"  {'Component':<35} {'CPU':>6} {'Mem(GiB)':>10} {'Monthly':>10}")
    print(f"  {'─'*35} {'─'*6} {'─'*10} {'─'*10}")
    for dpg in result["dpg_breakdown"]:
        print(
            f"  {dpg['component']:<35} "
            f"{dpg['cpu_cores']:>6.2f} "
            f"{dpg['memory_gib']:>10.2f} "
            f"${dpg['estimated_monthly_usd']:>9.2f}"
        )
    print()

    print(f"  {sep}")
    print("  Notes")
    print(f"  {sep}")
    print("  - Prices are on-demand (no reserved instance discount).")
    print("  - Reserved 1-year instances typically save 30-40%.")
    print("  - Reserved 3-year instances typically save 50-60%.")
    print("  - This estimate covers a single-node deployment (dev/test/demo).")
    print("  - Production would require HA setup (3+ nodes): use --topology ha-3node.")
    print(f"  - Pricing data as of {result['pricing_as_of']}. Verify before budgeting.")
    print("  - Use --pricing-file to supply updated pricing data.")
    print("  - PVC storage reflects requested capacity (not actual bytes used).")
    print("  - For network cost realism, pass observed monthly egress via --egress-gib.")
    print()


def load_mock_metrics() -> dict:
    """Return representative metrics matching collect-metrics.sh --mock output."""
    return {
        "collected_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "mode": "mock",
        "cluster": {
            "node_count": 1,
            "total_cpu_millicores": 4000,
            "total_memory_mib": 16384,
        },
        "summary": {
            "total_pods": 18,
            "total_cpu_millicores": 1340,
            "total_memory_mib": 7344,
            "total_cpu_cores": 1.34,
            "total_memory_gib": 7.17,
        },
        "namespaces": [
            {"namespace": "infra",       "pod_count": 6, "total_cpu_millicores": 400, "total_memory_mib": 2656.0},
            {"namespace": "mifosx",      "pod_count": 2, "total_cpu_millicores": 325, "total_memory_mib": 1584.0},
            {"namespace": "paymenthub",  "pod_count": 5, "total_cpu_millicores": 450, "total_memory_mib": 2240.0},
            {"namespace": "vnext",       "pod_count": 5, "total_cpu_millicores": 165, "total_memory_mib":  864.0},
        ],
        "storage_gib": {
            "infra": 45,
            "mifosx": 8,
            "paymenthub": 9,
            "vnext": 7,
        },
        "pods": [],
    }


def load_pricing_catalog(pricing_file: str | None) -> tuple[dict, str, str]:
    """
    Load pricing catalog and metadata.

    Supported file formats:
      1) Raw catalog (same shape as INSTANCE_CATALOG)
      2) Wrapped metadata:
         {
           "pricing_as_of": "2026-05",
           "source": "custom snapshot",
           "catalog": { ...same as INSTANCE_CATALOG... }
         }
    """
    if not pricing_file:
        return INSTANCE_CATALOG, PRICING_LAST_UPDATED, "built-in catalog"

    try:
        with open(pricing_file) as f:
            payload = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"ERROR: could not load pricing file: {e}", file=sys.stderr)
        sys.exit(1)

    if isinstance(payload, dict) and "catalog" in payload:
        catalog = payload.get("catalog", {})
        pricing_as_of = payload.get("pricing_as_of", PRICING_LAST_UPDATED)
        source = payload.get("source", f"external file: {pricing_file}")
    else:
        catalog = payload
        pricing_as_of = PRICING_LAST_UPDATED
        source = f"external file: {pricing_file}"

    if not isinstance(catalog, dict) or not catalog:
        print("ERROR: pricing catalog is empty or invalid", file=sys.stderr)
        sys.exit(1)

    return catalog, pricing_as_of, source


def main():
    parser = argparse.ArgumentParser(
        description="Mifos Gazelle TCO Estimator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--metrics",  help="Path to metrics JSON from collect-metrics.sh")
    parser.add_argument("--mock",     action="store_true", help="Use built-in sample data (no cluster needed)")
    parser.add_argument("--provider", default="aws",       help="Cloud provider: aws, gcp, azure (default: aws)")
    parser.add_argument("--region",   default="us-east-1", help="Cloud region (default: us-east-1)")
    parser.add_argument("--headroom", type=float, default=0.30,
                        help="Headroom buffer fraction, e.g. 0.30 = 30%% (default: 0.30)")
    parser.add_argument("--egress-gib", type=float, default=float(ESTIMATED_EGRESS_GIB_MONTH),
                        help=f"Estimated monthly outbound traffic in GiB (default: {ESTIMATED_EGRESS_GIB_MONTH})")
    parser.add_argument("--topology", default="single-node",
                        choices=["single-node", "ha-3node"],
                        help="Deployment topology: single-node (dev/demo) or ha-3node (production, default: single-node)")
    parser.add_argument("--pricing-file",
                        help="Path to a JSON pricing catalog file (same structure as built-in INSTANCE_CATALOG)")
    parser.add_argument("--all-providers", action="store_true",
                        help="Show estimates for all providers and regions")
    parser.add_argument("--json-out", help="Also write full result JSON to this file")
    args = parser.parse_args()

    # Load metrics
    if args.mock:
        metrics = load_mock_metrics()
        print("  [mock mode] Using representative sample data — not a live cluster.")
    elif args.metrics:
        try:
            with open(args.metrics) as f:
                metrics = json.load(f)
        except FileNotFoundError:
            print(f"ERROR: metrics file not found: {args.metrics}", file=sys.stderr)
            sys.exit(1)
        except json.JSONDecodeError as e:
            print(f"ERROR: invalid JSON in metrics file: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print("ERROR: provide --metrics <file> or --mock", file=sys.stderr)
        parser.print_help()
        sys.exit(1)

    # Load pricing catalog (external file overrides built-in)
    catalog, pricing_as_of, pricing_source = load_pricing_catalog(args.pricing_file)
    if args.pricing_file:
        print(f"  [pricing] Loaded from: {args.pricing_file} (as of {pricing_as_of})")
    else:
        print(f"  [pricing] Using built-in data (as of {pricing_as_of}). "
              "Pass --pricing-file for updated prices.")

    egress = args.egress_gib

    if args.all_providers:
        print(f"\n  Mifos Gazelle — TCO Comparison Across Providers  [{args.topology}]\n")
        print(f"  {'Provider':<8} {'Region':<20} {'Instance':<18} {'Monthly':>10} {'Annual':>10}")
        print(f"  {'─'*8} {'─'*20} {'─'*18} {'─'*10} {'─'*10}")
        for prov, regions in catalog.items():
            for reg in regions:
                r = calculate_tco(
                    metrics, prov, reg, args.headroom, egress, args.topology,
                    catalog, pricing_as_of, pricing_source
                )
                inst = r.get("recommended_instance")
                inst_name = inst["name"] if inst else "N/A"
                print(
                    f"  {prov:<8} {reg:<20} {inst_name:<18} "
                    f"${r['costs']['total_monthly_usd']:>9.2f} "
                    f"${r['costs']['total_annual_usd']:>9.2f}"
                )
        print()
        return

    # Single provider/region estimate
    result = calculate_tco(
        metrics, args.provider, args.region, args.headroom, egress, args.topology,
        catalog, pricing_as_of, pricing_source
    )
    print_report(result)

    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(result, f, indent=2)
        print(f"  Full JSON written to: {args.json_out}\n")


if __name__ == "__main__":
    main()
