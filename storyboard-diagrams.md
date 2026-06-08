# Mifos Gazelle — Mermaid Diagrams
> Domain: mifos.gazelle.test | Generated: 2026-05-10
> Components enabled: MifosX ✅ · Payment Hub EE ✅ · Mojaloop vNext ✅ · Mastercard ❌

---

## Diagram 1 — End-to-End Payment Flow (Sequence)

Single payment from a Greenbank customer to a Bluebank customer via the full stack.

```mermaid
sequenceDiagram
    autonumber
    actor Operator as Demo Operator
    participant Channel as Channel Connector<br/>channel.mifos.gazelle.test
    participant Zeebe as Zeebe Workflow Engine<br/>(PaymentTransferFlow BPMN)
    participant AMS as AMS-Mifos Connector<br/>ams-mifos.mifos.gazelle.test
    participant Fineract as Apache Fineract<br/>mifos.mifos.gazelle.test
    participant MojaConn as Mojaloop Connector<br/>mojaloop.mifos.gazelle.test
    participant FSPIOP as vNext FSPIOP API<br/>fspiop.mifos.gazelle.test
    participant ALO as Account Lookup Oracle<br/>(vNext built-in)
    participant Transfers as Transfers Svc<br/>(vNext)
    participant Settlements as Settlements Svc<br/>(vNext)

    Operator->>Channel: POST /channel/transfer<br/>Platform-TenantId: greenbank<br/>X-PayeeDFSP-ID: bluebank<br/>{ payer MSISDN, payee MSISDN, amount }

    Channel->>Zeebe: Start workflow instance<br/>PaymentTransferFlow

    Note over Zeebe: Phase 1 — Party Lookup
    Zeebe->>MojaConn: GET /parties/MSISDN/{payee-msisdn}
    MojaConn->>FSPIOP: GET /parties/MSISDN/{payee-msisdn}
    FSPIOP->>ALO: Resolve MSISDN → DFSP
    ALO-->>FSPIOP: payeeFsp = bluebank
    FSPIOP-->>MojaConn: Party resolved
    MojaConn-->>Zeebe: Payee confirmed at bluebank

    Note over Zeebe: Phase 2 — Quotation
    Zeebe->>MojaConn: POST /quotes
    MojaConn->>FSPIOP: POST /quotes
    FSPIOP-->>MojaConn: Quote accepted (fee + expiry)
    MojaConn-->>Zeebe: Quote OK

    Note over Zeebe: Phase 3 — Transfer Prepare
    Zeebe->>MojaConn: POST /transfers (prepare)
    MojaConn->>FSPIOP: POST /transfers
    FSPIOP->>Transfers: Reserve funds
    Transfers->>Settlements: Record obligation

    Note over Transfers: vNext notifies payee DFSP (bluebank)
    Transfers->>AMS: Credit payee account<br/>(bluebank tenant)
    AMS->>Fineract: POST /savingsaccounts/{id}/transactions<br/>transactionType: DEPOSIT
    Fineract-->>AMS: Transaction recorded ✅

    Transfers-->>FSPIOP: Transfer fulfilled
    FSPIOP-->>MojaConn: Fulfilment
    MojaConn-->>Zeebe: Transfer complete

    Note over Zeebe: Phase 4 — Debit Payer
    Zeebe->>AMS: Debit payer account<br/>(greenbank tenant)
    AMS->>Fineract: POST /savingsaccounts/{id}/transactions<br/>transactionType: WITHDRAWAL
    Fineract-->>AMS: Transaction recorded ✅

    AMS-->>Zeebe: Debit confirmed
    Zeebe-->>Channel: Workflow COMPLETED
    Channel-->>Operator: HTTP 200 OK ✅
```

---

## Diagram 2 — Infrastructure Data Flows (Flowchart)

Data stores and how each component depends on them.

