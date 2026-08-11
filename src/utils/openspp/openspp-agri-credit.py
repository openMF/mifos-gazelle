#!/usr/bin/env python3
"""
Agri credit demo: OpenSPP2 farmer registry -> credit decision -> MifosX loan.

For every farmer enrolled in the programme this script scores the farm with OpenSPP's own
scoring engine, records the farmer's consent to share that verdict with the lender, and then
opens and disburses a loan in MifosX. The lender receives the score and the attributes behind
it, never the registry record.

Two ways to open the loan, chosen with --origination:
  workflow  the Mifos workflow engine runs its BPMN loan origination process, and the score is
            what its Credit Assessment step receives. Its Fineract tenant is fixed at deploy
            time, so the borrower is created there.
  direct    straight against Fineract, so the loan lands in the same savings account that
            received the subsidy.

Idempotent: a farmer who already holds a loan from this demo is left alone, and one whose
loan a cut run left half open is carried to the end instead of opening a second one.
"""

import argparse
import datetime
import importlib.util
import sys
import xmlrpc.client
from pathlib import Path

import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
DATA_DIR = REPO_ROOT / "src" / "utils" / "data-loading"
DEFAULT_CONFIG = REPO_ROOT / "config" / "config.ini"
HTTP_TIMEOUT = 60

SCORING_MODULE = "spp_scoring"
SCORECARD_CODE = "AGRI_CREDIT_V1"
SCORECARD_NAME = "Agri credit scorecard"
SCORING_GROUPS = ("spp_scoring.group_scoring_manager", "spp_scoring.group_scoring_officer")

CONSENT_PURPOSES = ("spp_consent.purpose_sp_eligibility", "spp_consent.purpose_sp_data_sharing")
CONSENT_DATA_CATEGORIES = ("spp_consent.pd_identifying", "spp_consent.pd_location",
                           "spp_consent.pd_sp_livelihood")
CONSENT_VALID_DAYS = 365
# The two organisations the consent record names: who holds the registry and who receives the
# verdict. They exist in OpenSPP only so the consent can point at them.
LENDER_NAME = "Gazelle Agricultural Bank"
REGISTRY_AUTHORITY_NAME = "Farmer Registry Authority"

# Fineract parses dates with this pattern and rejects the call without it.
FINERACT_DATE_FORMAT = "dd MMMM yyyy"
LOAN_PRODUCT_NAME = "Agri input loan"
LOAN_PRODUCT_SHORT_NAME = "AGRI"
# Fineract keeps both of these as values of its own code lists, whose names are fixed.
PURPOSE_CODE = "LoanPurpose"
LOAN_PURPOSE = "Agricultural inputs"
COLLATERAL_CODE = "LoanCollateral"
COLLATERAL_TYPE = "Farm land"
REGISTRY_TABLE = "openspp_registry_snapshot"

# The loan is a seasonal input loan: one repayment after the season, no interest, so the demo
# shows where the amount comes from instead of an amortisation schedule.
LOAN_TERM_MONTHS = 6
TRANSACTION_STRATEGY = "mifos-standard-strategy"
BASE_PRINCIPAL = 100.0
PRINCIPAL_PER_HECTARE = 150.0
# What each score band is allowed to borrow, as a share of the amount the land alone justifies.
BAND_LIMITS = {"A": 1.0, "B": 0.75, "C": 0.5}


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gen = _load("gen_mifos_vnext", DATA_DIR / "generate-mifos-vnext-data.py")
loader = _load("openspp_loader", Path(__file__).resolve().parent / "load-openspp-agri-data.py")


def openspp_call(url, db, user, password):
    """Return a call(model, method, *args, **kw) bound to verified Odoo credentials.

    Odoo's XML-RPC API keeps no session, so the database, user id and password travel on
    every call and the closure carries them.
    """
    uid = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/common").authenticate(db, user, password, {})
    if not uid:
        sys.exit(f"ERROR: OpenSPP auth failed for {user}@{db}")
    models = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/object")

    def call(model, method, *args, **keywords):
        return models.execute_kw(db, uid, password, model, method, list(args), keywords)

    return call, uid


def fineract_headers(tenant):
    return {"Fineract-Platform-TenantId": tenant, "Authorization": gen.AUTH_HEADER_VALUE,
            "Content-Type": "application/json", "Accept": "application/json"}


def read_farmers(call, program_name):
    """Farmers enrolled in the programme, with the farm attributes the decision reads."""
    program = call("spp.program", "search", [["name", "=", program_name]])
    if not program:
        sys.exit(f"ERROR: program '{program_name}' not found in OpenSPP")

    memberships = call("spp.program.membership", "search_read",
                       [["program_id", "=", program[0]]], fields=["partner_id"])
    farmers = []
    for membership in memberships:
        partner_id = membership["partner_id"][0]
        partner = call("res.partner", "read", [partner_id],
                       fields=["name", "farm_size_hectares", "experience_years",
                               "land_tenure_id"])[0]
        phones = call("spp.phone.number", "search_read",
                      [["partner_id", "=", partner_id], ["disabled", "=", False]],
                      fields=["phone_no"])
        activities = call("spp.farm.activity", "search_read",
                          [["crop_farm_id", "=", partner_id], ["activity_type", "=", "crop"]],
                          fields=["species_id"])
        farmers.append({
            "partner_id": partner_id,
            "name": partner["name"],
            "msisdn": phones[0]["phone_no"] if phones else None,
            "hectares": partner["farm_size_hectares"] or 0.0,
            "experience_years": partner["experience_years"] or 0,
            "tenure": partner["land_tenure_id"][1] if partner["land_tenure_id"] else "unknown",
            "crop": activities[0]["species_id"][1] if activities else "unknown",
        })
    return farmers


