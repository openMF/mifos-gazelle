# OpenG2P Demo — Step-by-Step Walkthrough

This guide walks through running a Government-to-Person (G2P) bulk disbursement demo in Mifos Gazelle end to end: from a deployed cluster, through the OpenG2P PBMS (Payment & Beneficiary Management System) UI, to money actually landing in beneficiary accounts in MifosX/Fineract.

Screenshots live in `docs/openg2p-demo-images/` and embed with a path **relative to this file** (i.e. no leading `docs/`):

```markdown
![description](openg2p-demo-images/step1-login.png)
```

> **Prerequisites:** A running Gazelle cluster with `infra`, `mifosx`, `vnext`, `paymenthub`, and `openg2p` all deployed and healthy (`./run.sh -m deploy -a all`), and the OpenG2P demo data-setup script already run (`src/utils/openg2p/openg2p-data-setup.sh`). See [GAZELLE_OPENG2P.md](GAZELLE_OPENG2P.md) for deployment details.

---

## What This Demo Shows

A government social-welfare programme ("Demo Program") pays a fixed entitlement to a set of eligible citizens:

- **Beneficiaries** are individuals registered in the PBMS registry (mirrored from MifosX clients).
- **Eligibility** is filtered by an age rule — only citizens within the configured age band are enrolled.
- **Payment** is issued as a bulk batch through Payment Hub EE, routed via the Mojaloop vNext switch, and credited into each beneficiary's bank (bluebank) account in Fineract.

At the end, you verify that the eligible beneficiaries' account balances increased by the entitlement amount.

---

## Access & Credentials

| System | URL | Login |
|--------|-----|-------|
| **PBMS (OpenG2P)** | `https://pbms.mifos.gazelle.test` | `admin@openg2p.org` / `adminopeng2p` |
| MifosX web (verify balances) | `https://mifos.mifos.gazelle.test` | `mifos` / `password` (tenant: `bluebank`) |
| Ops Web (view transfers / batch status) | `https://ops.mifos.gazelle.test` | — |
| Ops Web backend API (cert accept only) | `https://ops-bk.mifos.gazelle.test` | — |

> **Note (self-signed certs):** These hosts are served with self-signed certs, so your browser warns on first visit — accept it to proceed. Do this for `https://pbms.mifos.gazelle.test`, and (for Step 9) for **both** `https://ops.mifos.gazelle.test` **and** `https://ops-bk.mifos.gazelle.test` — Ops Web loads from the former but calls the latter for its data, so the backend cert must be trusted too or the transfers list stays empty. Non-Safari browsers on macOS also need Local Network permission enabled — see [MIFOS-GAZELLE-README.md](MIFOS-GAZELLE-README.md).

---

## Step 1 — Log in to PBMS

Open `https://pbms.mifos.gazelle.test` and sign in with `admin@openg2p.org` / `adminopeng2p`.

![PBMS login](openg2p-demo-images/step1-login.png)

---

## Step 2 — View the Beneficiary Registry

From the top menu, open **Registry → Individuals**. You should see the individuals mirrored from MifosX/Fineract as registrants — each with a name, phone number (their MSISDN), and date of birth.

These are the citizens known to the programme. Not all of them will be paid — eligibility (Step 4) decides who is enrolled.

![Beneficiary registry](openg2p-demo-images/step2-Benificiary-Registry.png)

---

## Step 3 — Open the Demo Program

From the top menu, open **Programs** and click into **Demo Program**.

The program page shows its key managers:
- **Eligibility** — the age rule that filters registrants.
- **Cycle** — the disbursement round.
- **Entitlement** — the amount each beneficiary receives.
- **Payment** — wired to Payment Hub EE (routes the actual payment).

![Demo Program overview](openg2p-demo-images/step3-open-demo-program.png)

---

## Step 4 — Review Eligibility & Enrolled Beneficiaries

Open the program's **Beneficiaries** tab. The eligibility rule (an age band, e.g. 18–70) filters the registry: registrants inside the band are **enrolled**; those outside (e.g. a minor, or someone above the upper bound) are **filtered out** and will not be paid.

Confirm the enrolled count matches the eligible subset. This is the group that will receive the disbursement.

![Enrolled beneficiaries](openg2p-demo-images/step4-review-enrolled-benificiary.png)

---

## Step 5 — Create a Cycle

A **cycle** is one disbursement round. From the program, open **Cycles** and click **New Cycle** (or **Create Cycle**). Give it a name (e.g. "Cycle 1") and confirm.

The new cycle starts in **draft** state.

![Create cycle](openg2p-demo-images/step5-create-new-cycle.png)

---

## Step 6 — Generate & Approve Entitlements

