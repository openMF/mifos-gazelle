# OpenG2P in Mifos Gazelle

Deploy OpenG2P and run the government-payments demo.

1. [What OpenG2P is](#1-what-openg2p-is)
2. [The gap it fills](#2-the-gap-it-fills)
3. [Deployment](#3-deployment)
4. [The demo](#4-the-demo)
5. [Building OpenG2P images](#5-building-openg2p-images)
6. [Troubleshooting](#6-troubleshooting)


---

## 1. What OpenG2P is

[OpenG2P](https://openg2p.org/) is a Digital Public Good for **Government-to-Person payments** —
the software a government uses to pay social benefits: pensions, child support, disaster relief,
farm subsidies.

It answers the three questions that come before any money moves — **who are our citizens**
(a beneficiary registry), **who qualifies and for how much** (eligibility and entitlements), and
**when do we pay** (payment cycles) — then produces a payment batch and hands it to a payment
system to execute.

Gazelle deploys it as its own app (`-a openg2p`), made of five modules:

| Module | What it does | Default |
|---|---|---|
| **pbms** | Payment & Beneficiary Management System (Odoo). Registry, programmes, eligibility, cycles, entitlements, batches. **The main one.** | off |
| commons | Shared Postgres + Keycloak SSO for the three below | auto |
| social-registry | Deeper beneficiary data management | off |
| spar | Social Registry mapper API | off |
| g2p-bridge | Connects programmes to payment rails; needs spar | off |

**For the demo you only need `pbms`.** It is self-contained — own database, own login — so a
PBMS-only deployment skips `commons` entirely and is much lighter.

---

## 2. The gap it fills

Gazelle already deploys three systems that move money:

| System | Role |
|---|---|
| MifosX / Fineract | Core banking — holds accounts and balances |
| Payment Hub EE | Payment orchestration — executes and tracks payments |
| Mojaloop vNext | The switch — routes payments between banks |

Together they can pay *a person* — if you already know who to pay, how much, and into which
account. A government benefit programme has to decide all of that first, for hundreds of
thousands of people.

None of the three does that. There is nowhere to keep a citizen registry, no way to express
"everyone aged 18–70 in this district gets 500 per month", no concept of a payment cycle, and no
way to turn policy into payment instructions.

**That is the gap OpenG2P fills:**

```
OpenG2P (PBMS)     decides WHO, HOW MUCH, WHEN
      │            registry → eligibility → entitlements → batch
      ▼
Payment Hub EE     executes the batch
      ▼
Mojaloop vNext     routes each payment to the right bank
      ▼
MifosX / Fineract  credits the beneficiary's account
```

---

## 3. Deployment

**Prerequisites:** a working Gazelle environment (`sudo ./setup-env.sh -u $USER`). No `sudo`
needed for OpenG2P itself. The full demo also needs `infra`, `mifosx`, `vnext` and `paymenthub`.

### Enable it

Everything ships off. In `config/config.ini`:

```ini
[openg2p]
enabled = true
OPENG2P_NAMESPACE = openg2p
OPENG2P_SOCIAL_REGISTRY_ENABLED = false
OPENG2P_PBMS_ENABLED = true
OPENG2P_SPAR_ENABLED = false
OPENG2P_G2P_BRIDGE_ENABLED = false
```

That is the recommended setup: **PBMS only**. Turning a flag off removes that module's Helm
release on the next deploy.

Leave the other three off unless you need them — enabling any of them pulls in `commons`
(Postgres + Keycloak), which is heavier and **amd64-only**.

### Deploy

```bash
./run.sh -m deploy -a openg2p          # OpenG2P on its own
./run.sh -m deploy -a all              # everything, including OpenG2P (MifosX , Vnext and PaymentHub EE)
./run.sh -m deploy -a openg2p -d true  # with debug output

./run.sh -m cleanapps -a openg2p       # remove
```

Deploys are idempotent — running again against a healthy release does nothing. If one module
fails to start, the others still deploy and a summary is printed at the end.

### Log in

| Console | URL | Login |
|---|---|---|
| PBMS (Odoo) | `https://pbms.mifos.gazelle.test` | `admin@openg2p.org` / `adminopeng2p` |

Other modules, if enabled, appear at `https://<module>.mifos.gazelle.test`; Keycloak at
`https://keycloak.mifos.gazelle.test`.

`sudo ./setup-env.sh` adds all six hostnames to `/etc/hosts` automatically on a local cluster.
On a remote cluster, add them yourself pointing at your ingress IP:

```
<INGRESS-IP>  openg2p.mifos.gazelle.test social-registry.mifos.gazelle.test pbms.mifos.gazelle.test spar.mifos.gazelle.test g2p-bridge.mifos.gazelle.test keycloak.mifos.gazelle.test
```

These hosts use self-signed certificates — your browser warns on first visit, accept once per host.

### PBMS → Payment Hub EE

The stock PBMS image ships with **no OpenG2P addons installed**. After PBMS starts, Gazelle runs
`src/utils/openg2p/setup-pbms-phee.sh` automatically to download the `openg2p-registry` and
`openg2p-program` addons and install the two modules PBMS needs. A failure only warns; re-run by
hand with:

```bash
./src/utils/openg2p/setup-pbms-phee.sh
```

The script also applies three idempotent fixes, because the upstream addon does not work as-is:

| Fix | Why |
|---|---|
| Stub `payment_sepa_direct_debit` record | The install references an Enterprise-only Odoo module that doesn't exist in Community edition and crashes. An Odoo core packaging issue, not an OpenG2P bug. |
| Cast `amount_issued` to integer | PBMS writes the CSV amount as a float; PHEE's `parseInt` throws and silently zeroes the batch total. |
| Set `batch_type_header=csv`, `payee_id_type=phone` | Upstream's default makes PHEE return HTTP 500. |

---

## 4. The demo

A full G2P disbursement: from a list of citizens, through eligibility rules, to money landing in
real bank accounts.

**Setup.** All of `infra`, `mifosx`, `vnext`, `paymenthub`, `openg2p` deployed and healthy, then
load the demo data (safe to re-run):

```bash
src/utils/openg2p/openg2p-data-setup.sh
```

This copies MifosX clients into the PBMS registry and creates "Demo Program" with an age-based
eligibility rule.

| System | URL | Login |
|---|---|---|
| PBMS | `https://pbms.mifos.gazelle.test` | `admin@openg2p.org` / `adminopeng2p` |
| MifosX web | `https://mifos.mifos.gazelle.test` | `mifos` / `password`, tenant `bluebank` |
| Ops Web | `https://ops.mifos.gazelle.test` | — |
| Ops Web backend | `https://ops-bk.mifos.gazelle.test` | accept cert only |

> **Accept certificates first.** For Step 9 you must visit **both** `ops.` and `ops-bk.` and
> click through the warning — Ops Web loads from the first but fetches data from the second, so
> accepting only one leaves the transfers list mysteriously empty.

### 1. Log in to PBMS

![PBMS login](openg2p-demo-images/step1-login.png)

### 2. View the registry

**Registry → Individuals** — the citizens mirrored from MifosX, each with a name, phone number
(MSISDN) and date of birth. Not everyone here gets paid; eligibility decides that.

![Beneficiary registry](openg2p-demo-images/step2-Benificiary-Registry.png)

### 3. Open the Demo Program

**Programs → Demo Program.** It shows four managers: **Eligibility** (the age rule), **Cycle**
(the disbursement round), **Entitlement** (the amount), and **Payment** (wired to Payment Hub EE).

![Demo Program overview](openg2p-demo-images/step3-open-demo-program.png)

### 4. Check who is enrolled

The **Beneficiaries** tab. The age band (e.g. 18–70) splits the registry — registrants inside it
are enrolled, a minor or someone too old is filtered out. This is who gets money.

![Enrolled beneficiaries](openg2p-demo-images/step4-review-enrolled-benificiary.png)

### 5. Create a cycle

**Cycles → New Cycle.** Name it, confirm. It starts in **draft**.

![Create cycle](openg2p-demo-images/step5-create-new-cycle.png)

### 6. Generate and approve entitlements

Click **Prepare Entitlements** (one per enrolled beneficiary), review, then **Approve**.
Approved entitlements are what become payments.

![Approve entitlements](openg2p-demo-images/step6-prepare-entitlement.png)

### 7. Approve the cycle

Approve the cycle itself. It moves to **approved**, which unlocks payment.

### 8. Send the payments

Click **Send Payments**. PBMS builds a CSV and posts it to Payment Hub EE, which routes each
payment through the Mojaloop switch to the beneficiary's bank.

![Send payments](openg2p-demo-images/step8-send-payment.png)

> "Sent" means PBMS handed the batch over — not that money arrived. PBMS never polls for the
> result. Step 10 is the real check.

### 9. (Optional) Watch the transfers

`https://ops.mifos.gazelle.test` → **paymenthub → Transfers**. The *batch* status may show
`REJECTED` or `null` while still in flight — expected. Watch individual transfers instead.

![Operations Web transfers](openg2p-demo-images/step9-ops-web-transfers.png)

### 10. Verify the money arrived

Open `https://mifos.mifos.gazelle.test`, tenant **bluebank**, and open a beneficiary from Step 4.
Their savings balance should have increased by the entitlement amount, with a deposit dated today.

![Verify in MifosX](openg2p-demo-images/step10-mifosx-balance.png)

Or from the command line (replace the MSISDN):

```bash
CID=$(curl -sk -H "Fineract-Platform-TenantId: bluebank" -H "Authorization: Basic bWlmb3M6cGFzc3dvcmQ=" \
  "https://mifos.mifos.gazelle.test/fineract-provider/api/v1/clients?limit=1000" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(next(c['id'] for c in d['pageItems'] if c.get('mobileNo')=='0495822412'))")
curl -sk -H "Fineract-Platform-TenantId: bluebank" -H "Authorization: Basic bWlmb3M6cGFzc3dvcmQ=" \
  "https://mifos.mifos.gazelle.test/fineract-provider/api/v1/clients/$CID/accounts" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('balance:', d['savingsAccounts'][0]['accountBalance'])"
```

That is the full chain: registry → eligibility → enrollment → cycle → entitlements → batch →
Payment Hub EE → Mojaloop → money in the bank account.

---

## 5. Building OpenG2P images

Most OpenG2P images are pulled from a registry and need nothing. You only get involved when an
image is **not published for the architecture you are deploying on**, or when you need a patched
build.

### Step 1 — Check what is published

Works for any image, any architecture:

```bash
docker manifest inspect -v <image>:<tag> \
  | python3 -c "import json,sys; d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; \
print([ (x.get('Descriptor') or {}).get('platform') for x in d ])"
```

`docker manifest inspect -v` is required — without `-v` a single-architecture image reports no
platform data at all. Ignore any `unknown/unknown` entries; those are build attestations, not
platforms.

**This branch makes the PBMS demo arm64-capable** — every image the PBMS-only deploy pulls is now multi-arch:

| Image the PBMS demo uses | Arch | How it got there |
|---|---|---|
| `openg2p-pbms-core:3.0.0` | amd64, arm64 | upstream is amd64-only; the pbms overlay points at a **multi-arch rebuild** — build/publish your own via the steps below |
| `openg2p-pbms-bg-task-{api,celery-beat-producers,celery-workers}:3.0.0` | amd64, arm64 | upstream already multi-arch |
| `bitnamilegacy/postgresql` (commons + pbms) | amd64, arm64 | repointed from amd64-only `openg2p/postgresql` |
| `bitnamilegacy/redis` (pbms) | amd64, arm64 | repointed from amd64-only `openg2p/redis` |
| `postgres:16.9-alpine` (bg-task `postgres-checker`) | amd64, arm64 | repointed from the amd64-only, unpinned `jbergknoff/postgresql-client` |

The only amd64-only images left — `openg2p/keycloak:24.0.5-debian-12-r1-g2p1`, `keycloak-init`,
`postgres-init` — all live in **`commons`**, which a **PBMS-only deploy does not deploy** (commons
is pulled only by `social-registry`/`spar`/`g2p-bridge`). So:

- **PBMS-only → arm64-ready.** Rebuild `openg2p-pbms-core` once for your own registry (steps below); everything else it uses is already multi-arch.
- **Full stack (`social-registry`/`spar`/`g2p-bridge`) → still amd64-only** — their commons images have no multi-arch build yet.

### Step 2 — Repoint before you rebuild

If the image is a *third-party* base image that OpenG2P merely re-hosts, a multi-architecture
equivalent usually already exists under a different name. Changing one line in `values.yaml` is
far cheaper than a build. Gazelle already does this:

| Upstream (amd64 only) | Repointed to (multi-arch) |
|---|---|
| `openg2p/postgresql` | `bitnamilegacy/postgresql`, same tag |
| `openg2p/redis` | `bitnamilegacy/redis`, same tag |
| `jbergknoff/postgresql-client:latest` | `postgres:16.9-alpine` |

Only rebuild when the image is OpenG2P's **own application code**, where no equivalent can exist.

### Step 3 — Get the source

OpenG2P application images are built from
[`OpenG2P/openg2p-pbms-docker`](https://github.com/OpenG2P/openg2p-pbms-docker). Mind the
naming: the **git tag** is `v3.0.0` while the **image tag** is `3.0.0`.

Clone it **outside** your Gazelle checkout — it is a separate repo and would otherwise show up as
untracked clutter in `git status`:

```bash
cd ~   # anywhere outside mifos-gazelle
git clone --branch v3.0.0 https://github.com/OpenG2P/openg2p-pbms-docker.git
```

Each image is described by a `.txt` **package file** in that repo, and the recipe differs per
image:

| Image | Package file | Build context | Extra step |
|---|---|---|---|
| `openg2p-pbms-core` | `openg2p-pbms-odoo/3.0.0.txt` | `openg2p-pbms-odoo/utils` | `package.sh` — **required** |
| bg-task api / producers / workers | `openg2p-pbms-bg-tasks/*.txt` | repo root | none |

The package file's first lines are the image name and the Odoo base version (`pbms-core`), or the
image name, Dockerfile path and context (bg-tasks). Read it before building — it is the source of
truth for the build arguments.

### Step 4 — Run the image's prepare step

Some images need their dependencies fetched before the Docker build; the build fails without it.

For **`pbms-core`** this is mandatory. The repo holds only the packaging — the application code
lives in four separate repos. `package.sh` clones the versions pinned in `3.0.0.txt` into
`utils/tmpdir/`, which the Dockerfile then copies into the image:

```bash
cd ~/openg2p-pbms-docker/openg2p-pbms-odoo/utils
bash package.sh ../3.0.0.txt
```

Use `bash package.sh`, not `./package.sh`. Upstream commits the file with mode `100644`, so it is
**not executable** on a fresh clone and `./package.sh` fails with `Permission denied` — upstream's
own CI works around it with `chmod +x package.sh || true`.

You should end up with four directories in `tmpdir/`: `oca`, `openg2p-commons`, `openg2p-pbms`,
`openg2p-pbms-extensions`. Run it from `utils/` — its paths are relative to that folder. It wipes
and recreates `tmpdir` each time, so it is safe to re-run.

The **bg-task** images need no prepare step; their Python dependencies are resolved during the
Docker build.

### Step 5 — Build

Use Gazelle's image utility — see [BUILDING-IMAGES.md](BUILDING-IMAGES.md). Choose the target
platforms with `--platform`; it is not fixed to any architecture:

```bash
docker login   # only needed when pushing

src/utils/build-and-import-image.sh \
  -n <registry-namespace>/<image-name> -t <tag> \
  -c <build-context> \
  -f <build-context>/Dockerfile \
  [--build-arg KEY=VALUE] \
  [--platform <list>] [--push]
```

There are two output modes, and which one you want depends on your goal:

| Goal | Flags | Result |
|---|---|---|
| Run it on **this machine's** cluster | *(omit both)* | Builds for the host architecture and imports straight into k3s. No registry, no login. |
| Publish for **several** architectures | `--platform linux/amd64,linux/arm64 --push` | Builds each platform and pushes a manifest list to the registry. |

A multi-platform build **must** use `--push`. It produces a manifest list, which only a registry
can store — it cannot be exported with `docker save` and so cannot be imported into k3s. The
script stops with that explanation rather than failing halfway.

**Building for a foreign architecture needs QEMU emulation.** Check your builder advertises the
platforms you want:

```bash
docker buildx ls    # look for your targets in the PLATFORMS column
```

If a target is missing, install the emulators once:

```bash
docker run --privileged --rm tonistiigi/binfmt --install all
```

If you already have a working multi-arch builder, pass it with `--builder <name>` to reuse its
warm cache — otherwise the script creates its own `gazelle-multiarch` builder, which starts cold.

Emulated builds are slow: for `pbms-core`, allow anywhere from 30 minutes to over an hour and
around 15 GB of free disk. **Run it under `tmux` or `screen`** so it survives a dropped SSH
session.

**Worked example — `pbms-core` for both architectures.** The context is the `utils/` folder, not
the repo root, and `BASE_VERSION` comes from line 2 of `3.0.0.txt`:

```bash
src/utils/build-and-import-image.sh \
  -n <your-dockerhub-user>/openg2p-pbms-core -t 3.0.0-test1 \
  -c ~/openg2p-pbms-docker/openg2p-pbms-odoo/utils \
  -f ~/openg2p-pbms-docker/openg2p-pbms-odoo/utils/Dockerfile \
  --build-arg BASE_VERSION=17.0-20250807 \
  --platform linux/amd64,linux/arm64 \
  --builder multiarch \
  --push
```

**Build to a throwaway tag first.** If you push straight over the tag your `values.yaml` already
uses, a bad build takes out your working image with no way back. Verify the test tag, then promote
it by digest — a registry-side copy, so no second hour-long build:

```bash
docker buildx imagetools create \
  -t <your-dockerhub-user>/openg2p-pbms-core:3.0.0 \
  <your-dockerhub-user>/openg2p-pbms-core@sha256:<digest-from-the-verify-step>
```

### Step 6 — Point the chart at your image

Each image is overridden in its module's wrapper `values.yaml` under
`src/deployer/helm/openg2p/`. For `pbms-core`, in `openg2p-pbms/values.yaml`:

```yaml
pbms:
  odoo:
    image:
      repository: <your-dockerhub-user>/openg2p-pbms-core
      tag: "3.0.0"
```

The bg-task images sit under `pbms.openg2p-pbms-bg-task-*.image`, and commons images under
`commons.<service>.image` in `openg2p-commons/values.yaml`.

### Step 7 — Verify

Re-run the check from Step 1, or:

```bash
docker buildx imagetools inspect <your-dockerhub-user>/openg2p-pbms-core:3.0.0
```

Confirm every architecture you asked for is listed.

### Full example — publishing PBMS to `openmf`

The complete sequence for `openg2p-pbms-core`, from clone to a published multi-architecture
image in the openmf dockerhub:

```bash
# 1. Get the source, OUTSIDE your Gazelle checkout.
#    Git tag is v3.0.0; the image tag is 3.0.0.
cd ~
git clone --branch v3.0.0 https://github.com/OpenG2P/openg2p-pbms-docker.git
cd openg2p-pbms-docker

# 2. Prepare — clones the four pinned addon repos into utils/tmpdir/.
(cd openg2p-pbms-odoo/utils && bash package.sh ../3.0.0.txt)

# 3. Authenticate (needs push rights on the target namespace)
docker login

# 4. Build both architectures and push as one manifest list.
#    Run under tmux/screen — the emulated arm64 leg can take over an hour.
~/mifos-gazelle/src/utils/build-and-import-image.sh \
  -n openmf/openg2p-pbms-core -t 3.0.0-gazelle-2.0.0 \
  -c "$PWD/openg2p-pbms-odoo/utils" \
  -f "$PWD/openg2p-pbms-odoo/utils/Dockerfile" \
  --build-arg BASE_VERSION=17.0-20250807 \
  --platform linux/amd64,linux/arm64 \
  --push

# 5. Confirm both architectures landed
docker buildx imagetools inspect openmf/openg2p-pbms-core:3.0.0-gazelle-2.0.0
```


## 6. Troubleshooting

### Demo

| Symptom | What to do |
|---|---|
| "Send Payments" does nothing | Approve **both** the entitlements and the cycle first |
| PBMS says "sent" but balances don't change | PBMS marks sent on POST and never polls. Check the balance in MifosX (Step 10) |
| A beneficiary is never credited | Their MSISDN isn't in the vNext ALS oracle — re-run the data-setup script's oracle step |
| Only part of a large batch is paid | Connector saturates under load. Use smaller batches or give `ph-ee-connector-mojaloop-java` more resources |
| Cycle won't approve ("approver group not specified") | Re-run `openg2p-data-setup.sh` — it sets this idempotently |
| Ops Web transfers list empty | Accept the `ops-bk.mifos.gazelle.test` certificate |

---

**See also:**·
[BUILDING-IMAGES.md](BUILDING-IMAGES.md) · [GOVSTACK.md](GOVSTACK.md) ·
[MIFOS-GAZELLE-README.md](MIFOS-GAZELLE-README.md)