def scorecard_indicators():
    """The five registry attributes the scorecard reads, and what each one is worth.

    Ranges are inclusive on both ends and are rejected when they overlap, so every band stops
    below the next one: by 0.01 for the hectares, which are decimal, and by a whole year for
    the ones counted in years.
    """
    return [
        {"code": "FARM_SIZE", "name": "Farm size", "field_path": "farm_size_hectares",
         "calculation_type": "range", "weight": 1.0,
         "bands": [(0, 0.99, 10), (1, 1.99, 20), (2, 4.99, 30), (5, 9999, 20)]},
        {"code": "EXPERIENCE", "name": "Years farming", "field_path": "experience_years",
         "calculation_type": "range", "weight": 1.0,
         "bands": [(0, 1, 5), (2, 4, 15), (5, 9, 25), (10, 99, 30)]},
        {"code": "TENURE", "name": "Land tenure", "field_path": "land_tenure_id.code",
         "calculation_type": "mapped", "weight": 1.0,
         "values": [("self", 25), ("family", 20), ("cooperative", 15), ("leased", 12)]},
        {"code": "LIVESTOCK", "name": "Livestock held", "field_path": "total_livestock_heads",
         "calculation_type": "range", "weight": 1.0,
         "bands": [(0, 0, 0), (1, 19, 5), (20, 9999, 10)]},
        {"code": "PRODUCTIVE", "name": "Land under production", "field_path": "has_productive_land",
         "calculation_type": "direct", "weight": 5.0, "required": True},
    ]


def scorecard_thresholds():
    """Score bands, each one ending 0.01 below the next.

    The engine matches a band with both ends included, so bands that share a boundary are
    rejected as overlapping, and bands further apart than 0.01 are rejected as leaving a gap.
    That leaves exactly one valid shape.
    """
    return [
        {"name": "Basic", "min_score": 0, "max_score": 49.99, "display_color": "orange",
         "classification_code": "C", "classification_label": "Basic terms"},
        {"name": "Standard", "min_score": 50, "max_score": 74.99, "display_color": "yellow",
         "classification_code": "B", "classification_label": "Standard terms"},
        {"name": "Preferred", "min_score": 75, "max_score": 100, "display_color": "green",
         "classification_code": "A", "classification_label": "Preferred terms"},
    ]


def build_indicator_values(indicator):
    """Odoo create commands for the bands or the lookup table of one indicator."""
    if "bands" in indicator:
        return [(0, 0, {"range_min": low, "range_max": high, "output_score": score})
                for low, high, score in indicator["bands"]]
    if "values" in indicator:
        return [(0, 0, {"input_value": value, "output_score": score})
                for value, score in indicator["values"]]
    return []


def ensure_scorecard(call, uid):
    """Create and activate the credit scorecard, once.

    Indicators read the registry through field paths rather than CEL: the engine's CEL
    context carries only the common registrant fields, so a formula would never see a
    hectare and would quietly score zero.
    """
    loader.ensure_module_installed(call, SCORING_MODULE)
    for group in SCORING_GROUPS:
        loader.ensure_user_in_group(call, uid, group)

    indicators = scorecard_indicators()
    total_weight = sum(indicator["weight"] for indicator in indicators)
    existing = call("spp.scoring.model", "search_read", [["code", "=", SCORECARD_CODE]],
                    fields=["is_active"], limit=1)
    if existing:
        model_id = existing[0]["id"]
        if not existing[0]["is_active"]:
            call("spp.scoring.model", "write", [model_id], {"expected_total_weight": total_weight})
            call("spp.scoring.model", "action_activate", [model_id])
        return model_id

    model_id = call("spp.scoring.model", "create", {
        "name": SCORECARD_NAME,
        "code": SCORECARD_CODE,
        "category": "eligibility",
        "calculation_method": "weighted_sum",
        # The engine refuses to activate a model whose weights do not add up to what it was
        # told to expect, so the expectation is derived from the indicators themselves.
        "expected_total_weight": total_weight,
        "description": "Credit capacity of a smallholder farm, from the farmer registry.",
    })
    for indicator in indicators:
        call("spp.scoring.indicator", "create", {
            "model_id": model_id,
            "code": indicator["code"],
            "name": indicator["name"],
            "field_path": indicator["field_path"],
            "source_model": "res.partner",
            "calculation_type": indicator["calculation_type"],
            "weight": indicator["weight"],
            "is_required": indicator.get("required", False),
            "value_mapping_ids": build_indicator_values(indicator),
        })
    for threshold in scorecard_thresholds():
        call("spp.scoring.threshold", "create", dict(threshold, model_id=model_id))

    call("spp.scoring.model", "action_activate", [model_id])
    print(f"Scorecard '{SCORECARD_NAME}' created and activated", file=sys.stderr)
    return model_id


