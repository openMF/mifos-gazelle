# Mifos Gazelle
[![Mifos](https://img.shields.io/badge/Mifos-Gazelle-blue)](https://github.com/openMF/mifos-gazelle)

> Mifos Gazelle is a Mifos Digital Public Infrastructure as a Solution (DaaS) deployment tool v2.0.0 — March 2026.
> Deploys MifosX (core banking), Payment Hub EE (payment orchestration), and Mojaloop vNext Beta1 (payment switch) on Kubernetes with a single command.

## Quick Start

Latest Stable Release:
```bash
git clone --branch main https://github.com/openMF/mifos-gazelle.git
cd mifos-gazelle
sudo ./run.sh -u $USER -m deploy -a all
```

See [Deployment Guide](docs/MIFOS-GAZELLE-README.md) for prerequisites and full instructions.

For Latest Development Release (May not be stable):
```bash
git clone --branch dev https://github.com/openMF/mifos-gazelle.git
cd mifos-gazelle
sudo ./run.sh -u $USER -m deploy -a all
```

## Documentation

| Guide | Contents |
|-------|----------|
| [Deployment Guide](docs/MIFOS-GAZELLE-README.md) | Install, configure, test end-to-end payments, FAQ |
| [Bulk Payment Tools](docs/BULK.md) | Submit/verify G2P batch payments, GovStack mode |
| [GovStack Architecture](docs/GOVSTACK.md) | G2P bulk disbursement design and troubleshooting |
| [Local Development](docs/LOCALDEV.md) | hostPath mounts for iterating on Payment Hub EE code |
| [vNext Standalone](docs/VNEXT-README.md) | Deploy Mojaloop vNext on its own |
| [Raspberry Pi](docs/RASPBERRY-PI-README.md) | Ubuntu setup on Raspberry Pi 5 |
| [Release Notes](docs/RELEASE-NOTES.md) | v2.0.0 changes and component versions |
| [PHEE Release History](docs/PHEE-RELEASE-HISTORY.md) | reference for PaymentHub EE component versions  |
| [Mastercard CBS](docs/mastercard/MASTERCARD.md) | Cross-border payment connector for Payment Hub EE — overview, integration, and quick start |
| [Mastercard CBS — Operator Guide](docs/mastercard/OPERATOR_DEPLOYMENT_GUIDE.md) | Full config reference, CR spec, operator lifecycle, and troubleshooting |

## Companion Tools

- **[Demo Creator](https://github.com/openMF/mifos-gazelle-demo-creator)** — TUI to author, manage, and deploy Gazelle demos
- **[Demo Runtime](https://github.com/openMF/mifos-gazelle-demo-runtime)** — Web UI to run interactive demos against a live Gazelle deployment

## Additional Resources

- [Contributing Guidelines](CONTRIBUTING.md)
- [License Information](LICENSE.md)
- [Architecture](ARCHITECTURE.md)
- [Mifos Slack for Release](https://mifos.slack.com) — join the `#mifos-gazelle` channel
- [Mifos Slack for Development](https://mifos.slack.com) — join the `#mifos-gazelle-dev` channel
