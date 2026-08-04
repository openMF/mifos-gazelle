# OpenSPP2 on Mifos Gazelle

## What this is

[OpenSPP](https://openspp.org) is an open source social protection platform. It is the **social
registry**: it holds the people and households a government or agency wants to help (individuals,
groups, farms, land), decides who is eligible for a benefit, and works out how much each one should get.
Benefits are organised as **programmes** with **cycles** and **entitlements**. It is built on Odoo, so it
is a web application with its own database.

In Gazelle it fills the gap the other DPGs do not cover. MifosX is the core banking system, Payment Hub
EE orchestrates payments and Mojaloop vNext is the switch, but none of them knows **who** the
beneficiaries are or **why** they should be paid. OpenSPP answers that, so a full chain becomes possible:
a beneficiary registered in OpenSPP -> a subsidy calculated for them -> paid through Payment Hub EE ->
credited in a MifosX account.

**OpenSPP2** (Odoo 19) is the current version and the one Gazelle deploys. It is an **optional** DPG,
disabled by default (`[openspp] enabled = false` in `config/config.ini`), and self-contained: it brings
its own **PostgreSQL 18 + PostGIS 3.6** database, so it does not use the shared infra chart.

```
                      Browser (HTTPS)
                             |
              NGINX ingress  openspp.<GAZELLE_DOMAIN>
                 /  -> :8069            /websocket -> :8072
                             |
                   Service openspp-odoo
                             |
        odoo (Deployment)                jobworker (Deployment)
        Odoo 19 + OpenSPP                async queue worker
        self-initialises the DB          no Service, no HTTP
                             |                    |
                             +---------+----------+
                                       |
                            Service openspp-postgis
                                       |
                              postgis (StatefulSet)
                              postgis/postgis:18-3.6-alpine
```

Both paths of the ingress go to the `openspp-odoo` Service: `/websocket` to the longpolling port (8072)
and everything else to the HTTP port (8069). The jobworker has no Service and serves no HTTP; it only
talks to the database, where it picks up queued jobs.

The Odoo container **self-initialises** on first boot (its entrypoint installs `base` then the module
in `ODOO_INIT_MODULES`), so there is **no separate init Job**.

## Prerequisites

1. A running cluster. On a fresh machine: `sudo ./setup-env.sh -u $USER` (installs k3s + tools).
2. `docker` with the buildx plugin, because the OpenSPP2 image is not published anywhere yet and the
   deploy builds it. See [Building images](BUILDING-IMAGES.md).

The deploy checks three things in order and picks the cheapest that works: the image is already in the
cluster, the image can be pulled from its registry, or it has to be built. Only the third one costs
anything, about **30 minutes and 3 GB of disk** the first time, and the import step asks for `sudo`.
Both the source checkout and the image are reused, so a second deploy does neither.

To build it by hand instead, or to look at what the deploy runs:

```bash
src/utils/build-and-import-image.sh -n ghcr.io/openmf/openspp -t 19.0 \
    -c <OpenSPP2 checkout> -f <OpenSPP2 checkout>/docker/Dockerfile --target production
```

> The import loads the image into the container runtime of a k3s cluster **on this machine**, so it
> does not work against a remote cluster, nor on macOS where the cluster lives inside the Colima VM.
> There, build the image and `--push` it to a registry, or build it on the cluster node itself. The
> deploy reports this before it starts building.

> Keep the node's `/` disk below ~85%, or k3s image garbage collection may evict the image, which
> cannot be pulled back.

## Configuration

`config/config.ini`, section `[openspp]`:

| Key | Default | Notes |
|-----|---------|-------|
| `enabled` | `false` | Optional DPG; deploy explicitly with `-a openspp`. |
| `OPENSPP_IMAGE_REPOSITORY` / `OPENSPP_IMAGE_TAG` | `ghcr.io/openmf/openspp` / `19.0` | The image the pods run. Point these at a published image and nothing else has to change. |
| `OPENSPP_BUILD_IF_MISSING` | `true` | Build during the deploy when the image is neither in the cluster nor pullable. `false` stops instead, printing the build command. |
| `OPENSPP_SOURCE_REPO` / `OPENSPP_SOURCE_REF` | OpenSPP2 upstream / `v19.0.2.0.0` | Source used for that build. Only read when a build is needed. |
| `OPENSPP_NAMESPACE` / `OPENSPP_RELEASE_NAME` | `openspp` | Namespace and Helm release. |
| `OPENSPP_DB_PASSWORD_FILE` / `OPENSPP_ADMIN_PASSWORD_FILE` | empty | File paths for real secrets (prod/remote). Empty = local-dev defaults. |

When the password files are empty, local-dev defaults are used: login **admin / admin** and a fixed DB
password (which also keeps re-deploys idempotent). For production, point the `*_FILE` keys at files
holding real secrets.

## Deploy

```bash
./run.sh -m deploy -a openspp
```

This makes sure the image is available, deploys PostGIS, Odoo and the job worker, waits for them to be
Ready, and runs `tests/openspp/smoke.sh`.

Running it again is safe, but by default it removes the deployment and creates it new, so the database
does not survive. Add `-r false` to upgrade the existing release and keep the data:

```bash
./run.sh -m deploy -a openspp -r false
```

## Access

OpenSPP is exposed over HTTPS through the shared NGINX ingress at `openspp.${GAZELLE_DOMAIN}`
(default `openspp.mifos.gazelle.test`):

```
https://openspp.mifos.gazelle.test/web/login      # admin / admin
```

`setup-env.sh` adds the host to `/etc/hosts`. On Linux it can point to `127.0.0.1` (stable across
restarts); on a remote VM, point it at the VM IP from your client machine. The TLS certificate is
self-signed, so accept the warning on first visit.

Without the ingress you can port-forward:

```bash
kubectl port-forward svc/openspp-odoo 8069:8069 -n openspp   # then http://localhost:8069/web/login
```

## Using it once deployed

Log in with **admin / admin**. The chart installs the base module `spp_base_common`, which gives the
OpenSPP shell: a left menu with **Registry** (the social registry: individuals and groups), **Apps**, and
**Settings**. Which other menus appear depends on the modules you install.

A useful first walkthrough:

1. Open **Registry** and add a registrant, to confirm the database is writable and the UI works.
2. Open **Apps** to see the OpenSPP modules. The list is filtered to the official OpenSPP apps; clear
   the filter to see all of them. Press **Activate** on the one you want.
3. Go back to **Registry**: new fields, views and menus appear once the module is installed.

Useful starting points in **Apps**:

| App | What it adds |
|-----|--------------|
| **OpenSPP Registry** | Consolidated registry management for individuals, groups and membership. |
| **OpenSPP Programs** | Programmes, cycles and entitlements (cash and in-kind), the base for any benefit delivery. |
| **OpenSPP Starter: Farmer Registry** | A ready-made agriculture bundle: farm fields (farm size, land tenure, crops, livestock), FAO vocabularies, land records, irrigation, GIS, and Programs. |
| **OpenSPP API V2** | REST API for external data exchange. |

Modules can also be installed at deploy time instead of by hand, with the `modules` value of the chart
(comma-separated, no spaces), so a fresh deploy comes up with everything already installed.

## Smoke test

```bash
bash tests/openspp/smoke.sh        # override the namespace with OPENSPP_NAMESPACE
```

Checks the pods are Ready, the base module is really installed, and `/web/health` returns 200.

A CircleCI job that builds the image, deploys OpenSPP and runs this smoke test is kept in
`tests/openspp/circleci-job.yml`. It is not wired into `.circleci/config.yml`, so CircleCI does not run
it; the file explains how to enable it.

## Teardown

```bash
./run.sh -m cleanapps -a openspp   # removes OpenSPP (namespace + volumes)
```

## Notes / limitations

- **amd64 by default**: the official `postgis/postgis:18-3.6-alpine` publishes a `linux/amd64` manifest
  only, so the chart pins the pods to amd64 nodes through the `arch` value in `values.yaml`. Running on
  arm64 needs both an arm64 PostGIS image (`postgis.image.*`) and an arm64 build of the OpenSPP image.
- **Image is build-only.** An official OpenSPP2 image (Docker Hub / GHCR) is not published yet; once it
  is, set `OPENSPP_IMAGE_*` to pull it instead of building locally.
- The async **job worker** runs as a separate Deployment (it starts after Odoo has initialised the DB).