def score_farmers(call, model_id, farmers):
    """Score every farmer and return the result keyed by registrant."""
    wizard_id = call("spp.batch.scoring.wizard", "create", {
        "model_id": model_id,
        "registrant_ids": [(6, 0, [farmer["partner_id"] for farmer in farmers])],
    })
    call("spp.batch.scoring.wizard", "action_run_batch_scoring", [wizard_id])

    results = call("spp.scoring.result", "search_read",
                   [["model_id", "=", model_id],
                    ["registrant_id", "in", [farmer["partner_id"] for farmer in farmers]]],
                   fields=["registrant_id", "score", "classification_code", "classification_label",
                           "model_version", "is_complete", "error_messages"],
                   order="calculation_date desc, id desc")
    latest = {}
    for result in results:
        latest.setdefault(result["registrant_id"][0], result)
    return latest


def loan_principal(hectares, band):
    """What the farm can borrow: land-based amount, capped by the score band."""
    justified = BASE_PRINCIPAL + hectares * PRINCIPAL_PER_HECTARE
    return round(justified * BAND_LIMITS.get(band, BAND_LIMITS["C"]))


def ensure_organisation(call, name):
    """An organisation in OpenSPP, so consent can name who holds and who receives the data."""
    found = call("res.partner", "search", [["name", "=", name], ["is_company", "=", True]])
    if found:
        return found[0]
    return call("res.partner", "create", {"name": name, "is_company": True})


def link_consent_to_registrants(call, consent_id, partner_ids):
    """Show the consent on the people it concerns.

    The registrant form lists its consent_ids, which is how the module's own wizard files a
    consent, so a record created on its own would exist without ever showing up on the farmer.
    """
    for partner_id in partner_ids:
        call("res.partner", "write", [partner_id], {"consent_ids": [(4, consent_id)]})


def ensure_consent(call, farmer, lender_id, controller_id):
    """Record the farmer's consent to share the credit verdict with the lender.

    The subsidy is the registry paying its own beneficiary; a loan sends personal data to a
    third party, which is what needs consent. Returns the consent id, or None when the
    household has no head registered to sign it.
    """
    # Matched by the id of the membership type and not by its code, because 'head' is also a
    # code of the relationship vocabulary.
    head_type = loader.vocabulary_code_id(call, loader.MEMBERSHIP_TYPE_VOCABULARY, "head")
    head = call("spp.group.membership", "search_read",
                [["group", "=", farmer["partner_id"]],
                 ["membership_type_ids", "in", [head_type]]], fields=["individual"], limit=1)
    if not head:
        return None
    signatory_id = head[0]["individual"][0]

    name = f"Agri credit data sharing - {farmer['name']}"
    existing = call("spp.consent", "search",
                    [["name", "=", name], ["status", "=", "given"]])
    if existing:
        link_consent_to_registrants(call, existing[0], [farmer["partner_id"], signatory_id])
        return existing[0]

    today = datetime.date.today()
    consent_id = call("spp.consent", "create", {
        "name": name,
        "record_type": "consent_record",
        "signatory_id": signatory_id,
        "group_id": farmer["partner_id"],
        "controller_id": controller_id,
        "recipient_mode": "specific",
        "recipient_ids": [(6, 0, [lender_id])],
        "purpose_ids": [(6, 0, [loader.xmlid_to_id(call, xmlid) for xmlid in CONSENT_PURPOSES])],
        "personal_data_ids": [(6, 0, [loader.xmlid_to_id(call, xmlid)
                                      for xmlid in CONSENT_DATA_CATEGORIES])],
        "legal_basis": "consent",
        "status": "given",
        "collection_method": "electronic",
        "effective_date": today.isoformat(),
        "expiry": (today + datetime.timedelta(days=CONSENT_VALID_DAYS)).isoformat(),
    })
    link_consent_to_registrants(call, consent_id, [farmer["partner_id"], signatory_id])
    return consent_id


def ensure_code_value(headers, code_name, value_name):
    """Fineract code value id, creating the value under its code when missing.

    The id is read back from the list instead of taken from the create response, which
    answers with the id of the code and not of the value just added.
    """
    codes = gen.make_api_request("GET", f"{gen.API_BASE_URL}/codes", headers) or []
    code = next((c for c in codes if c.get("name") == code_name), None)
    if not code:
        print(f"  WARN: this Fineract has no '{code_name}' code, so that field is left empty",
              file=sys.stderr)
        return None

    def value_id():
        values = gen.make_api_request("GET", f"{gen.API_BASE_URL}/codes/{code['id']}/codevalues",
                                      headers) or []
        return next((v["id"] for v in values if v.get("name") == value_name), None)

    found = value_id()
    if found:
        return found
    gen.make_api_request("POST", f"{gen.API_BASE_URL}/codes/{code['id']}/codevalues",
                         headers, json_data={"name": value_name, "isActive": True})
    return value_id()