With the cycle open:

1. Click **Prepare Entitlements** (or **Generate Entitlements**) — this creates one entitlement per enrolled beneficiary for the configured amount.
2. Review the generated entitlements, then **Approve** them.

Approved entitlements are what turn into payments.

![Approve entitlements](openg2p-demo-images/step6-prepare-entitlement.png)

---

## Step 7 — Approve the Cycle

Once entitlements are approved, **Approve** the cycle itself. The cycle moves to **approved** state, which unlocks payment issuance.

---

## Step 8 — Send Payments

From the approved cycle, click **Send Payments** (or **Pay** / **Issue Payments**).

This hands the batch to the PHEE payment manager wired on the program: PBMS builds a payment CSV and POSTs it to Payment Hub EE, which routes each payment through the Mojaloop vNext switch to the beneficiary's bank.

The payments will show as **sent** in PBMS.

![Send payments](openg2p-demo-images/step8-send-payment.png)

---

## Step 9 — (Optional) Watch the Transfers in Operations Web

Open `https://ops.mifos.gazelle.test`, go to **paymenthub → Transfers**, and watch the individual transfers as the batch processes.

> **Accept the certificate first:** Operations Web (`https://ops.mifos.gazelle.test`) is served with a self-signed cert, and its browser calls a separate backend API host (`https://ops-bk.mifos.gazelle.test`) that has its own self-signed cert. Visit **both** URLs once and click through the certificate warning on each — otherwise the UI loads but its API calls to `ops-bk` silently fail and no data appears.

> **Note:** Operations Web may show a wrong/`REJECTED`/`null` batch status while the batch is still in flight — this is expected. Check the individual **Transfers** rather than the batch summary; once all transfers finish, the batch status and totals settle. The authoritative outcome is the beneficiary's balance in Fineract (Step 10), not the Ops-Web status alone.

![Operations Web transfers](openg2p-demo-images/step9-ops-web-transfers.png)

---

## Step 10 — Verify Payment in MifosX

The real proof is money landing in the beneficiary account. Open `https://mifos.mifos.gazelle.test`, select tenant **bluebank**, and open one of the enrolled beneficiaries (e.g. by name from Step 4). Check their savings account — the balance should have increased by the entitlement amount, with a matching deposit transaction dated today.

![Verify in MifosX](openg2p-demo-images/step10-mifosx-balance.png)

Alternatively, verify from the command line:

```bash
# Balance for a beneficiary MSISDN in bluebank (replace 0495822412)
CID=$(curl -sk -H "Fineract-Platform-TenantId: bluebank" -H "Authorization: Basic bWlmb3M6cGFzc3dvcmQ=" \
  "https://mifos.mifos.gazelle.test/fineract-provider/api/v1/clients?limit=1000" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(next(c['id'] for c in d['pageItems'] if c.get('mobileNo')=='0495822412'))")
curl -sk -H "Fineract-Platform-TenantId: bluebank" -H "Authorization: Basic bWlmb3M6cGFzc3dvcmQ=" \
  "https://mifos.mifos.gazelle.test/fineract-provider/api/v1/clients/$CID/accounts" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('balance:', d['savingsAccounts'][0]['accountBalance'])"
```

---

## Demo Complete

You have run a full G2P bulk disbursement: registered beneficiaries → filtered by eligibility → enrolled → funded → issued a cycle → approved entitlements → sent payments through Payment Hub EE and the Mojaloop switch → and confirmed the money arrived in the beneficiaries' bank accounts.

---

## Troubleshooting

| Symptom | Likely cause | What to check |
|---------|--------------|---------------|
| "Send Payments" does nothing / no batch created | Payment manager not fully wired, or no approved entitlements | Confirm entitlements are **approved** and the cycle is **approved** before sending |
| Payments show "sent" in PBMS but balances don't change | PBMS marks payments sent on POST; it does not poll for the real result | Verify the actual balance in MifosX (Step 10), not the PBMS status |
| Beneficiary not credited | Payee not resolvable at party lookup | Confirm the beneficiary's MSISDN is registered in the vNext ALS oracle (run the data-setup script's oracle step) |
| Only some of a large batch get paid | Payment connector saturates under concurrent load | Keep batch sizes small, or scale the `ph-ee-connector-mojaloop-java` connector resources |
| Cycle won't approve ("approver group not specified") | Cycle manager's approver group unset | Re-run `openg2p-data-setup.sh` (it sets the approver group idempotently) |

For deployment and architecture details, see [GAZELLE_OPENG2P.md](GAZELLE_OPENG2P.md). For the payment-flow internals, see [GOVSTACK.md](GOVSTACK.md).