```mermaid
flowchart TB
    subgraph infra["☁ Infrastructure Namespace (infra)"]
        direction TB
        MySQL[(MySQL 8\nPort 3306)]
        Kafka([Kafka + Zookeeper\nPort 9092])
        MongoDB[(MongoDB\nPort 27017)]
        Redis[(Redis\nPort 6379)]
        ES[(Elasticsearch\nPort 9200)]
        Minio2[(Minio S3\nPort 9000)]
    end

    subgraph mifosx["🏦 MifosX Namespace (mifosx)"]
        Fineract[Fineract Server\nCore Banking API]
        WebApp[Mifos Web App\nUI]
        Fineract --> WebApp
    end

    subgraph paymenthub["⚡ PaymentHub Namespace (paymenthub)"]
        direction LR
        Channel[Channel\nConnector]
        Zeebe[Zeebe Engine]
        ZeebeGW[Zeebe Gateway]
        ZeebeOps[Zeebe Ops]
        Operate[Zeebe Operate\nUI]
        AMS[AMS-Mifos\nConnector]
        MojaConn[Mojaloop\nConnector]
        BulkProc[Bulk\nProcessor]
        OpsApp[Operations\nApp]
        OpsWeb[Operations\nWeb UI]
        Notif[Notifications\nConnector]
        IAMapper[Identity Account\nMapper]
        Importer[RDBMS\nImporter]
        PHMinio[(Minio\nbatch files)]
        PHRedis[(Redis\ncache)]
        PHMySQL[(Operations\nMySQL)]
        PHKafka([Kafka\nbranch)]

        Channel --> Zeebe
        Zeebe --> AMS
        Zeebe --> MojaConn
        ZeebeGW --> Zeebe
        ZeebeOps --> Zeebe
        OpsApp --> Importer
        BulkProc --> PHMinio
        OpsWeb --> OpsApp
    end

    subgraph vnext["🔀 Mojaloop vNext Namespace (vnext)"]
        direction LR
        FSPIOP[FSPIOP API Svc]
        Transfers2[Transfers Svc]
        Quotes2[Quoting Svc]
        ALO2[Account Lookup\nOracle]
        Participants[Participants Svc]
        Sched[Scheduling Svc]
        Settlements2[Settlements Svc]
        Auditing[Auditing Svc]
        AdminUI2[Admin UI]
        Reporting[Reporting\nServices ×4]

        FSPIOP --> Transfers2
        FSPIOP --> Quotes2
        FSPIOP --> ALO2
        Transfers2 --> Settlements2
    end

    %% Infra → MifosX
    MySQL -- "greenbank / bluebank /\nredbank schemas" --> Fineract

    %% Infra → PaymentHub
    PHMySQL -- "operations DB" --> OpsApp
    PHMySQL --> Importer
    PHKafka -- "payment events" --> Zeebe
    PHKafka --> Notif
    PHRedis --> Channel
    ES -- "audit + logs" --> OpsApp

    %% Infra → vNext
    MongoDB -- "transfer state" --> Transfers2
    MongoDB -- "settlements" --> Settlements2
    MongoDB -- "participants" --> Participants
    Kafka -- "domain events" --> FSPIOP
    Kafka --> Auditing

    %% Cross-namespace
    AMS -- "Fineract REST API" --> Fineract
    MojaConn -- "FSPIOP/1.1" --> FSPIOP
    IAMapper -- "beneficiary lookup" --> ALO2
```

---

## Diagram 3 — Kubernetes Namespace Topology

Namespaces, pod counts, and ingress endpoints on `192.168.68.6`.

```mermaid
flowchart LR
    NGINX["NGINX Ingress\n192.168.68.6"]

    subgraph ns_mifosx["mifosx  (2 pods)"]
        P_fineract["fineract-server ✅"]
        P_webapp["web-app ✅"]
    end

    subgraph ns_ph["paymenthub  (18 pods)"]
        P_channel["ph-ee-connector-channel ✅"]
        P_zeebe["phee-zeebe ✅"]
        P_zbgw["phee-zeebe-gateway ✅"]
        P_operate["phee-operate ✅"]
        P_ams["ph-ee-connector-ams-mifos ✅"]
        P_moja["ph-ee-connector-mojaloop-java ✅"]
        P_bulk["ph-ee-bulk-processor ✅"]
        P_ops["ph-ee-operations-app ✅"]
        P_opsweb["ph-ee-operations-web ✅"]
        P_iamapper["ph-ee-identity-account-mapper ✅"]
        P_mock["ph-ee-connector-mock-payment-schema ✅"]
        P_more["+ 7 more ✅"]
    end

    subgraph ns_vnext["vnext  (22 pods)"]
        P_fspiop["fspiop-api-svc ✅"]
        P_transfers["transfers-*-svc ×3 ✅"]
        P_quotes["quoting-svc ✅"]
        P_alo["account-lookup-* ×2 ✅"]
        P_settlements["settlements-*-svc ×4 ✅"]
        P_adminui["admin-ui ✅"]
        P_vnmore["+ 10 more ✅"]
    end

    subgraph ns_infra["infra  (9 pods)"]
        P_mysql["mysql-0 ✅"]
        P_kafka["kafka-broker-0 ✅"]
        P_mongo["mongodb-0 ✅"]
        P_redis["redis-master-0 ✅"]
        P_es["elasticsearch-master-0 ✅"]
        P_kibana["kibana ✅"]
        P_minio["minio ✅"]
        P_me["mongo-express ✅"]
        P_rp["redpanda-console ✅"]
    end

    NGINX --> ns_mifosx
    NGINX --> ns_ph
    NGINX --> ns_vnext
    NGINX --> ns_infra
```

---

## Diagram 4 — Multi-Tenant Bank Model