def ensure_loan_product(headers, currency):
    """The agri loan product, created once per tenant.

    Accounting is left off (accountingRule 1), so the product needs no chart of accounts.
    """
    products = gen.make_api_request("GET", f"{gen.API_BASE_URL}/loanproducts", headers) or []
    existing = next((p for p in products if p.get("name") == LOAN_PRODUCT_NAME), None)
    if existing:
        return existing["id"]

    payload = {
        "name": LOAN_PRODUCT_NAME,
        "shortName": LOAN_PRODUCT_SHORT_NAME,
        "description": "Seasonal input loan sized from the farmer registry.",
        "currencyCode": currency,
        "digitsAfterDecimal": 2,
        "inMultiplesOf": 1,
        "principal": 1000,
        "numberOfRepayments": 1,
        "repaymentEvery": LOAN_TERM_MONTHS,
        "repaymentFrequencyType": 2,
        "interestRatePerPeriod": 0,
        "interestRateFrequencyType": 2,
        "amortizationType": 1,
        "interestType": 0,
        "interestCalculationPeriodType": 1,
        "transactionProcessingStrategyCode": TRANSACTION_STRATEGY,
        "accountingRule": 1,
        "isInterestRecalculationEnabled": False,
        "daysInMonthType": 1,
        "daysInYearType": 1,
        "locale": "en",
        "dateFormat": FINERACT_DATE_FORMAT,
    }
    created = gen.make_api_request("POST", f"{gen.API_BASE_URL}/loanproducts", headers,
                                   json_data=payload)
    if not created:
        sys.exit(f"ERROR: could not create the loan product '{LOAN_PRODUCT_NAME}' in Fineract")
    print(f"Loan product '{LOAN_PRODUCT_NAME}' created", file=sys.stderr)
    return created.get("resourceId")


def read_clients(headers):
    """Every client of the tenant, read once because Fineract has no usable filter here."""
    # limit=-1 returns them all. Fineract pages at 200 by default and the match happens here,
    # so a client past the page would look like it does not exist.
    clients = gen.make_api_request("GET", gen.CLIENTS_API_URL, headers, params={"limit": -1})
    return (clients or {}).get("pageItems", [])


def find_client(clients, external_id, msisdn):
    """Client id by registry identifier, falling back to the phone number."""
    for client in clients:
        if client.get("externalId") == external_id:
            return client.get("id")
    for client in clients:
        if msisdn and client.get("mobileNo") == msisdn:
            return client.get("id")
    return None


def registrant_external_id(farmer):
    """The identifier that ties a Fineract client back to the registry record."""
    return f"openspp-{farmer['partner_id']}"


def ensure_borrower(headers, clients, tenant, farmer):
    """The farmer as a client of the lending bank, with an account to receive the money.

    Looked up by registry identifier first and by phone second, so the borrower of the
    lending bank and the payee of the subsidy are the same person when they share a tenant.
    """
    external_id = registrant_external_id(farmer)
    client_id = find_client(clients, external_id, farmer["msisdn"])

    if not client_id:
        client_id, _mobile, _name = gen.create_client(headers, "en", tenant, farmer["msisdn"])
        if not client_id:
            return None, None

    gen.make_api_request("PUT", f"{gen.CLIENTS_API_URL}/{client_id}", headers,
                         json_data={"externalId": external_id})

    account_id = gen.get_savings_accounts_for_client(headers, client_id)
    if not account_id:
        product_id = gen.create_savings_product(headers, f"{tenant}-savings")
        account_id, _ext = gen.create_savings_account(headers, client_id, product_id, "en")
        if account_id:
            today = datetime.datetime.now().strftime(gen.DATE_FORMAT)
            gen.approve_savings_account(gen.API_BASE_URL, headers, account_id, today)
            gen.activate_savings_account(gen.API_BASE_URL, headers, account_id, today)
    return client_id, account_id


def existing_agri_loan(headers, client_id):
    """The agri loan this demo already opened for a client, and how far it got.

    A run cut short can leave it waiting for approval or waiting for the money, so both
    stages are reported and not just whether it was paid out.
    """
    accounts = gen.make_api_request("GET", f"{gen.CLIENTS_API_URL}/{client_id}/accounts", headers)
    for loan in (accounts or {}).get("loanAccounts", []):
        if loan.get("productName") == LOAN_PRODUCT_NAME:
            status = loan.get("status") or {}
            return {"id": loan.get("id"),
                    "approved": bool(status.get("active") or status.get("waitingForDisbursal")),
                    "disbursed": bool(status.get("active"))}
    return None


def approved_principal(headers, loan_id):
    """What the bank approved, which is what a resumed disbursement has to pay out."""
    loan = gen.make_api_request("GET", f"{gen.API_BASE_URL}/loans/{loan_id}", headers) or {}
    return loan.get("approvedPrincipal") or loan.get("principal")


def loan_status(headers, loan_id):
    """How Fineract describes the loan right now. Read only to explain a failure."""
    loan = gen.make_api_request("GET", f"{gen.API_BASE_URL}/loans/{loan_id}", headers) or {}
    return (loan.get("status") or {}).get("value", "in an unknown state")


