# Upgrading MifosX in Mifos Gazelle

A checklist for adopting a future MifosX release. Gazelle currently tracks **25.12.25**; the pins that make up that release line live in [VERSIONS.md](../src/deployer/manifests/mifosx/VERSIONS.md), and [MIFOSX.md](MIFOSX.md) describes what each component is and how to use it.

Most of an upgrade is changing pins and rebuilding the images Gazelle builds itself. Work through the steps in order — later ones assume the pins are already settled.

---

## 1. Find out what changed

MifosX releases are published on [SourceForge](https://sourceforge.net/projects/mifos/files/) using a `YY.MM.DD` scheme, and a release bundles specific versions of Fineract, the web app and PostgreSQL. Read the release notes for the target version and write down the new versions before touching anything.

Check separately whether the **Pentaho reporting plugin** has a release matching the new Fineract. The plugin is versioned independently and is not part of the MifosX release bundle.

## 2. Update the pins

Change [VERSIONS.md](../src/deployer/manifests/mifosx/VERSIONS.md) and the manifests under `src/deployer/manifests/mifosx/` **in the same commit**, so the table never disagrees with what deploys.

Confirm nothing was missed — every `image:` in the manifests should appear in the table:

```bash
grep -h '^\s*image:' src/deployer/manifests/mifosx/*.yaml | grep -v '#' | sed 's/.*image: *//' | sort -u
```

Two pins are not `image:` lines and are easy to overlook:

- the **Pentaho plugin zip**, fetched by the `fetch-reporting-plugin` initContainer in `fineract-server-deployment.yaml`
- the shared **PostgreSQL** version, in `src/deployer/helm/infra/values.yaml`

## 3. Rebuild the images Gazelle builds itself

Three modules publish no container image, so Gazelle builds them from source: the **Workflow Engine**, the **Credit Bureau** and **Loan Assessment**. A new MifosX release does not rebuild them — you do.

Always use the repo's builder rather than raw `docker buildx`, so the build stays reproducible:

```bash
docker login
git clone https://github.com/openMF/mifos-workflow.git
src/utils/build-and-import-image.sh \
    -n <namespace>/mifos-workflow -t <tag> \
    -c mifos-workflow -f mifos-workflow/Dockerfile \
    --platform linux/amd64,linux/arm64 --push
```

Repeat for `mifos-x-credit-bureau-plugin` and `reactive-loan-module`. `--platform linux/amd64,linux/arm64` is what keeps Apple Silicon and Raspberry Pi working and requires `--push`; see [BUILDING-IMAGES.md](BUILDING-IMAGES.md). Then update the pins from step 2 to the tags you pushed.

If a module fails to build against the new Fineract, fix it **upstream** rather than in a fork — that is what keeps the next upgrade cheap.

## 4. Redeploy

```bash
./run.sh -m deploy -a mifosx
```

The deploy warns if any image in the manifests cannot be found in a registry, which catches a pin you bumped but never published. The warning is advisory and does not stop the deploy.

If the upgrade added a module with its own ingress, add the hostname to `MIFOSXHOSTS` in `src/environmentSetup/environmentSetup.sh` and re-run `sudo ./setup-env.sh -u $USER`, otherwise the URL will not resolve.

## 5. Verify

Check the pods and ingresses first:

```bash
kubectl -n mifosx get pods      # every pod 1/1
kubectl -n mifosx get ingress   # one host per exposed module
```

Note that the deploy only waits on Fineract's tenant APIs, so a module can be broken while the deploy still reports success. Then exercise each module end to end:

```bash
./src/utils/demo-workflow.sh          # onboards a client and activates it in Fineract
./src/utils/demo-credit-bureau.sh     # registers a bureau and pulls a mock report
./src/utils/demo-message-gateway.sh   # sends a message through the Dummy provider
./src/utils/demo-loan-module.sh       # creates a loan and waits for the risk row
```

Each script fails loudly if MifosX is not deployed. If one fails after an upgrade, that module is the regression — the scripts are the fastest way to find which.

Confirm reporting separately, since it is staged into the Fineract pod rather than run as its own service:

```bash
kubectl -n mifosx logs deploy/fineract-server -c fetch-reporting-plugin | tail -5
```

## 6. Raise the PR

Include the before and after versions, and say which images you rebuilt and where you pushed them. Update [MIFOSX.md](MIFOSX.md) if the upgrade changed how a component is used, and add an entry to [RELEASE-NOTES.md](RELEASE-NOTES.md).

---

## Things that have bitten us before

- **A module image built for one architecture only.** It deploys fine on the machine that built it and fails on Apple Silicon or a Pi. Always build multi-arch.
- **A pin bumped but never pushed.** The pods sit in `ImagePullBackOff` and the deploy times out on the tenant wait with an unhelpful message. The image check at deploy time is there to catch this earlier.
- **The Pentaho plugin drifting from Fineract.** The plugin is released separately, so a Fineract bump can leave reporting on an incompatible plugin. Reporting failures usually surface as a 403 from `runreports`, not as a startup error.
- **Assuming the deploy verifies the modules.** It does not — it waits on Fineract only. Run the demo scripts.