How the three tenant banks are structured within a shared MifosX instance.

```mermaid
flowchart TD
    Fineract["Apache Fineract\n(fineract-server pod)"]

    subgraph MySQL_infra["MySQL — mysql.infra.svc.cluster.local:3306"]
        direction LR
        DefaultDB[("fineracttenants\n(routing DB)")]
        GreenDB[("greenbank\n(schema)")]
        BlueDB[("bluebank\n(schema)")]
        RedDB[("redbank\n(schema)")]
    end

    subgraph vNext_Oracle["vNext Account Lookup Oracle"]
        ALO_GB["MSISDN → greenbank\n(payer DFSP)"]
        ALO_BB["MSISDN → bluebank\n(payee DFSP)"]
        ALO_RB["MSISDN → redbank\n(DFSP)"]
    end

    subgraph IAM["Identity Account Mapper\nidentity-mapper.mifos.gazelle.test"]
        IAM_BB["bluebank beneficiaries\nregistered as payees"]
    end

    Fineract -- "Fineract-Platform-TenantId:\ngreenbank" --> GreenDB
    Fineract -- "Fineract-Platform-TenantId:\nbluebank" --> BlueDB
    Fineract -- "Fineract-Platform-TenantId:\nredbank" --> RedDB
    Fineract --> DefaultDB

    GreenDB -- "1 client\n(payer in demos)" --> ALO_GB
    BlueDB -- "2 clients\n(payee in demos)" --> ALO_BB
    RedDB -- "1 client" --> ALO_RB

    BlueDB --> IAM_BB
    IAM_BB --> ALO_BB
```

---

## Diagram 5 — Bulk Payment Flow

Batch payment path (CSV upload through Payment Hub EE).

```mermaid
sequenceDiagram
    autonumber
    actor Operator
    participant Minio as Minio S3<br/>minio-console.mifos.gazelle.test
    participant BulkProc as Bulk Processor<br/>bulk-processor.mifos.gazelle.test
    participant Channel as Channel Connector
    participant Zeebe as Zeebe Workflow Engine
    participant AMS as AMS-Mifos
    participant Fineract as Fineract (per tenant)

    Operator->>Minio: Upload batch CSV<br/>(payer,payee,amount rows)
    Minio-->>BulkProc: File available event (Kafka)
    BulkProc->>BulkProc: Parse CSV, validate rows
    loop For each payment row
        BulkProc->>Channel: POST /channel/transfer<br/>(one per row)
        Channel->>Zeebe: Start PaymentTransferFlow instance
        Zeebe->>AMS: Debit payer / Credit payee
        AMS->>Fineract: Transaction API calls
        Fineract-->>AMS: Confirmed
        AMS-->>Zeebe: Done
        Zeebe-->>Channel: COMPLETED
    end
    BulkProc->>Minio: Write result CSV (status per row)
    Operator->>Minio: Download result CSV
```

---

## Diagram 6 — Deployment Lifecycle (`run.sh`)

How a single command deploys the full stack.

```mermaid
flowchart TD
    RunSH["./run.sh -m deploy -a all"]

    subgraph CommandLine["commandline.sh\n(CLI + config parsing)"]
        ParseArgs["Parse flags\n(-m, -a, -u, -d, -t)"]
        LoadConfig["crudini --get config/config.ini\n→ export all variables"]
    end

    subgraph EnvSetup["environmentSetup.sh\n(prerequisites)"]
        OS["OS checks\n(RAM, disk, Ubuntu version)"]
        K8s["k3s install / Colima start\n(mac / local / remote)"]
        Hosts["/etc/hosts entries\n(*.mifos.gazelle.test → VM IP)"]
        Venv["Python venv setup\n(.venv/)"]
    end

    subgraph Deployer["deployer.sh\n(orchestration)"]
        Infra["deploy_infrastructure()\nHelm: NGINX + MySQL + Kafka\n+ MongoDB + Redis + ES"]
        MifosX2["deploy_mifosx_from_yaml()\nkubectl apply manifests\n+ DB restore"]
        PHEE2["deploy_ph()\nHelm: ph-ee-engine\n+ Zeebe + connectors"]
        VNext2["deploy_vnext()\nkubectl apply manifests\n(~22 services)"]
        Data["generate_mifosx_and_vnext_data()\nPython: clients, accounts,\nbeneficiaries, BPMN workflows"]
    end

    RunSH --> CommandLine
    CommandLine --> EnvSetup
    EnvSetup --> Deployer

    Infra --> MifosX2
    Infra --> PHEE2
    Infra --> VNext2
    MifosX2 --> Data
    PHEE2 --> Data
    VNext2 --> Data

    Data --> Done["🎉 Mifos Gazelle Ready\nhttps://mifos.mifos.gazelle.test"]
```