def loan_application(request, date_format, today):
    """The loan application both rails send, differing only in how dates are written.

    The savings account is linked here and not at disbursement, which is where Fineract
    expects it and the only way the money can land in an account the farmer already has.
    """
    payload = {
        "clientId": request["client_id"],
        "productId": request["product_id"],
        "principal": request["principal"],
        "loanType": "individual",
        "loanTermFrequency": LOAN_TERM_MONTHS,
        "loanTermFrequencyType": 2,
        "numberOfRepayments": 1,
        "repaymentEvery": LOAN_TERM_MONTHS,
        "repaymentFrequencyType": 2,
        "interestRatePerPeriod": 0,
        "interestRateFrequencyType": 2,
        "amortizationType": 1,
        "interestType": 0,
        "interestCalculationPeriodType": 1,
        "transactionProcessingStrategyCode": TRANSACTION_STRATEGY,
        "expectedDisbursementDate": today,
        "submittedOnDate": today,
        "dateFormat": date_format,
        "locale": "en",
    }
    if request.get("purpose_id"):
        payload["loanPurposeId"] = request["purpose_id"]
    if request.get("account_id"):
        payload["linkAccountId"] = request["account_id"]
    return payload


def originate_direct(headers, request, collateral):
    """Submit, secure and approve the loan straight against Fineract. Returns the loan id.

    The collateral goes in before the approval because Fineract only takes it while the loan
    is still pending one.
    """
    today = datetime.date.today().strftime(gen.DATE_FORMAT)
    created = gen.make_api_request("POST", f"{gen.API_BASE_URL}/loans", headers,
                                   json_data=loan_application(request, FINERACT_DATE_FORMAT, today))
    if not created:
        return None
    loan_id = created.get("loanId") or created.get("resourceId")
    attach_collateral(headers, loan_id, collateral)
    return loan_id if approve_loan(headers, loan_id, request["principal"]) else None


def approve_loan(headers, loan_id, principal):
    """Approve the loan for what was asked. True when the bank took it."""
    today = datetime.date.today().strftime(gen.DATE_FORMAT)
    return bool(gen.make_api_request(
        "POST", f"{gen.API_BASE_URL}/loans/{loan_id}?command=approve", headers,
        json_data={"approvedOnDate": today, "approvedLoanAmount": principal,
                   "dateFormat": FINERACT_DATE_FORMAT, "locale": "en"}))


def workflow_session(base_url, username, password):
    """Authenticated session against the workflow engine, or None when it does not answer."""
    session = requests.Session()
    try:
        response = session.post(f"{base_url}/api/v1/auth/authenticate",
                                json={"username": username, "password": password},
                                timeout=HTTP_TIMEOUT)
        response.raise_for_status()
    except requests.RequestException as exc:
        print(f"  workflow engine not usable ({exc.__class__.__name__})", file=sys.stderr)
        return None
    return session


def complete_workflow_task(session, base_url, task, variables):
    """Answer one step of the process. False when the engine refused, saying why."""
    response = session.post(f"{base_url}/api/v1/workflow/loan-origination/tasks/{task['taskId']}/complete",
                            json=variables, timeout=HTTP_TIMEOUT)
    if response.status_code == 200:
        return True
    print(f"  the workflow engine refused '{task['name']}': HTTP {response.status_code} "
          f"{response.text[:400]}", file=sys.stderr)
    return False


def workflow_variables(session, base_url, process_id):
    """Variables of a running process, empty once it has finished and they are gone."""
    response = session.get(f"{base_url}/api/v1/workflow/loan-origination/processes/{process_id}/variables",
                           timeout=HTTP_TIMEOUT)
    return response.json() if response.status_code == 200 else {}


def workflow_task_answers(principal, decision, approval_date):
    """What each step of the BPMN process is answered with.

    Credit Assessment is where the registry decision enters the bank's own process. The
    approval date is written the way Fineract will be told to read it, because the engine
    forwards a date given as text without touching it.
    """
    return {
        "Submit Loan Application": {},
        "Review Loan Application": {"approved": True, "reviewNotes": "Registry record complete"},
        "Credit Assessment": {"creditScore": int(round(decision["score"])),
                              "riskLevel": decision["classification_label"],
                              "assessmentNotes": f"OpenSPP scorecard "
                                                 f"{decision['model_version'] or SCORECARD_CODE}"},
        "Loan Approval": {"approved": True, "approvedOnDate": approval_date,
                          "approvedAmount": principal,
                          "approvalNotes": "Approved on registry evidence"},
        "Notify Client - Approval": {"notificationMethod": "sms", "notificationSent": True},
    }


