# Building images for Gazelle

Most Gazelle components run images pulled from a registry. Some have no image published upstream, so
someone has to build them, and there are two ways to get the result to the cluster: load it into the
cluster's container runtime, or push it to a registry the cluster can pull from.
`src/utils/build-and-import-image.sh` does both, for the architecture of the host it runs on.

## Quick start

```bash
# build for the host architecture and import into k3s
src/utils/build-and-import-image.sh -n ghcr.io/openmf/openspp -t 19.0 \
    -c <OpenSPP2 checkout> -f <OpenSPP2 checkout>/docker/Dockerfile --target production

# build a multi-architecture image and push it to a registry
src/utils/build-and-import-image.sh -n openmf/some-component -t 1.0.0 \
    --platform linux/amd64,linux/arm64 --push
```

Run `src/utils/build-and-import-image.sh --help` for all options.

## The two output paths

| Path | What it builds | Where it ends up |
|------|----------------|------------------|
| default | the host architecture only | local docker, then imported into k3s |
| `--push` | one or more platforms | pushed to the registry |

They are separate on purpose. A multi-platform build produces a **manifest list**, an index that
points to one image per architecture. Docker's classic image store cannot load one: `--load` fails with
`docker exporter does not currently support exporting manifest lists`. The containerd image store does
hold manifest lists, and it is [the default storage backend for Docker Engine 29.0 and later on fresh
installations](https://docs.docker.com/engine/storage/containerd/), so this is about the image store
rather than about registries. Even there the local path would not gain anything: `ctr images import`
imports a single platform unless you pass `--all-platforms`, and building the other architecture on this
machine means emulation, which is much slower than a native build. So asking for several platforms
without `--push` fails with that explanation instead of paying for a build nobody uses.

## Architecture detection

The host architecture is read from `uname -m` and mapped to Docker and Kubernetes naming
(`x86_64` -> `amd64`, `aarch64` -> `arm64`), the same mapping the environment setup uses. So the same
command produces an amd64 image on a server and an arm64 image on a Raspberry Pi or an Ampere
instance, with nothing to remember.

## Requirements

- **BuildKit / buildx.** The utility uses `docker buildx`, and some Dockerfiles need it: the OpenSPP2
  Dockerfile reads the `TARGETARCH` build argument to pick its downloads, and it is only set by
  BuildKit. If buildx is missing the utility says how to install it.
- **`sudo` for the import step.** The import is delegated to
  `src/utils/import-local-image-to-k3s.sh`, which loads the image into the cluster's container
  runtime and needs root. It resolves the user that owns the built image from `$SUDO_USER`, so it
  also works over a non-interactive ssh and in a pipeline, as long as `sudo` does not ask for a
  password.
- **Registry credentials for `--push`.** The registry comes from the image name
  (`ghcr.io/openmf/openspp` -> ghcr.io; a bare name -> Docker Hub). Credentials come from
  `docker login <registry>`, which stores them in `$HOME/.docker/config.json`; this utility does not
  handle authentication. For ghcr.io, GitHub needs a personal access token with the `write:packages`
  scope. This is unrelated to `config.ini [dockerhub]`, which `src/utils/k3s-docker-login.sh` uses so
  the **cluster can pull**, not so you can push.
- **Disk space on the node.** k3s garbage-collects images when the disk fills up. A build-only image
  cannot be pulled back, so keep the node's root filesystem below about 85% or it may be evicted and
  have to be built again.
- **Linux for the import path.** The import runs `k3s ctr images import`, so it needs k3s on the same
  machine. On macOS the cluster lives inside the Colima virtual machine and the host has no `k3s`
  binary, so run the utility from inside that machine, or use `--push` and let the cluster pull the
  image. The build itself works anywhere Docker does.

## OpenSPP on arm64

The Odoo application image builds for both architectures. The database image is the limit: the
**official `postgis/postgis` has no arm64 build**, so the chart pins `kubernetes.io/arch` to keep
pods off a node they cannot run on, and the default architecture is amd64.

To deploy on arm64 you need an arm64 PostGIS image. A third-party build exists (`imresamu/postgis`,
from the maintainer who drives arm64 PostGIS upstream), but that repository is marked experimental,
so use it for a demo and not for production. Keep the **same PostgreSQL major version** as the chart
default, or an existing data directory will not start.

```bash
# 1. build and import the application image (on the arm64 machine)
src/utils/build-and-import-image.sh -n ghcr.io/openmf/openspp -t 19.0 \
    -c <OpenSPP2 checkout> -f <OpenSPP2 checkout>/docker/Dockerfile --target production

# 2. deploy with an arm64 database image
OPENSPP_POSTGIS_REPOSITORY=imresamu/postgis \
OPENSPP_POSTGIS_TAG=18-3.6.1-alpine3.22 \
./run.sh -m deploy -a openspp
```

The deployment reads the architecture from the host. Set `OPENSPP_ARCH` to override it, or to an
empty value to deploy without a node selector.

If the pods stay `Pending` with a node affinity message, the architecture does not match the node.
If a container reports `exec format error`, the image was built for the other architecture.