def workflow_application(request, today):
    """The loan application in the shape the workflow engine takes.

    Its own request carries fewer fields than Fineract needs, so the rest travel in
    additionalProperties, which the engine merges into the process variables its delegate
    reads. Sent this way the loan reaches Fineract complete.
    """
    return {
        "clientId": request["client_id"],
        "productId": request["product_id"],
        "principal": request["principal"],
        "loanType": "individual",
        "loanPurposeId": request.get("purpose_id"),
        "loanTermFrequency": LOAN_TERM_MONTHS,
        "loanTermFrequencyType": 2,
        "interestRatePerPeriod": 0,
        "interestRateFrequencyType": 2,
        "amortizationType": 1,
        "interestType": 0,
        "interestCalculationPeriodType": 1,
        # Required as a number, while the delegate that talks to Fineract reads it as the
        # strategy code. The number gets it past validation and the code below replaces it.
        "transactionProcessingStrategyId": 1,
        "loanDate": today,
        "submittedOnDate": today,
        # Dates travel in ISO because that is what its own request parses, but the engine
        # rewrites them as 'dd MMMM yyyy' before calling Fineract, so that is the format
        # Fineract has to be told about.
        "dateFormat": FINERACT_DATE_FORMAT,
        "locale": "en",
        "additionalProperties": {
            "interestType": 0,
            "numberOfRepayments": 1,
            "repaymentEvery": LOAN_TERM_MONTHS,
            "repaymentFrequencyType": 2,
            "expectedDisbursementDate": today,
            "transactionProcessingStrategyCode": TRANSACTION_STRATEGY,
        },
    }


def originate_via_workflow(session, base_url, headers, request, collateral, decision):
    """Drive the BPMN loan origination process to approval. Returns the loan id.

    The collateral is attached as soon as the process has created the loan, because by the
    time the process approves it Fineract no longer takes one.
    """
    today = datetime.date.today().isoformat()
    start = session.post(f"{base_url}/api/v1/workflow/loan-origination/start",
                         json=workflow_application(request, today), timeout=HTTP_TIMEOUT)
    if start.status_code != 200:
        print(f"  the workflow engine refused the application: HTTP {start.status_code} "
              f"{start.text[:200]}", file=sys.stderr)
        return None
    process_id = start.json().get("id")

    answers = workflow_task_answers(request["principal"], decision,
                                    datetime.date.today().strftime(gen.DATE_FORMAT))
    # The loan id is picked up while the process runs, because a finished process keeps no
    # variables to read afterwards.
    loan_id = None
    # One pass per step of the process, plus a margin, so a process that never finishes stops
    # the run instead of looping for ever.
    for _ in range(len(answers) + 2):
        response = session.get(
            f"{base_url}/api/v1/workflow/loan-origination/processes/{process_id}/tasks",
            timeout=HTTP_TIMEOUT)
        if response.status_code != 200:
            print(f"  the workflow engine did not list the tasks: HTTP {response.status_code}",
                  file=sys.stderr)
            break
        tasks = response.json()
        if not tasks:
            break
        task = tasks[0]
        if task["name"] not in answers:
            print(f"  unexpected task '{task['name']}', stopping there", file=sys.stderr)
            break
        if not complete_workflow_task(session, base_url, task, answers[task["name"]]):
            return None

        state = workflow_variables(session, base_url, process_id)
        if state.get("loanCreationSuccess") is False:
            print(f"  the process did not create the loan: {state.get('loanCreationError')}",
                  file=sys.stderr)
            return None
        if not loan_id and state.get("loanId"):
            loan_id = state["loanId"]
            attach_collateral(headers, loan_id, collateral)

    if not loan_id:
        print("  the process ended without reporting a loan", file=sys.stderr)
    return loan_id


def linked_savings(headers, loan_id):
    """The savings account the loan was linked to, if the link went through."""
    loan = gen.make_api_request("GET", f"{gen.API_BASE_URL}/loans/{loan_id}", headers,
                                params={"associations": "linkedAccount"})
    return ((loan or {}).get("linkedAccount") or {}).get("id")


def disburse(headers, loan_id, principal):
    """Pay the loan out, into its linked savings account when it has one.

    Which command applies is read from the loan rather than assumed, because the two rails
    do not link the account the same way.
    """
    today = datetime.date.today().strftime(gen.DATE_FORMAT)
    payload = {"actualDisbursementDate": today, "transactionAmount": principal,
               "dateFormat": FINERACT_DATE_FORMAT, "locale": "en"}
    command = "disburseToSavings" if linked_savings(headers, loan_id) else "disburse"
    return bool(gen.make_api_request("POST", f"{gen.API_BASE_URL}/loans/{loan_id}?command={command}",
                                     headers, json_data=payload))


def ensure_registry_table(headers):
    """Register the datatable that carries the registry evidence on the loan.

    True when the table is there afterwards. The reply body is not read, because Fineract
    answers a registration with the table name and an empty body would read as a failure.
    """
    tables = gen.make_api_request("GET", f"{gen.API_BASE_URL}/datatables", headers) or []
    if any(table.get("registeredTableName") == REGISTRY_TABLE for table in tables):
        return True
    payload = {
        "datatableName": REGISTRY_TABLE,
        "apptableName": "m_loan",
        "multiRow": False,
        "columns": [
            {"name": "registrant_id", "type": "String", "length": 64, "mandatory": False},
            {"name": "score", "type": "Decimal", "mandatory": False},
            {"name": "band", "type": "String", "length": 16, "mandatory": False},
            {"name": "scorecard_version", "type": "String", "length": 32, "mandatory": False},
            {"name": "hectares", "type": "Decimal", "mandatory": False},
            {"name": "crop", "type": "String", "length": 64, "mandatory": False},
            {"name": "consent_id", "type": "String", "length": 32, "mandatory": False},
        ],
    }
    created = gen.make_api_request("POST", f"{gen.API_BASE_URL}/datatables", headers,
                                   json_data=payload)
    return created is not None


def attach_registry_snapshot(headers, loan_id, farmer, decision, consent_id):
    """Hang the evidence behind the decision on the loan itself, once."""
    rows = gen.make_api_request("GET", f"{gen.API_BASE_URL}/datatables/{REGISTRY_TABLE}/{loan_id}",
                                headers)
    if rows:
        return
    payload = {
        "registrant_id": registrant_external_id(farmer),
        "score": decision["score"],
        "band": decision["classification_code"],
        "scorecard_version": decision["model_version"] or SCORECARD_CODE,
        "hectares": farmer["hectares"],
        "crop": farmer["crop"],
        "consent_id": str(consent_id) if consent_id else "",
        "locale": "en",
        "dateFormat": FINERACT_DATE_FORMAT,
    }
    gen.make_api_request("POST", f"{gen.API_BASE_URL}/datatables/{REGISTRY_TABLE}/{loan_id}",
                         headers, json_data=payload)


def farm_as_collateral(farmer, collateral_type_id):
    """The land parcel offered as security, or None when this Fineract has no such code."""
    if not collateral_type_id:
        return None
    return {"collateralTypeId": collateral_type_id,
            "value": round(farmer["hectares"] * PRINCIPAL_PER_HECTARE),
            "description": f"{farmer['hectares']} ha, {farmer['tenure']}",
            "locale": "en"}


def attach_collateral(headers, loan_id, collateral):
    """Secure the loan with the parcel, once. Fineract only takes it before approval."""
    if not collateral:
        return
    loan = gen.make_api_request("GET", f"{gen.API_BASE_URL}/loans/{loan_id}", headers,
                                params={"associations": "collateral"}) or {}
    if loan.get("collateral"):
        return
    gen.make_api_request("POST", f"{gen.API_BASE_URL}/loans/{loan_id}/collaterals", headers,
                         json_data=collateral)


def choose_origination(asked, base_url, username, password):
    """Pick the rail: the workflow engine when it answers, Fineract on its own otherwise."""
    if asked == "direct":
        print("Opening loans straight against Fineract (asked for)", file=sys.stderr)
        return "direct", None

    session = workflow_session(base_url, username, password)
    if session:
        print("Opening loans through the Mifos workflow engine", file=sys.stderr)
        return "workflow", session
    if asked == "workflow":
        sys.exit("ERROR: the workflow engine did not answer, so --origination workflow cannot be "
                 "honoured. Use --origination direct or auto.")
    print("WARN: the workflow engine did not answer, falling back to Fineract", file=sys.stderr)
    return "direct", None


def print_decisions(farmers, decisions):
    print("\n  farmer                     ha   yrs  tenure    score  band  principal", file=sys.stderr)
    for farmer in farmers:
        decision = decisions.get(farmer["partner_id"])
        if not decision:
            print(f"  {farmer['name'][:26]:<26} no score", file=sys.stderr)
            continue
        principal = loan_principal(farmer["hectares"], decision["classification_code"])
        print(f"  {farmer['name'][:26]:<26} {farmer['hectares']:>4.1f} {farmer['experience_years']:>4}  "
              f"{farmer['tenure'][:8]:<8} {decision['score']:>6.1f}  {decision['classification_code']:<4}  "
              f"{principal:>9}", file=sys.stderr)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Decide and open agri loans in MifosX from the OpenSPP farmer registry")
    parser.add_argument("--openspp-url", default="http://localhost:8069",
                        help="where OpenSPP answers, over plain HTTP. The demo opens a "
                             "port-forward and passes the URL it got.")
    parser.add_argument("--openspp-db", default="openspp")
    parser.add_argument("--openspp-user", default="admin")
    parser.add_argument("--openspp-password", default="admin")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--program-name", default="Agri subsidy Q3")
    parser.add_argument("--lender-tenant", default="",
                        help="Fineract tenant that lends. Defaults to greenbank for the workflow "
                             "rail, which is the tenant its engine is configured with, and to "
                             "bluebank for the direct rail, where the farmers already bank.")
    parser.add_argument("--currency", default="USD")
    parser.add_argument("--origination", choices=["auto", "workflow", "direct"], default="auto")
    parser.add_argument("--workflow-user", default="mifos")
    parser.add_argument("--workflow-password", default="password")
    parser.add_argument("--workflow-url", default="",
                        help="where the workflow engine answers. Defaults to its Gazelle "
                             "hostname; point it elsewhere when that name does not resolve, "
                             "for example at a port-forward.")
    parser.add_argument("--decide-only", action="store_true",
                        help="score and record consent, then stop before the bank")
    return parser.parse_args()


def main():
    args = parse_args()
    config = gen.load_config(str(args.config))
    domain = gen.get_gazelle_domain(config)
    gen.set_global_urls(domain)
    print(f"Domain: {domain}", file=sys.stderr)

    call, uid = openspp_call(args.openspp_url, args.openspp_db, args.openspp_user,
                             args.openspp_password)
    farmers = read_farmers(call, args.program_name)
    if not farmers:
        sys.exit(f"ERROR: no farmers enrolled in '{args.program_name}'")
    without_farm = [f["name"] for f in farmers if not f["hectares"]]
    if without_farm:
        sys.exit(f"ERROR: {len(without_farm)} farmer(s) have no farm recorded, so there is nothing "
                 f"to assess: {', '.join(without_farm)}. Run the data loader first.")

    model_id = ensure_scorecard(call, uid)
    decisions = score_farmers(call, model_id, farmers)
    print_decisions(farmers, decisions)

    lender_id = ensure_organisation(call, LENDER_NAME)
    controller_id = ensure_organisation(call, REGISTRY_AUTHORITY_NAME)
    consents = {farmer["partner_id"]: ensure_consent(call, farmer, lender_id, controller_id)
                for farmer in farmers}
    granted = sum(1 for consent in consents.values() if consent)
    print(f"\nConsent to share the verdict with the lender: {granted}/{len(farmers)}",
          file=sys.stderr)

    if args.decide_only:
        print(0, "none")
        return

    workflow_url = args.workflow_url or f"http://workflow.{domain}"
    rail, session = choose_origination(args.origination, workflow_url,
                                       args.workflow_user, args.workflow_password)
    tenant = args.lender_tenant or ("greenbank" if rail == "workflow" else "bluebank")
    headers = fineract_headers(tenant)
    print(f"Lender: {tenant}", file=sys.stderr)

    product_id = ensure_loan_product(headers, args.currency)
    purpose_id = ensure_code_value(headers, PURPOSE_CODE, LOAN_PURPOSE)
    collateral_type_id = ensure_code_value(headers, COLLATERAL_CODE, COLLATERAL_TYPE)
    if not ensure_registry_table(headers):
        sys.exit(f"ERROR: the datatable {REGISTRY_TABLE} could not be registered in {tenant}, so "
                 f"no loan could carry the evidence it was granted on")

    clients = read_clients(headers)
    opened = 0
    for farmer in farmers:
        decision = decisions.get(farmer["partner_id"])
        if not decision or not decision.get("is_complete"):
            print(f"  SKIP {farmer['name']}: no complete score", file=sys.stderr)
            continue
        if not consents[farmer["partner_id"]]:
            print(f"  SKIP {farmer['name']}: no consent on record", file=sys.stderr)
            continue
        if not farmer["msisdn"]:
            print(f"  SKIP {farmer['name']}: no phone number to identify the borrower",
                  file=sys.stderr)
            continue

        client_id, account_id = ensure_borrower(headers, clients, tenant, farmer)
        if not client_id:
            print(f"  ERROR {farmer['name']}: could not be registered as a borrower", file=sys.stderr)
            continue
        # A loan that already exists is never opened a second time: it is carried to the end,
        # from wherever a previous run left it.
        existing = existing_agri_loan(headers, client_id)
        if existing:
            loan_id = existing["id"]
            principal = approved_principal(headers, loan_id)
            if not existing["approved"]:
                print(f"  {farmer['name']}: loan {loan_id} was left unfinished, resuming",
                      file=sys.stderr)
                attach_collateral(headers, loan_id, farm_as_collateral(farmer, collateral_type_id))
                if not approve_loan(headers, loan_id, principal):
                    print(f"  ERROR {farmer['name']}: loan {loan_id} could not be approved",
                          file=sys.stderr)
                    continue
        else:
            principal = loan_principal(farmer["hectares"], decision["classification_code"])
            request = {"client_id": client_id, "product_id": product_id, "principal": principal,
                       "purpose_id": purpose_id, "account_id": account_id}
            collateral = farm_as_collateral(farmer, collateral_type_id)
            if rail == "workflow":
                loan_id = originate_via_workflow(session, workflow_url, headers, request,
                                                 collateral, decision)
            else:
                loan_id = originate_direct(headers, request, collateral)
            if not loan_id:
                print(f"  ERROR {farmer['name']}: the loan was not opened", file=sys.stderr)
                continue

        # Whichever way it got here, the loan leaves carrying what it was granted on.
        attach_registry_snapshot(headers, loan_id, farmer, decision,
                                 consents[farmer["partner_id"]])

        if existing and existing["disbursed"]:
            print(f"  OK {farmer['name']}: already has an agri loan, left alone", file=sys.stderr)
            continue

        if not disburse(headers, loan_id, principal):
            print(f"  ERROR {farmer['name']}: loan {loan_id} was not disbursed, it is "
                  f"{loan_status(headers, loan_id)}", file=sys.stderr)
            continue

        opened += 1
        print(f"  OK {farmer['name']}: {args.currency} {principal} disbursed on loan {loan_id} "
              f"(band {decision['classification_code']})", file=sys.stderr)

    print(f"\nOK: {opened}/{len(farmers)} agri loans opened and disbursed in {tenant}.",
          file=sys.stderr)
    # stdout: how many were opened and who lent, which is what the orchestrator verifies against.
    print(opened, tenant)


if __name__ == "__main__":
    main()
