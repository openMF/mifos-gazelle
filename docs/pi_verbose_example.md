## Example of verbose output on installing on Raspberry Pi

This verbose output was generated deploying v2.0.0 using the following command:
```bash
davidhiggins@gazelle1:~/mifos-gazelle$ sudo ./run.sh -u ¢USER -m deploy -a all -d true
```

Verbose Output:
```bash

 ██████   █████  ███████ ███████ ██      ██      ███████ 
██       ██   ██    ███  ██      ██      ██      ██      
██   ███ ███████   ███   █████   ██      ██      █████   
██    ██ ██   ██  ███    ██      ██      ██      ██      
 ██████  ██   ██ ███████ ███████ ███████ ███████ ███████ 

Mifos Gazelle — Digital Public Infrastructure as a Solution (DaaS) deployment tool.
Deploys MifosX, Payment Hub EE and Mojaloop vNext on Kubernetes.

INFO   Using config file: /home/davidhiggins/mifos-gazelle/config/config.ini
INFO   Attempting to load configuration from /home/davidhiggins/mifos-gazelle/config/config.ini using crudini.
INFO   CLI apps converted to space-separated: all
DEBUG  Apps array: all
DEBUG  Expanded 'all' to: infra vnext phee mifosx
DEBUG  Apps to process: infra vnext phee mifosx
DEBUG  Final app order: infra vnext phee mifosx
WARN   This deployment is recommended for demo, test and educational purposes only.

==> checking operating system is tested with mifos-gazelle
    Linux OS is Ubuntu and version 24
    Supported Ubuntu versions are: 22 24
    Operating system and versions checks            [ok]

==> Check & install operating system packagesDEBUG  Docker is already installed.

DEBUG  nc (netcat) is already installed.

DEBUG  jq is already installed

       [ok]
==> Checking and installing Kubernetes tools         kubectl is already installed. Skipping.
    kubectx is already installed. Skipping.
Error: kustomize installation failed.
    k9s is already installed. Skipping.
    kubens is already installed. Skipping.
    helm is already installed. Skipping.
   [ok]
==> user's .bashrc already configured for k8s       [skipping]

==> Check & install operating system packagesDEBUG  Docker is already installed.

DEBUG  nc (netcat) is already installed.

DEBUG  jq is already installed

       [ok]
==> Mifos-gazelle: update local hosts file          [ok]
==> install local k3s cluster v1.35 user [davidhiggins]    DEBUG  k3s kubeconfig copied to /home/davidhiggins/.kube/config
[ok]
==> Check and load Helm repositories                [ok]
==> Installing NGINX to local cluster               [ok]
==> local kubernetes v1.35 configured  for davidhiggins 

============================
Environment setup successful
============================
DEBUG  Apps to deploy: infra vnext phee mifosx (redeploy=true)
DEBUG  Checking for at least 2 pods, all Ready, in namespace infra
DEBUG  Namespace check exit code: 1, output: []
ERROR  Namespace infra does not exist or is inaccessible

==> Deploying infrastructure
DEBUG  Checking for at least 2 pods, all Ready, in namespace infra
DEBUG  Namespace check exit code: 1, output: []
ERROR  Namespace infra does not exist or is inaccessible
    Creating namespace infra 
[  ok  ]
    Updating FQDNs [  ok  ]
DEBUG  Ensuring helm dependencies for infra
    Helm chart (infra) NAME: infra
LAST DEPLOYED: Fri Mar 13 08:49:00 2026
NAMESPACE: infra
STATUS: deployed
REVISION: 1
DEBUG  Checking for at least 2 pods, all Ready, in namespace infra
DEBUG  Namespace check exit code: 0, output: [namespace/infra]
DEBUG  kubectl exit code: 0, pod list: [infra-elasticsearch-master-0     1/1   Running   0               9m56s   10.42.0.14   gazelle1   <none>   <none>
infra-kibana-5cf7df4578-wq5t2    1/1   Running   0               9m56s   10.42.0.10   gazelle1   <none>   <none>
kafka-broker-0                   1/1   Running   0               9m56s   10.42.0.20   gazelle1   <none>   <none>
mongo-express-78687485db-z6s7s   1/1   Running   2 (6m6s ago)    9m56s   10.42.0.9    gazelle1   <none>   <none>
mongodb-0                        1/1   Running   2 (4m28s ago)   9m56s   10.42.0.12   gazelle1   <none>   <none>
mysql-0                          1/1   Running   0               9m56s   10.42.0.18   gazelle1   <none>   <none>
redis-master-0                   1/1   Running   0               9m56s   10.42.0.13   gazelle1   <none>   <none>
rpconsole-fdd584cc-cd6bj         1/1   Running   6 (3m6s ago)    9m56s   10.42.0.11   gazelle1   <none>   <none>
zookeeper-0                      1/1   Running   0               9m56s   10.42.0.17   gazelle1   <none>   <none>], total pods: 9, ready pods: 9
DEBUG  is_app_running(infra): total_pods=9, ready_count=9, min_pods=2
DEBUG  Found 9 pods, all Ready, in namespace infra, meeting minimum of 2
[  ok  ]

==================================
 Infrastructure Deployed
==================================
DEBUG  Checking for at least 2 pods, all Ready, in namespace infra
DEBUG  Namespace check exit code: 0, output: [namespace/infra]
DEBUG  kubectl exit code: 0, pod list: [infra-elasticsearch-master-0     1/1   Running   0               9m57s   10.42.0.14   gazelle1   <none>   <none>
infra-kibana-5cf7df4578-wq5t2    1/1   Running   0               9m57s   10.42.0.10   gazelle1   <none>   <none>
kafka-broker-0                   1/1   Running   0               9m57s   10.42.0.20   gazelle1   <none>   <none>
mongo-express-78687485db-z6s7s   1/1   Running   2 (6m7s ago)    9m57s   10.42.0.9    gazelle1   <none>   <none>
mongodb-0                        1/1   Running   2 (4m29s ago)   9m57s   10.42.0.12   gazelle1   <none>   <none>
mysql-0                          1/1   Running   0               9m57s   10.42.0.18   gazelle1   <none>   <none>
redis-master-0                   1/1   Running   0               9m57s   10.42.0.13   gazelle1   <none>   <none>
rpconsole-fdd584cc-cd6bj         1/1   Running   6 (3m7s ago)    9m57s   10.42.0.11   gazelle1   <none>   <none>
zookeeper-0                      1/1   Running   0               9m57s   10.42.0.17   gazelle1   <none>   <none>], total pods: 9, ready pods: 9
DEBUG  is_app_running(infra): total_pods=9, ready_count=9, min_pods=2
DEBUG  Found 9 pods, all Ready, in namespace infra, meeting minimum of 2

==> Deploying Mojaloop vNext
DEBUG  Checking for at least 2 pods, all Ready, in namespace vnext
DEBUG  Namespace check exit code: 1, output: []
ERROR  Namespace vnext does not exist or is inaccessible
    Removing existing vNext resources [  ok  ]
    Creating namespace vnext 
[  ok  ]
    Updating service URLs in manifests [  ok  ]
    Updating FQDNs in manifests [  ok  ]
    Restoring vNext MongoDB demo data [  ok  ]
    Applying layer 1 manifests [  ok  ]
DEBUG  Cross-cutting concerns layer applied — proceeding
    Applying layer 2 manifests [  ok  ]
    Applying layer 3 manifests [  ok  ]

==================================
 vNext Deployed
==================================
DEBUG  Checking for at least 2 pods, all Ready, in namespace infra
DEBUG  Namespace check exit code: 0, output: [namespace/infra]
DEBUG  kubectl exit code: 0, pod list: [infra-elasticsearch-master-0     1/1   Running   0               10m   10.42.0.14   gazelle1   <none>   <none>
infra-kibana-5cf7df4578-wq5t2    1/1   Running   0               10m   10.42.0.10   gazelle1   <none>   <none>
kafka-broker-0                   1/1   Running   0               10m   10.42.0.20   gazelle1   <none>   <none>
mongo-express-78687485db-z6s7s   1/1   Running   2 (6m37s ago)   10m   10.42.0.9    gazelle1   <none>   <none>
mongodb-0                        1/1   Running   2 (4m59s ago)   10m   10.42.0.12   gazelle1   <none>   <none>
mysql-0                          1/1   Running   0               10m   10.42.0.18   gazelle1   <none>   <none>
redis-master-0                   1/1   Running   0               10m   10.42.0.13   gazelle1   <none>   <none>
rpconsole-fdd584cc-cd6bj         1/1   Running   6 (3m37s ago)   10m   10.42.0.11   gazelle1   <none>   <none>
zookeeper-0                      1/1   Running   0               10m   10.42.0.17   gazelle1   <none>   <none>], total pods: 9, ready pods: 9
DEBUG  is_app_running(infra): total_pods=9, ready_count=9, min_pods=2
DEBUG  Found 9 pods, all Ready, in namespace infra, meeting minimum of 2

==> Deploying Payment Hub EE
DEBUG  Checking for at least 2 pods, all Ready, in namespace paymenthub
DEBUG  Namespace check exit code: 1, output: []
ERROR  Namespace paymenthub does not exist or is inaccessible
    Removing existing Payment Hub resources [  ok  ]
    Creating namespace paymenthub 
[  ok  ]
DEBUG  Cloned https://github.com/openMF/ph-ee-env-template.git → /home/davidhiggins/mifos-gazelle/repos/ph_template
    Updating FQDNs in Helm chart values and manifests [  ok  ]
DEBUG  Ensuring helm dependencies for ph-ee-engine
DEBUG  Ensuring helm dependencies for gazelle
    Creating elastic secrets [  ok  ]
    Creating TLS secret 'sandbox-secret' (bulk-processor.mifos.gazelle.test, 8 SANs) DEBUG  SANs:
DNS.1 = bulk-processor.mifos.gazelle.test
DNS.2 = ops.mifos.gazelle.test
DNS.3 = ops-bk.mifos.gazelle.test
DNS.4 = api.mifos.gazelle.test
DNS.5 = *.mifos.gazelle.test
DNS.6 = localhost
DNS.7 = ph-ee-connector-channel
DNS.8 = ph-ee-connector-channel.paymenthub.svc.cluster.local
[  ok  ]
    Helm install (phee) DEBUG  → helm install phee /home/davidhiggins/mifos-gazelle/repos/ph_template/helm/gazelle -n paymenthub --wait --timeout 1200s -f /home/davidhiggins/mifos-gazelle/config/ph_values.yaml
coalesce.go:286: warning: cannot overwrite table with non table for ph-ee-gazelle.ph-ee-engine.operations_web.deployment.config (map[])
coalesce.go:286: warning: cannot overwrite table with non table for ph-ee-engine.operations_web.deployment.config (map[])
coalesce.go:286: warning: cannot overwrite table with non table for ph-ee-engine.operations_web.deployment.config (map[])
coalesce.go:286: warning: cannot overwrite table with non table for ph-ee-gazelle.ph-ee-engine.operations_web.deployment.config (map[])
coalesce.go:286: warning: cannot overwrite table with non table for ph-ee-gazelle.ph-ee-engine.operations_web.deployment.config (map[])
W0313 09:12:22.375803 2580071 warnings.go:70] spec.template.spec.containers[0].env[12]: hides previous definition of "JAVA_TOOL_OPTIONS", which may be dropped when using apply
W0313 09:12:22.399022 2580071 warnings.go:70] spec.template.spec.containers[0].env[14]: hides previous definition of "JAVA_TOOL_OPTIONS", which may be dropped when using apply
NAME: phee
LAST DEPLOYED: Fri Mar 13 09:12:14 2026
NAMESPACE: paymenthub
STATUS: deployed
REVISION: 1
[  ok  ]
DEBUG  BPMNs to deploy: 19
DEBUG  Unique BPMNs already deployed: 0
    Deploying BPMN diagrams DEBUG  Uploading PayeePartyLookup-DFSPID.bpmn
DEBUG  Uploading PayeeQuoteTransfer-DFSPID.bpmn
DEBUG  Uploading PayerFundTransfer-DFSPID.bpmn
DEBUG  Uploading bulk_connector_closedloop-DFSPID.bpmn
DEBUG  Uploading bulk_processor-DFSPID.bpmn
DEBUG  Uploading bulk_processor_account_lookup-DFSPID.bpmn
DEBUG  Uploading gsma-p2p-account-lookup.bpmn
DEBUG  Uploading gsma-p2p-wo-local-quote.bpmn
DEBUG  Uploading gsma-p2p.bpmn
DEBUG  Uploading gsma-payee-process.bpmn
DEBUG  Uploading gsma-payee-transfer.bpmn
DEBUG  Uploading gsma_base_transaction-DFSPID.bpmn
DEBUG  Uploading inbound_transfer-mifos-DFSPID.bpmn
DEBUG  Uploading minimal_mock_fund_transfer-DFSPID.bpmn
DEBUG  Uploading minimal_mock_fund_transfer_account_lookup-DFSPID.bpmn
DEBUG  Uploading minimal_mock_transfer_request-DFSPID.bpmn
DEBUG  Uploading mojaloop-account-validation.bpmn
DEBUG  Uploading payer-fund-transfer-DFSPID.bpmn
DEBUG  Uploading payment-notification-DFSPID.bpmn
WARN   Some BPMN diagrams may not have deployed. Run: ./src/utils/deployBpmn-gazelle.sh

==================================
 Payment Hub EE Deployed
==================================
DEBUG  Checking for at least 2 pods, all Ready, in namespace infra
DEBUG  Namespace check exit code: 0, output: [namespace/infra]
DEBUG  kubectl exit code: 0, pod list: [infra-elasticsearch-master-0     1/1   Running   0               42m   10.42.0.14   gazelle1   <none>   <none>
infra-kibana-5cf7df4578-wq5t2    1/1   Running   0               42m   10.42.0.10   gazelle1   <none>   <none>
kafka-broker-0                   1/1   Running   0               42m   10.42.0.20   gazelle1   <none>   <none>
mongo-express-78687485db-z6s7s   1/1   Running   2 (38m ago)     42m   10.42.0.9    gazelle1   <none>   <none>
mongodb-0                        1/1   Running   5               42m   10.42.0.12   gazelle1   <none>   <none>
mysql-0                          1/1   Running   2 (7m17s ago)   42m   10.42.0.18   gazelle1   <none>   <none>
redis-master-0                   1/1   Running   0               42m   10.42.0.13   gazelle1   <none>   <none>
rpconsole-fdd584cc-cd6bj         1/1   Running   6 (35m ago)     42m   10.42.0.11   gazelle1   <none>   <none>
zookeeper-0                      1/1   Running   0               42m   10.42.0.17   gazelle1   <none>   <none>], total pods: 9, ready pods: 9
DEBUG  is_app_running(infra): total_pods=9, ready_count=9, min_pods=2
DEBUG  Found 9 pods, all Ready, in namespace infra, meeting minimum of 2

==> Deploying MifosX
DEBUG  Checking for at least 2 pods, all Ready, in namespace mifosx
DEBUG  Namespace check exit code: 1, output: []
ERROR  Namespace mifosx does not exist or is inaccessible
    Removing existing MifosX resources [  ok  ]
    Creating namespace mifosx 
[  ok  ]
DEBUG  Cloned https://github.com/openMF/mifosx-docker.git → /home/davidhiggins/mifos-gazelle/repos/mifosx
    Updating FQDNs in manifests [  ok  ]
    Restoring MifosX database dump [  ok  ]
    Applying manifests [  ok  ]

==================================
 MifosX Deployed
==================================
DEBUG  Checking for at least 2 pods, all Ready, in namespace vnext
DEBUG  Namespace check exit code: 0, output: [namespace/vnext]
DEBUG  kubectl exit code: 0, pod list: [account-lookup-http-oracle-svc-cb75f54f5-l8mhh                   1/1   Running   0             36m   10.42.0.30   gazelle1   <none>   <none>
account-lookup-svc-5bd46f7bfd-rg6jw                              1/1   Running   1 (32m ago)   36m   10.42.0.31   gazelle1   <none>   <none>
accounts-and-balances-builtin-ledger-grpc-svc-64b757d969-rzvx9   1/1   Running   2             35m   10.42.0.32   gazelle1   <none>   <none>
accounts-and-balances-coa-grpc-svc-64b974897-z84mk               1/1   Running   2 (27m ago)   35m   10.42.0.33   gazelle1   <none>   <none>
admin-ui-57f79c9774-fb6tv                                        1/1   Running   0             35m   10.42.0.34   gazelle1   <none>   <none>
auditing-svc-6479b799c6-tt6hb                                    1/1   Running   0             36m   10.42.0.22   gazelle1   <none>   <none>
authentication-svc-75744965f6-b68w8                              1/1   Running   0             36m   10.42.0.23   gazelle1   <none>   <none>
authorization-svc-984c7b95-66nzk                                 1/1   Running   0             36m   10.42.0.24   gazelle1   <none>   <none>
fspiop-api-svc-7c885b88cc-kxzzm                                  1/1   Running   0             35m   10.42.0.50   gazelle1   <none>   <none>
identity-svc-8665d57d6-4t245                                     1/1   Running   1 (32m ago)   36m   10.42.0.25   gazelle1   <none>   <none>
logging-svc-74dff9bcf6-crgxs                                     1/1   Running   0             36m   10.42.0.26   gazelle1   <none>   <none>
participants-reporting-svc-6dbc8dbbbb-bhzm7                      1/1   Running   0             35m   10.42.0.44   gazelle1   <none>   <none>
participants-svc-5c457bd6f-ctj47                                 1/1   Running   1 (23m ago)   35m   10.42.0.36   gazelle1   <none>   <none>
platform-configuration-svc-6767f5fdc9-sq45j                      1/1   Running   0             36m   10.42.0.46   gazelle1   <none>   <none>
quotes-reporting-svc-986b8b96c-p4wdp                             1/1   Running   2 (23m ago)   35m   10.42.0.45   gazelle1   <none>   <none>
quoting-svc-6667f8587b-hgfdz                                     1/1   Running   0             35m   10.42.0.38   gazelle1   <none>   <none>
reporting-api-svc-66c4f544d4-t8p7c                               1/1   Running   0             35m   10.42.0.47   gazelle1   <none>   <none>
scheduling-api-svc-57ff5686ff-grjsl                              1/1   Running   0             36m   10.42.0.28   gazelle1   <none>   <none>
scheduling-command-handler-svc-c4cbdd697-f24cl                   1/1   Running   0             36m   10.42.0.29   gazelle1   <none>   <none>
settlements-api-svc-74b86c8d76-h9t4h                             1/1   Running   0             35m   10.42.0.39   gazelle1   <none>   <none>
settlements-command-handler-svc-678fffb9d6-vxtlg                 1/1   Running   2 (23m ago)   35m   10.42.0.37   gazelle1   <none>   <none>
settlements-event-handler-svc-7c57cff98b-xsrxm                   1/1   Running   0             35m   10.42.0.40   gazelle1   <none>   <none>
settlements-reporting-svc-6c756f57d4-pnpfv                       1/1   Running   0             35m   10.42.0.48   gazelle1   <none>   <none>
transfers-api-svc-78cf5cc99c-s7982                               1/1   Running   0             35m   10.42.0.41   gazelle1   <none>   <none>
transfers-command-handler-svc-5956cf4c97-d7tn7                   1/1   Running   2 (22m ago)   35m   10.42.0.42   gazelle1   <none>   <none>
transfers-event-handler-svc-5f8d7f7dfd-hmpdn                     1/1   Running   0             35m   10.42.0.43   gazelle1   <none>   <none>
transfers-reporting-svc-746cd7c9c-7q2m8                          1/1   Running   0             35m   10.42.0.49   gazelle1   <none>   <none>], total pods: 27, ready pods: 27
DEBUG  is_app_running(vnext): total_pods=27, ready_count=27, min_pods=2
DEBUG  Found 27 pods, all Ready, in namespace vnext, meeting minimum of 2
DEBUG  Checking for at least 2 pods, all Ready, in namespace mifosx
DEBUG  Namespace check exit code: 0, output: [namespace/mifosx]
DEBUG  kubectl exit code: 0, pod list: [fineract-server-8cc57dc88-5z2ck   0/1   Pending             0     5s    <none>   <none>     gazelle1   <none>
web-app-59df76f6d6-688wf          0/1   ContainerCreating   0     4s    <none>   gazelle1   <none>     <none>], total pods: 2, ready pods: 0
DEBUG  is_app_running(mifosx): total_pods=2, ready_count=0, min_pods=2
DEBUG  Check failed: 2 pods, 0 Ready, in namespace mifosx (requires at least 2 pods, all Ready)
DEBUG  vNext or MifosX not running — retrying in 30s (2s/600s)
DEBUG  Checking for at least 2 pods, all Ready, in namespace vnext
DEBUG  Namespace check exit code: 0, output: [namespace/vnext]
DEBUG  kubectl exit code: 0, pod list: [account-lookup-http-oracle-svc-cb75f54f5-l8mhh                   1/1   Running   0             36m   10.42.0.30   gazelle1   <none>   <none>
account-lookup-svc-5bd46f7bfd-rg6jw                              1/1   Running   1 (32m ago)   36m   10.42.0.31   gazelle1   <none>   <none>
accounts-and-balances-builtin-ledger-grpc-svc-64b757d969-rzvx9   1/1   Running   2             36m   10.42.0.32   gazelle1   <none>   <none>
accounts-and-balances-coa-grpc-svc-64b974897-z84mk               1/1   Running   2 (28m ago)   36m   10.42.0.33   gazelle1   <none>   <none>
admin-ui-57f79c9774-fb6tv                                        1/1   Running   0             36m   10.42.0.34   gazelle1   <none>   <none>
auditing-svc-6479b799c6-tt6hb                                    1/1   Running   0             36m   10.42.0.22   gazelle1   <none>   <none>
authentication-svc-75744965f6-b68w8                              1/1   Running   0             36m   10.42.0.23   gazelle1   <none>   <none>
authorization-svc-984c7b95-66nzk                                 1/1   Running   0             36m   10.42.0.24   gazelle1   <none>   <none>
fspiop-api-svc-7c885b88cc-kxzzm                                  1/1   Running   0             36m   10.42.0.50   gazelle1   <none>   <none>
identity-svc-8665d57d6-4t245                                     1/1   Running   1 (33m ago)   36m   10.42.0.25   gazelle1   <none>   <none>
logging-svc-74dff9bcf6-crgxs                                     1/1   Running   0             36m   10.42.0.26   gazelle1   <none>   <none>
participants-reporting-svc-6dbc8dbbbb-bhzm7                      1/1   Running   0             36m   10.42.0.44   gazelle1   <none>   <none>
participants-svc-5c457bd6f-ctj47                                 1/1   Running   1 (24m ago)   36m   10.42.0.36   gazelle1   <none>   <none>
platform-configuration-svc-6767f5fdc9-sq45j                      1/1   Running   0             36m   10.42.0.46   gazelle1   <none>   <none>
quotes-reporting-svc-986b8b96c-p4wdp                             1/1   Running   2 (23m ago)   36m   10.42.0.45   gazelle1   <none>   <none>
quoting-svc-6667f8587b-hgfdz                                     1/1   Running   0             36m   10.42.0.38   gazelle1   <none>   <none>
reporting-api-svc-66c4f544d4-t8p7c                               1/1   Running   0             36m   10.42.0.47   gazelle1   <none>   <none>
scheduling-api-svc-57ff5686ff-grjsl                              1/1   Running   0             36m   10.42.0.28   gazelle1   <none>   <none>
scheduling-command-handler-svc-c4cbdd697-f24cl                   1/1   Running   0             36m   10.42.0.29   gazelle1   <none>   <none>
settlements-api-svc-74b86c8d76-h9t4h                             1/1   Running   0             36m   10.42.0.39   gazelle1   <none>   <none>
settlements-command-handler-svc-678fffb9d6-vxtlg                 1/1   Running   2 (23m ago)   36m   10.42.0.37   gazelle1   <none>   <none>
settlements-event-handler-svc-7c57cff98b-xsrxm                   1/1   Running   0             36m   10.42.0.40   gazelle1   <none>   <none>
settlements-reporting-svc-6c756f57d4-pnpfv                       1/1   Running   0             36m   10.42.0.48   gazelle1   <none>   <none>
transfers-api-svc-78cf5cc99c-s7982                               1/1   Running   0             36m   10.42.0.41   gazelle1   <none>   <none>
transfers-command-handler-svc-5956cf4c97-d7tn7                   1/1   Running   2 (23m ago)   36m   10.42.0.42   gazelle1   <none>   <none>
transfers-event-handler-svc-5f8d7f7dfd-hmpdn                     1/1   Running   0             36m   10.42.0.43   gazelle1   <none>   <none>
transfers-reporting-svc-746cd7c9c-7q2m8                          1/1   Running   0             36m   10.42.0.49   gazelle1   <none>   <none>], total pods: 27, ready pods: 27
DEBUG  is_app_running(vnext): total_pods=27, ready_count=27, min_pods=2
DEBUG  Found 27 pods, all Ready, in namespace vnext, meeting minimum of 2
DEBUG  Checking for at least 2 pods, all Ready, in namespace mifosx
DEBUG  Namespace check exit code: 0, output: [namespace/mifosx]
DEBUG  kubectl exit code: 0, pod list: [fineract-server-8cc57dc88-5z2ck   0/1   ContainerCreating   0     36s   <none>       gazelle1   <none>   <none>
web-app-59df76f6d6-688wf          1/1   Running             0     35s   10.42.0.81   gazelle1   <none>   <none>], total pods: 2, ready pods: 1
DEBUG  is_app_running(mifosx): total_pods=2, ready_count=1, min_pods=2
DEBUG  Check failed: 2 pods, 1 Ready, in namespace mifosx (requires at least 2 pods, all Ready)
DEBUG  vNext or MifosX not running — retrying in 30s (33s/600s)
DEBUG  Checking for at least 2 pods, all Ready, in namespace vnext
DEBUG  Namespace check exit code: 0, output: [namespace/vnext]
DEBUG  kubectl exit code: 0, pod list: [account-lookup-http-oracle-svc-cb75f54f5-l8mhh                   1/1   Running   0             37m   10.42.0.30   gazelle1   <none>   <none>
account-lookup-svc-5bd46f7bfd-rg6jw                              1/1   Running   1 (33m ago)   37m   10.42.0.31   gazelle1   <none>   <none>
accounts-and-balances-builtin-ledger-grpc-svc-64b757d969-rzvx9   1/1   Running   2             37m   10.42.0.32   gazelle1   <none>   <none>
accounts-and-balances-coa-grpc-svc-64b974897-z84mk               1/1   Running   2 (28m ago)   37m   10.42.0.33   gazelle1   <none>   <none>
admin-ui-57f79c9774-fb6tv                                        1/1   Running   0             37m   10.42.0.34   gazelle1   <none>   <none>
auditing-svc-6479b799c6-tt6hb                                    1/1   Running   0             37m   10.42.0.22   gazelle1   <none>   <none>
authentication-svc-75744965f6-b68w8                              1/1   Running   0             37m   10.42.0.23   gazelle1   <none>   <none>
authorization-svc-984c7b95-66nzk                                 1/1   Running   0             37m   10.42.0.24   gazelle1   <none>   <none>
fspiop-api-svc-7c885b88cc-kxzzm                                  1/1   Running   0             36m   10.42.0.50   gazelle1   <none>   <none>
identity-svc-8665d57d6-4t245                                     1/1   Running   1 (33m ago)   37m   10.42.0.25   gazelle1   <none>   <none>
logging-svc-74dff9bcf6-crgxs                                     1/1   Running   0             37m   10.42.0.26   gazelle1   <none>   <none>
participants-reporting-svc-6dbc8dbbbb-bhzm7                      1/1   Running   0             36m   10.42.0.44   gazelle1   <none>   <none>
participants-svc-5c457bd6f-ctj47                                 1/1   Running   1 (24m ago)   36m   10.42.0.36   gazelle1   <none>   <none>
platform-configuration-svc-6767f5fdc9-sq45j                      1/1   Running   0             37m   10.42.0.46   gazelle1   <none>   <none>
quotes-reporting-svc-986b8b96c-p4wdp                             1/1   Running   2 (24m ago)   36m   10.42.0.45   gazelle1   <none>   <none>
quoting-svc-6667f8587b-hgfdz                                     1/1   Running   0             36m   10.42.0.38   gazelle1   <none>   <none>
reporting-api-svc-66c4f544d4-t8p7c                               1/1   Running   0             36m   10.42.0.47   gazelle1   <none>   <none>
scheduling-api-svc-57ff5686ff-grjsl                              1/1   Running   0             37m   10.42.0.28   gazelle1   <none>   <none>
scheduling-command-handler-svc-c4cbdd697-f24cl                   1/1   Running   0             37m   10.42.0.29   gazelle1   <none>   <none>
settlements-api-svc-74b86c8d76-h9t4h                             1/1   Running   0             36m   10.42.0.39   gazelle1   <none>   <none>
settlements-command-handler-svc-678fffb9d6-vxtlg                 1/1   Running   2 (24m ago)   36m   10.42.0.37   gazelle1   <none>   <none>
settlements-event-handler-svc-7c57cff98b-xsrxm                   1/1   Running   0             36m   10.42.0.40   gazelle1   <none>   <none>
settlements-reporting-svc-6c756f57d4-pnpfv                       1/1   Running   0             36m   10.42.0.48   gazelle1   <none>   <none>
transfers-api-svc-78cf5cc99c-s7982                               1/1   Running   0             36m   10.42.0.41   gazelle1   <none>   <none>
transfers-command-handler-svc-5956cf4c97-d7tn7                   1/1   Running   2 (24m ago)   36m   10.42.0.42   gazelle1   <none>   <none>
transfers-event-handler-svc-5f8d7f7dfd-hmpdn                     1/1   Running   0             36m   10.42.0.43   gazelle1   <none>   <none>
transfers-reporting-svc-746cd7c9c-7q2m8                          1/1   Running   0             36m   10.42.0.49   gazelle1   <none>   <none>], total pods: 27, ready pods: 27
DEBUG  is_app_running(vnext): total_pods=27, ready_count=27, min_pods=2
DEBUG  Found 27 pods, all Ready, in namespace vnext, meeting minimum of 2
DEBUG  Checking for at least 2 pods, all Ready, in namespace mifosx
DEBUG  Namespace check exit code: 0, output: [namespace/mifosx]
DEBUG  kubectl exit code: 0, pod list: [fineract-server-8cc57dc88-5z2ck   0/1   ContainerCreating   0     68s   <none>       gazelle1   <none>   <none>
web-app-59df76f6d6-688wf          1/1   Running             0     67s   10.42.0.81   gazelle1   <none>   <none>], total pods: 2, ready pods: 1
DEBUG  is_app_running(mifosx): total_pods=2, ready_count=1, min_pods=2
DEBUG  Check failed: 2 pods, 1 Ready, in namespace mifosx (requires at least 2 pods, all Ready)
DEBUG  vNext or MifosX not running — retrying in 30s (65s/600s)
DEBUG  Checking for at least 2 pods, all Ready, in namespace vnext
DEBUG  Namespace check exit code: 0, output: [namespace/vnext]
DEBUG  kubectl exit code: 0, pod list: [account-lookup-http-oracle-svc-cb75f54f5-l8mhh                   1/1   Running   0             37m   10.42.0.30   gazelle1   <none>   <none>
account-lookup-svc-5bd46f7bfd-rg6jw                              1/1   Running   1 (33m ago)   37m   10.42.0.31   gazelle1   <none>   <none>
accounts-and-balances-builtin-ledger-grpc-svc-64b757d969-rzvx9   1/1   Running   2             37m   10.42.0.32   gazelle1   <none>   <none>
accounts-and-balances-coa-grpc-svc-64b974897-z84mk               1/1   Running   2 (29m ago)   37m   10.42.0.33   gazelle1   <none>   <none>
admin-ui-57f79c9774-fb6tv                                        1/1   Running   0             37m   10.42.0.34   gazelle1   <none>   <none>
auditing-svc-6479b799c6-tt6hb                                    1/1   Running   0             37m   10.42.0.22   gazelle1   <none>   <none>
authentication-svc-75744965f6-b68w8                              1/1   Running   0             37m   10.42.0.23   gazelle1   <none>   <none>
authorization-svc-984c7b95-66nzk                                 1/1   Running   0             37m   10.42.0.24   gazelle1   <none>   <none>
fspiop-api-svc-7c885b88cc-kxzzm                                  1/1   Running   0             37m   10.42.0.50   gazelle1   <none>   <none>
identity-svc-8665d57d6-4t245                                     1/1   Running   1 (34m ago)   37m   10.42.0.25   gazelle1   <none>   <none>
logging-svc-74dff9bcf6-crgxs                                     1/1   Running   0             37m   10.42.0.26   gazelle1   <none>   <none>
participants-reporting-svc-6dbc8dbbbb-bhzm7                      1/1   Running   0             37m   10.42.0.44   gazelle1   <none>   <none>
participants-svc-5c457bd6f-ctj47                                 1/1   Running   1 (25m ago)   37m   10.42.0.36   gazelle1   <none>   <none>
platform-configuration-svc-6767f5fdc9-sq45j                      1/1   Running   0             37m   10.42.0.46   gazelle1   <none>   <none>
quotes-reporting-svc-986b8b96c-p4wdp                             1/1   Running   2 (24m ago)   37m   10.42.0.45   gazelle1   <none>   <none>
quoting-svc-6667f8587b-hgfdz                                     1/1   Running   0             37m   10.42.0.38   gazelle1   <none>   <none>
reporting-api-svc-66c4f544d4-t8p7c                               1/1   Running   0             37m   10.42.0.47   gazelle1   <none>   <none>
scheduling-api-svc-57ff5686ff-grjsl                              1/1   Running   0             37m   10.42.0.28   gazelle1   <none>   <none>
scheduling-command-handler-svc-c4cbdd697-f24cl                   1/1   Running   0             37m   10.42.0.29   gazelle1   <none>   <none>
settlements-api-svc-74b86c8d76-h9t4h                             1/1   Running   0             37m   10.42.0.39   gazelle1   <none>   <none>
settlements-command-handler-svc-678fffb9d6-vxtlg                 1/1   Running   2 (24m ago)   37m   10.42.0.37   gazelle1   <none>   <none>
settlements-event-handler-svc-7c57cff98b-xsrxm                   1/1   Running   0             37m   10.42.0.40   gazelle1   <none>   <none>
settlements-reporting-svc-6c756f57d4-pnpfv                       1/1   Running   0             37m   10.42.0.48   gazelle1   <none>   <none>
transfers-api-svc-78cf5cc99c-s7982                               1/1   Running   0             37m   10.42.0.41   gazelle1   <none>   <none>
transfers-command-handler-svc-5956cf4c97-d7tn7                   1/1   Running   2 (24m ago)   37m   10.42.0.42   gazelle1   <none>   <none>
transfers-event-handler-svc-5f8d7f7dfd-hmpdn                     1/1   Running   0             37m   10.42.0.43   gazelle1   <none>   <none>
transfers-reporting-svc-746cd7c9c-7q2m8                          1/1   Running   0             37m   10.42.0.49   gazelle1   <none>   <none>], total pods: 27, ready pods: 27
DEBUG  is_app_running(vnext): total_pods=27, ready_count=27, min_pods=2
DEBUG  Found 27 pods, all Ready, in namespace vnext, meeting minimum of 2
DEBUG  Checking for at least 2 pods, all Ready, in namespace mifosx
DEBUG  Namespace check exit code: 0, output: [namespace/mifosx]
DEBUG  kubectl exit code: 0, pod list: [fineract-server-8cc57dc88-5z2ck   0/1   Running   0     100s   10.42.0.82   gazelle1   <none>   <none>
web-app-59df76f6d6-688wf          1/1   Running   0     99s    10.42.0.81   gazelle1   <none>   <none>], total pods: 2, ready pods: 1
DEBUG  is_app_running(mifosx): total_pods=2, ready_count=1, min_pods=2
DEBUG  Check failed: 2 pods, 1 Ready, in namespace mifosx (requires at least 2 pods, all Ready)
DEBUG  vNext or MifosX not running — retrying in 30s (97s/600s)
DEBUG  Checking for at least 2 pods, all Ready, in namespace vnext
DEBUG  Namespace check exit code: 0, output: [namespace/vnext]
DEBUG  kubectl exit code: 0, pod list: [account-lookup-http-oracle-svc-cb75f54f5-l8mhh                   1/1   Running   0             38m   10.42.0.30   gazelle1   <none>   <none>
account-lookup-svc-5bd46f7bfd-rg6jw                              1/1   Running   1 (34m ago)   38m   10.42.0.31   gazelle1   <none>   <none>
accounts-and-balances-builtin-ledger-grpc-svc-64b757d969-rzvx9   1/1   Running   2             38m   10.42.0.32   gazelle1   <none>   <none>
accounts-and-balances-coa-grpc-svc-64b974897-z84mk               1/1   Running   2 (29m ago)   38m   10.42.0.33   gazelle1   <none>   <none>
admin-ui-57f79c9774-fb6tv                                        1/1   Running   0             38m   10.42.0.34   gazelle1   <none>   <none>
auditing-svc-6479b799c6-tt6hb                                    1/1   Running   0             38m   10.42.0.22   gazelle1   <none>   <none>
authentication-svc-75744965f6-b68w8                              1/1   Running   0             38m   10.42.0.23   gazelle1   <none>   <none>
authorization-svc-984c7b95-66nzk                                 1/1   Running   0             38m   10.42.0.24   gazelle1   <none>   <none>
fspiop-api-svc-7c885b88cc-kxzzm                                  1/1   Running   0             38m   10.42.0.50   gazelle1   <none>   <none>
identity-svc-8665d57d6-4t245                                     1/1   Running   1 (34m ago)   38m   10.42.0.25   gazelle1   <none>   <none>
logging-svc-74dff9bcf6-crgxs                                     1/1   Running   0             38m   10.42.0.26   gazelle1   <none>   <none>
participants-reporting-svc-6dbc8dbbbb-bhzm7                      1/1   Running   0             37m   10.42.0.44   gazelle1   <none>   <none>
participants-svc-5c457bd6f-ctj47                                 1/1   Running   1 (26m ago)   38m   10.42.0.36   gazelle1   <none>   <none>
platform-configuration-svc-6767f5fdc9-sq45j                      1/1   Running   0             38m   10.42.0.46   gazelle1   <none>   <none>
quotes-reporting-svc-986b8b96c-p4wdp                             1/1   Running   2 (25m ago)   37m   10.42.0.45   gazelle1   <none>   <none>
quoting-svc-6667f8587b-hgfdz                                     1/1   Running   0             38m   10.42.0.38   gazelle1   <none>   <none>
reporting-api-svc-66c4f544d4-t8p7c                               1/1   Running   0             37m   10.42.0.47   gazelle1   <none>   <none>
scheduling-api-svc-57ff5686ff-grjsl                              1/1   Running   0             38m   10.42.0.28   gazelle1   <none>   <none>
scheduling-command-handler-svc-c4cbdd697-f24cl                   1/1   Running   0             38m   10.42.0.29   gazelle1   <none>   <none>
settlements-api-svc-74b86c8d76-h9t4h                             1/1   Running   0             37m   10.42.0.39   gazelle1   <none>   <none>
settlements-command-handler-svc-678fffb9d6-vxtlg                 1/1   Running   2 (25m ago)   37m   10.42.0.37   gazelle1   <none>   <none>
settlements-event-handler-svc-7c57cff98b-xsrxm                   1/1   Running   0             37m   10.42.0.40   gazelle1   <none>   <none>
settlements-reporting-svc-6c756f57d4-pnpfv                       1/1   Running   0             37m   10.42.0.48   gazelle1   <none>   <none>
transfers-api-svc-78cf5cc99c-s7982                               1/1   Running   0             37m   10.42.0.41   gazelle1   <none>   <none>
transfers-command-handler-svc-5956cf4c97-d7tn7                   1/1   Running   2 (25m ago)   37m   10.42.0.42   gazelle1   <none>   <none>
transfers-event-handler-svc-5f8d7f7dfd-hmpdn                     1/1   Running   0             37m   10.42.0.43   gazelle1   <none>   <none>
transfers-reporting-svc-746cd7c9c-7q2m8                          1/1   Running   0             37m   10.42.0.49   gazelle1   <none>   <none>], total pods: 27, ready pods: 27
DEBUG  is_app_running(vnext): total_pods=27, ready_count=27, min_pods=2
DEBUG  Found 27 pods, all Ready, in namespace vnext, meeting minimum of 2
DEBUG  Checking for at least 2 pods, all Ready, in namespace mifosx
DEBUG  Namespace check exit code: 0, output: [namespace/mifosx]
DEBUG  kubectl exit code: 0, pod list: [fineract-server-8cc57dc88-5z2ck   0/1   Running   0     2m11s   10.42.0.82   gazelle1   <none>   <none>
web-app-59df76f6d6-688wf          1/1   Running   0     2m10s   10.42.0.81   gazelle1   <none>   <none>], total pods: 2, ready pods: 1
DEBUG  is_app_running(mifosx): total_pods=2, ready_count=1, min_pods=2
DEBUG  Check failed: 2 pods, 1 Ready, in namespace mifosx (requires at least 2 pods, all Ready)
DEBUG  vNext or MifosX not running — retrying in 30s (128s/600s)
DEBUG  Checking for at least 2 pods, all Ready, in namespace vnext
DEBUG  Namespace check exit code: 0, output: [namespace/vnext]
DEBUG  kubectl exit code: 0, pod list: [account-lookup-http-oracle-svc-cb75f54f5-l8mhh                   1/1   Running   0             38m   10.42.0.30   gazelle1   <none>   <none>
account-lookup-svc-5bd46f7bfd-rg6jw                              1/1   Running   1 (34m ago)   38m   10.42.0.31   gazelle1   <none>   <none>
accounts-and-balances-builtin-ledger-grpc-svc-64b757d969-rzvx9   1/1   Running   2             38m   10.42.0.32   gazelle1   <none>   <none>
accounts-and-balances-coa-grpc-svc-64b974897-z84mk               1/1   Running   2 (30m ago)   38m   10.42.0.33   gazelle1   <none>   <none>
admin-ui-57f79c9774-fb6tv                                        1/1   Running   0             38m   10.42.0.34   gazelle1   <none>   <none>
auditing-svc-6479b799c6-tt6hb                                    1/1   Running   0             38m   10.42.0.22   gazelle1   <none>   <none>
authentication-svc-75744965f6-b68w8                              1/1   Running   0             38m   10.42.0.23   gazelle1   <none>   <none>
authorization-svc-984c7b95-66nzk                                 1/1   Running   0             38m   10.42.0.24   gazelle1   <none>   <none>
fspiop-api-svc-7c885b88cc-kxzzm                                  1/1   Running   0             38m   10.42.0.50   gazelle1   <none>   <none>
identity-svc-8665d57d6-4t245                                     1/1   Running   1 (35m ago)   38m   10.42.0.25   gazelle1   <none>   <none>
logging-svc-74dff9bcf6-crgxs                                     1/1   Running   0             38m   10.42.0.26   gazelle1   <none>   <none>
participants-reporting-svc-6dbc8dbbbb-bhzm7                      1/1   Running   0             38m   10.42.0.44   gazelle1   <none>   <none>
participants-svc-5c457bd6f-ctj47                                 1/1   Running   1 (26m ago)   38m   10.42.0.36   gazelle1   <none>   <none>
platform-configuration-svc-6767f5fdc9-sq45j                      1/1   Running   0             38m   10.42.0.46   gazelle1   <none>   <none>
quotes-reporting-svc-986b8b96c-p4wdp                             1/1   Running   2 (25m ago)   38m   10.42.0.45   gazelle1   <none>   <none>
quoting-svc-6667f8587b-hgfdz                                     1/1   Running   0             38m   10.42.0.38   gazelle1   <none>   <none>
reporting-api-svc-66c4f544d4-t8p7c                               1/1   Running   0             38m   10.42.0.47   gazelle1   <none>   <none>
scheduling-api-svc-57ff5686ff-grjsl                              1/1   Running   0             38m   10.42.0.28   gazelle1   <none>   <none>
scheduling-command-handler-svc-c4cbdd697-f24cl                   1/1   Running   0             38m   10.42.0.29   gazelle1   <none>   <none>
settlements-api-svc-74b86c8d76-h9t4h                             1/1   Running   0             38m   10.42.0.39   gazelle1   <none>   <none>
settlements-command-handler-svc-678fffb9d6-vxtlg                 1/1   Running   2 (25m ago)   38m   10.42.0.37   gazelle1   <none>   <none>
settlements-event-handler-svc-7c57cff98b-xsrxm                   1/1   Running   0             38m   10.42.0.40   gazelle1   <none>   <none>
settlements-reporting-svc-6c756f57d4-pnpfv                       1/1   Running   0             38m   10.42.0.48   gazelle1   <none>   <none>
transfers-api-svc-78cf5cc99c-s7982                               1/1   Running   0             38m   10.42.0.41   gazelle1   <none>   <none>
transfers-command-handler-svc-5956cf4c97-d7tn7                   1/1   Running   2 (25m ago)   38m   10.42.0.42   gazelle1   <none>   <none>
transfers-event-handler-svc-5f8d7f7dfd-hmpdn                     1/1   Running   0             38m   10.42.0.43   gazelle1   <none>   <none>
transfers-reporting-svc-746cd7c9c-7q2m8                          1/1   Running   0             38m   10.42.0.49   gazelle1   <none>   <none>], total pods: 27, ready pods: 27
DEBUG  is_app_running(vnext): total_pods=27, ready_count=27, min_pods=2
DEBUG  Found 27 pods, all Ready, in namespace vnext, meeting minimum of 2
DEBUG  Checking for at least 2 pods, all Ready, in namespace mifosx
DEBUG  Namespace check exit code: 0, output: [namespace/mifosx]
DEBUG  kubectl exit code: 0, pod list: [fineract-server-8cc57dc88-5z2ck   0/1   Running   0     2m43s   10.42.0.82   gazelle1   <none>   <none>
web-app-59df76f6d6-688wf          1/1   Running   0     2m42s   10.42.0.81   gazelle1   <none>   <none>], total pods: 2, ready pods: 1
DEBUG  is_app_running(mifosx): total_pods=2, ready_count=1, min_pods=2
DEBUG  Check failed: 2 pods, 1 Ready, in namespace mifosx (requires at least 2 pods, all Ready)
DEBUG  vNext or MifosX not running — retrying in 30s (160s/600s)
DEBUG  Checking for at least 2 pods, all Ready, in namespace vnext
DEBUG  Namespace check exit code: 0, output: [namespace/vnext]
DEBUG  kubectl exit code: 0, pod list: [account-lookup-http-oracle-svc-cb75f54f5-l8mhh                   1/1   Running   0             39m   10.42.0.30   gazelle1   <none>   <none>
account-lookup-svc-5bd46f7bfd-rg6jw                              1/1   Running   1 (35m ago)   39m   10.42.0.31   gazelle1   <none>   <none>
accounts-and-balances-builtin-ledger-grpc-svc-64b757d969-rzvx9   1/1   Running   2             39m   10.42.0.32   gazelle1   <none>   <none>
accounts-and-balances-coa-grpc-svc-64b974897-z84mk               1/1   Running   2 (30m ago)   39m   10.42.0.33   gazelle1   <none>   <none>
admin-ui-57f79c9774-fb6tv                                        1/1   Running   0             39m   10.42.0.34   gazelle1   <none>   <none>
auditing-svc-6479b799c6-tt6hb                                    1/1   Running   0             39m   10.42.0.22   gazelle1   <none>   <none>
authentication-svc-75744965f6-b68w8                              1/1   Running   0             39m   10.42.0.23   gazelle1   <none>   <none>
authorization-svc-984c7b95-66nzk                                 1/1   Running   0             39m   10.42.0.24   gazelle1   <none>   <none>
fspiop-api-svc-7c885b88cc-kxzzm                                  1/1   Running   0             39m   10.42.0.50   gazelle1   <none>   <none>
identity-svc-8665d57d6-4t245                                     1/1   Running   1 (35m ago)   39m   10.42.0.25   gazelle1   <none>   <none>
logging-svc-74dff9bcf6-crgxs                                     1/1   Running   0             39m   10.42.0.26   gazelle1   <none>   <none>
participants-reporting-svc-6dbc8dbbbb-bhzm7                      1/1   Running   0             38m   10.42.0.44   gazelle1   <none>   <none>
participants-svc-5c457bd6f-ctj47                                 1/1   Running   1 (27m ago)   39m   10.42.0.36   gazelle1   <none>   <none>
platform-configuration-svc-6767f5fdc9-sq45j                      1/1   Running   0             39m   10.42.0.46   gazelle1   <none>   <none>
quotes-reporting-svc-986b8b96c-p4wdp                             1/1   Running   2 (26m ago)   38m   10.42.0.45   gazelle1   <none>   <none>
quoting-svc-6667f8587b-hgfdz                                     1/1   Running   0             39m   10.42.0.38   gazelle1   <none>   <none>
reporting-api-svc-66c4f544d4-t8p7c                               1/1   Running   0             38m   10.42.0.47   gazelle1   <none>   <none>
scheduling-api-svc-57ff5686ff-grjsl                              1/1   Running   0             39m   10.42.0.28   gazelle1   <none>   <none>
scheduling-command-handler-svc-c4cbdd697-f24cl                   1/1   Running   0             39m   10.42.0.29   gazelle1   <none>   <none>
settlements-api-svc-74b86c8d76-h9t4h                             1/1   Running   0             38m   10.42.0.39   gazelle1   <none>   <none>
settlements-command-handler-svc-678fffb9d6-vxtlg                 1/1   Running   2 (26m ago)   38m   10.42.0.37   gazelle1   <none>   <none>
settlements-event-handler-svc-7c57cff98b-xsrxm                   1/1   Running   0             38m   10.42.0.40   gazelle1   <none>   <none>
settlements-reporting-svc-6c756f57d4-pnpfv                       1/1   Running   0             38m   10.42.0.48   gazelle1   <none>   <none>
transfers-api-svc-78cf5cc99c-s7982                               1/1   Running   0             38m   10.42.0.41   gazelle1   <none>   <none>
transfers-command-handler-svc-5956cf4c97-d7tn7                   1/1   Running   2 (26m ago)   38m   10.42.0.42   gazelle1   <none>   <none>
transfers-event-handler-svc-5f8d7f7dfd-hmpdn                     1/1   Running   0             38m   10.42.0.43   gazelle1   <none>   <none>
transfers-reporting-svc-746cd7c9c-7q2m8                          1/1   Running   0             38m   10.42.0.49   gazelle1   <none>   <none>], total pods: 27, ready pods: 27
DEBUG  is_app_running(vnext): total_pods=27, ready_count=27, min_pods=2
DEBUG  Found 27 pods, all Ready, in namespace vnext, meeting minimum of 2
DEBUG  Checking for at least 2 pods, all Ready, in namespace mifosx
DEBUG  Namespace check exit code: 0, output: [namespace/mifosx]
DEBUG  kubectl exit code: 0, pod list: [fineract-server-8cc57dc88-5z2ck   0/1   Running   0     3m14s   10.42.0.82   gazelle1   <none>   <none>
web-app-59df76f6d6-688wf          1/1   Running   0     3m13s   10.42.0.81   gazelle1   <none>   <none>], total pods: 2, ready pods: 1
DEBUG  is_app_running(mifosx): total_pods=2, ready_count=1, min_pods=2
DEBUG  Check failed: 2 pods, 1 Ready, in namespace mifosx (requires at least 2 pods, all Ready)
DEBUG  vNext or MifosX not running — retrying in 30s (191s/600s)
DEBUG  Checking for at least 2 pods, all Ready, in namespace vnext
DEBUG  Namespace check exit code: 0, output: [namespace/vnext]
DEBUG  kubectl exit code: 0, pod list: [account-lookup-http-oracle-svc-cb75f54f5-l8mhh                   1/1   Running   0             39m   10.42.0.30   gazelle1   <none>   <none>
account-lookup-svc-5bd46f7bfd-rg6jw                              1/1   Running   1 (35m ago)   39m   10.42.0.31   gazelle1   <none>   <none>
accounts-and-balances-builtin-ledger-grpc-svc-64b757d969-rzvx9   1/1   Running   2             39m   10.42.0.32   gazelle1   <none>   <none>
accounts-and-balances-coa-grpc-svc-64b974897-z84mk               1/1   Running   2 (31m ago)   39m   10.42.0.33   gazelle1   <none>   <none>
admin-ui-57f79c9774-fb6tv                                        1/1   Running   0             39m   10.42.0.34   gazelle1   <none>   <none>
auditing-svc-6479b799c6-tt6hb                                    1/1   Running   0             39m   10.42.0.22   gazelle1   <none>   <none>
authentication-svc-75744965f6-b68w8                              1/1   Running   0             39m   10.42.0.23   gazelle1   <none>   <none>
authorization-svc-984c7b95-66nzk                                 1/1   Running   0             39m   10.42.0.24   gazelle1   <none>   <none>
fspiop-api-svc-7c885b88cc-kxzzm                                  1/1   Running   0             39m   10.42.0.50   gazelle1   <none>   <none>
identity-svc-8665d57d6-4t245                                     1/1   Running   1 (36m ago)   39m   10.42.0.25   gazelle1   <none>   <none>
logging-svc-74dff9bcf6-crgxs                                     1/1   Running   0             39m   10.42.0.26   gazelle1   <none>   <none>
participants-reporting-svc-6dbc8dbbbb-bhzm7                      1/1   Running   0             39m   10.42.0.44   gazelle1   <none>   <none>
participants-svc-5c457bd6f-ctj47                                 1/1   Running   1 (27m ago)   39m   10.42.0.36   gazelle1   <none>   <none>
platform-configuration-svc-6767f5fdc9-sq45j                      1/1   Running   0             39m   10.42.0.46   gazelle1   <none>   <none>
quotes-reporting-svc-986b8b96c-p4wdp                             1/1   Running   2 (26m ago)   39m   10.42.0.45   gazelle1   <none>   <none>
quoting-svc-6667f8587b-hgfdz                                     1/1   Running   0             39m   10.42.0.38   gazelle1   <none>   <none>
reporting-api-svc-66c4f544d4-t8p7c                               1/1   Running   0             39m   10.42.0.47   gazelle1   <none>   <none>
scheduling-api-svc-57ff5686ff-grjsl                              1/1   Running   0             39m   10.42.0.28   gazelle1   <none>   <none>
scheduling-command-handler-svc-c4cbdd697-f24cl                   1/1   Running   0             39m   10.42.0.29   gazelle1   <none>   <none>
settlements-api-svc-74b86c8d76-h9t4h                             1/1   Running   0             39m   10.42.0.39   gazelle1   <none>   <none>
settlements-command-handler-svc-678fffb9d6-vxtlg                 1/1   Running   2 (26m ago)   39m   10.42.0.37   gazelle1   <none>   <none>
settlements-event-handler-svc-7c57cff98b-xsrxm                   1/1   Running   0             39m   10.42.0.40   gazelle1   <none>   <none>
settlements-reporting-svc-6c756f57d4-pnpfv                       1/1   Running   0             39m   10.42.0.48   gazelle1   <none>   <none>
transfers-api-svc-78cf5cc99c-s7982                               1/1   Running   0             39m   10.42.0.41   gazelle1   <none>   <none>
transfers-command-handler-svc-5956cf4c97-d7tn7                   1/1   Running   2 (26m ago)   39m   10.42.0.42   gazelle1   <none>   <none>
transfers-event-handler-svc-5f8d7f7dfd-hmpdn                     1/1   Running   0             39m   10.42.0.43   gazelle1   <none>   <none>
transfers-reporting-svc-746cd7c9c-7q2m8                          1/1   Running   0             39m   10.42.0.49   gazelle1   <none>   <none>], total pods: 27, ready pods: 27
DEBUG  is_app_running(vnext): total_pods=27, ready_count=27, min_pods=2
DEBUG  Found 27 pods, all Ready, in namespace vnext, meeting minimum of 2
DEBUG  Checking for at least 2 pods, all Ready, in namespace mifosx
DEBUG  Namespace check exit code: 0, output: [namespace/mifosx]
DEBUG  kubectl exit code: 0, pod list: [fineract-server-8cc57dc88-5z2ck   0/1   Running   0     3m45s   10.42.0.82   gazelle1   <none>   <none>
web-app-59df76f6d6-688wf          1/1   Running   0     3m44s   10.42.0.81   gazelle1   <none>   <none>], total pods: 2, ready pods: 1
DEBUG  is_app_running(mifosx): total_pods=2, ready_count=1, min_pods=2
DEBUG  Check failed: 2 pods, 1 Ready, in namespace mifosx (requires at least 2 pods, all Ready)
DEBUG  vNext or MifosX not running — retrying in 30s (222s/600s)
DEBUG  Checking for at least 2 pods, all Ready, in namespace vnext
DEBUG  Namespace check exit code: 0, output: [namespace/vnext]
DEBUG  kubectl exit code: 0, pod list: [account-lookup-http-oracle-svc-cb75f54f5-l8mhh                   1/1   Running   0             40m   10.42.0.30   gazelle1   <none>   <none>
account-lookup-svc-5bd46f7bfd-rg6jw                              1/1   Running   1 (36m ago)   40m   10.42.0.31   gazelle1   <none>   <none>
accounts-and-balances-builtin-ledger-grpc-svc-64b757d969-rzvx9   1/1   Running   2             40m   10.42.0.32   gazelle1   <none>   <none>
accounts-and-balances-coa-grpc-svc-64b974897-z84mk               1/1   Running   2 (31m ago)   40m   10.42.0.33   gazelle1   <none>   <none>
admin-ui-57f79c9774-fb6tv                                        1/1   Running   0             40m   10.42.0.34   gazelle1   <none>   <none>
auditing-svc-6479b799c6-tt6hb                                    1/1   Running   0             40m   10.42.0.22   gazelle1   <none>   <none>
authentication-svc-75744965f6-b68w8                              1/1   Running   0             40m   10.42.0.23   gazelle1   <none>   <none>
authorization-svc-984c7b95-66nzk                                 1/1   Running   0             40m   10.42.0.24   gazelle1   <none>   <none>
fspiop-api-svc-7c885b88cc-kxzzm                                  1/1   Running   0             40m   10.42.0.50   gazelle1   <none>   <none>
identity-svc-8665d57d6-4t245                                     1/1   Running   1 (36m ago)   40m   10.42.0.25   gazelle1   <none>   <none>
logging-svc-74dff9bcf6-crgxs                                     1/1   Running   0             40m   10.42.0.26   gazelle1   <none>   <none>
participants-reporting-svc-6dbc8dbbbb-bhzm7                      1/1   Running   0             39m   10.42.0.44   gazelle1   <none>   <none>
participants-svc-5c457bd6f-ctj47                                 1/1   Running   1 (28m ago)   40m   10.42.0.36   gazelle1   <none>   <none>
platform-configuration-svc-6767f5fdc9-sq45j                      1/1   Running   0             40m   10.42.0.46   gazelle1   <none>   <none>
quotes-reporting-svc-986b8b96c-p4wdp                             1/1   Running   2 (27m ago)   39m   10.42.0.45   gazelle1   <none>   <none>
quoting-svc-6667f8587b-hgfdz                                     1/1   Running   0             40m   10.42.0.38   gazelle1   <none>   <none>
reporting-api-svc-66c4f544d4-t8p7c                               1/1   Running   0             39m   10.42.0.47   gazelle1   <none>   <none>
scheduling-api-svc-57ff5686ff-grjsl                              1/1   Running   0             40m   10.42.0.28   gazelle1   <none>   <none>
scheduling-command-handler-svc-c4cbdd697-f24cl                   1/1   Running   0             40m   10.42.0.29   gazelle1   <none>   <none>
settlements-api-svc-74b86c8d76-h9t4h                             1/1   Running   0             40m   10.42.0.39   gazelle1   <none>   <none>
settlements-command-handler-svc-678fffb9d6-vxtlg                 1/1   Running   2 (27m ago)   39m   10.42.0.37   gazelle1   <none>   <none>
settlements-event-handler-svc-7c57cff98b-xsrxm                   1/1   Running   0             39m   10.42.0.40   gazelle1   <none>   <none>
settlements-reporting-svc-6c756f57d4-pnpfv                       1/1   Running   0             39m   10.42.0.48   gazelle1   <none>   <none>
transfers-api-svc-78cf5cc99c-s7982                               1/1   Running   0             39m   10.42.0.41   gazelle1   <none>   <none>
transfers-command-handler-svc-5956cf4c97-d7tn7                   1/1   Running   2 (27m ago)   39m   10.42.0.42   gazelle1   <none>   <none>
transfers-event-handler-svc-5f8d7f7dfd-hmpdn                     1/1   Running   0             39m   10.42.0.43   gazelle1   <none>   <none>
transfers-reporting-svc-746cd7c9c-7q2m8                          1/1   Running   0             39m   10.42.0.49   gazelle1   <none>   <none>], total pods: 27, ready pods: 27
DEBUG  is_app_running(vnext): total_pods=27, ready_count=27, min_pods=2
DEBUG  Found 27 pods, all Ready, in namespace vnext, meeting minimum of 2
DEBUG  Checking for at least 2 pods, all Ready, in namespace mifosx
DEBUG  Namespace check exit code: 0, output: [namespace/mifosx]
DEBUG  kubectl exit code: 0, pod list: [fineract-server-8cc57dc88-5z2ck   0/1   Running   0     4m16s   10.42.0.82   gazelle1   <none>   <none>
web-app-59df76f6d6-688wf          1/1   Running   0     4m15s   10.42.0.81   gazelle1   <none>   <none>], total pods: 2, ready pods: 1
DEBUG  is_app_running(mifosx): total_pods=2, ready_count=1, min_pods=2
DEBUG  Check failed: 2 pods, 1 Ready, in namespace mifosx (requires at least 2 pods, all Ready)
DEBUG  vNext or MifosX not running — retrying in 30s (253s/600s)
DEBUG  Checking for at least 2 pods, all Ready, in namespace vnext
DEBUG  Namespace check exit code: 0, output: [namespace/vnext]
DEBUG  kubectl exit code: 0, pod list: [account-lookup-http-oracle-svc-cb75f54f5-l8mhh                   1/1   Running   0             40m   10.42.0.30   gazelle1   <none>   <none>
account-lookup-svc-5bd46f7bfd-rg6jw                              1/1   Running   1 (36m ago)   40m   10.42.0.31   gazelle1   <none>   <none>
accounts-and-balances-builtin-ledger-grpc-svc-64b757d969-rzvx9   1/1   Running   2             40m   10.42.0.32   gazelle1   <none>   <none>
accounts-and-balances-coa-grpc-svc-64b974897-z84mk               1/1   Running   2 (32m ago)   40m   10.42.0.33   gazelle1   <none>   <none>
admin-ui-57f79c9774-fb6tv                                        1/1   Running   0             40m   10.42.0.34   gazelle1   <none>   <none>
auditing-svc-6479b799c6-tt6hb                                    1/1   Running   0             40m   10.42.0.22   gazelle1   <none>   <none>
authentication-svc-75744965f6-b68w8                              1/1   Running   0             40m   10.42.0.23   gazelle1   <none>   <none>
authorization-svc-984c7b95-66nzk                                 1/1   Running   0             40m   10.42.0.24   gazelle1   <none>   <none>
fspiop-api-svc-7c885b88cc-kxzzm                                  1/1   Running   0             40m   10.42.0.50   gazelle1   <none>   <none>
identity-svc-8665d57d6-4t245                                     1/1   Running   1 (37m ago)   40m   10.42.0.25   gazelle1   <none>   <none>
logging-svc-74dff9bcf6-crgxs                                     1/1   Running   0             40m   10.42.0.26   gazelle1   <none>   <none>
participants-reporting-svc-6dbc8dbbbb-bhzm7                      1/1   Running   0             40m   10.42.0.44   gazelle1   <none>   <none>
participants-svc-5c457bd6f-ctj47                                 1/1   Running   1 (28m ago)   40m   10.42.0.36   gazelle1   <none>   <none>
platform-configuration-svc-6767f5fdc9-sq45j                      1/1   Running   0             40m   10.42.0.46   gazelle1   <none>   <none>
quotes-reporting-svc-986b8b96c-p4wdp                             1/1   Running   2 (27m ago)   40m   10.42.0.45   gazelle1   <none>   <none>
quoting-svc-6667f8587b-hgfdz                                     1/1   Running   0             40m   10.42.0.38   gazelle1   <none>   <none>
reporting-api-svc-66c4f544d4-t8p7c                               1/1   Running   0             40m   10.42.0.47   gazelle1   <none>   <none>
scheduling-api-svc-57ff5686ff-grjsl                              1/1   Running   0             40m   10.42.0.28   gazelle1   <none>   <none>
scheduling-command-handler-svc-c4cbdd697-f24cl                   1/1   Running   0             40m   10.42.0.29   gazelle1   <none>   <none>
settlements-api-svc-74b86c8d76-h9t4h                             1/1   Running   0             40m   10.42.0.39   gazelle1   <none>   <none>
settlements-command-handler-svc-678fffb9d6-vxtlg                 1/1   Running   2 (28m ago)   40m   10.42.0.37   gazelle1   <none>   <none>
settlements-event-handler-svc-7c57cff98b-xsrxm                   1/1   Running   0             40m   10.42.0.40   gazelle1   <none>   <none>
settlements-reporting-svc-6c756f57d4-pnpfv                       1/1   Running   0             40m   10.42.0.48   gazelle1   <none>   <none>
transfers-api-svc-78cf5cc99c-s7982                               1/1   Running   0             40m   10.42.0.41   gazelle1   <none>   <none>
transfers-command-handler-svc-5956cf4c97-d7tn7                   1/1   Running   2 (27m ago)   40m   10.42.0.42   gazelle1   <none>   <none>
transfers-event-handler-svc-5f8d7f7dfd-hmpdn                     1/1   Running   0             40m   10.42.0.43   gazelle1   <none>   <none>
transfers-reporting-svc-746cd7c9c-7q2m8                          1/1   Running   0             40m   10.42.0.49   gazelle1   <none>   <none>], total pods: 27, ready pods: 27
DEBUG  is_app_running(vnext): total_pods=27, ready_count=27, min_pods=2
DEBUG  Found 27 pods, all Ready, in namespace vnext, meeting minimum of 2
DEBUG  Checking for at least 2 pods, all Ready, in namespace mifosx
DEBUG  Namespace check exit code: 0, output: [namespace/mifosx]
DEBUG  kubectl exit code: 0, pod list: [fineract-server-8cc57dc88-5z2ck   1/1   Running   0     4m46s   10.42.0.82   gazelle1   <none>   <none>
web-app-59df76f6d6-688wf          1/1   Running   0     4m45s   10.42.0.81   gazelle1   <none>   <none>], total pods: 2, ready pods: 2
DEBUG  is_app_running(mifosx): total_pods=2, ready_count=2, min_pods=2
DEBUG  Found 2 pods, all Ready, in namespace mifosx, meeting minimum of 2
    Waiting for Fineract tenant APIs (schema + seed data, timeout=600s) DEBUG  Tenant 'greenbank' ready (0s elapsed)
DEBUG  Tenant 'bluebank' ready (7s elapsed)
DEBUG  Tenant 'redbank' ready (7s elapsed)
[  ok  ]
    Generating MifosX clients and registering vNext Oracle associations 

=== CREATE MODE: Generating new clients ===


=== Tenant: bluebank ===
  bluebank already has 6 client(s) - re-registering, skipping creation
vNext registration OK for 0495822412
✓ Registered 0495822412 → account 1 @ bluebank (payer: greenbank)
   Response: Request not acknowledged by Pay-BB
✓ Registered 0495822412 → account 1 @ bluebank (payer: redbank)
   Response: Request not acknowledged by Pay-BB
vNext registration OK for 0424942603
✓ Registered 0424942603 → account 2 @ bluebank (payer: greenbank)
   Response: Request not acknowledged by Pay-BB
✓ Registered 0424942603 → account 2 @ bluebank (payer: redbank)
   Response: Request not acknowledged by Pay-BB
vNext registration OK for 0445271476
✓ Registered 0445271476 → account 3 @ bluebank (payer: greenbank)
   Response: Request not acknowledged by Pay-BB
✓ Registered 0445271476 → account 3 @ bluebank (payer: redbank)
   Response: Request not acknowledged by Pay-BB
vNext registration OK for 0450258089
✓ Registered 0450258089 → account 4 @ bluebank (payer: greenbank)
   Response: Request not acknowledged by Pay-BB
✓ Registered 0450258089 → account 4 @ bluebank (payer: redbank)
   Response: Request not acknowledged by Pay-BB
vNext registration OK for 0498660918
✓ Registered 0498660918 → account 5 @ bluebank (payer: greenbank)
   Response: Request not acknowledged by Pay-BB
✓ Registered 0498660918 → account 5 @ bluebank (payer: redbank)
   Response: Request not acknowledged by Pay-BB
vNext registration OK for 0472794194
✓ Registered 0472794194 → account 6 @ bluebank (payer: greenbank)
   Response: Request not acknowledged by Pay-BB
✓ Registered 0472794194 → account 6 @ bluebank (payer: redbank)
   Response: Request not acknowledged by Pay-BB
=== Finished tenant bluebank (existing clients re-registered) ===


=== Tenant: greenbank ===
Finding/creating product 'savb' for greenbank-savings...
WARNING: Unexpected response type: <class 'dict'>
Created product ID 1

--- Client 1/1 for greenbank (attempt 1) ---
Creating client Sebastian Moore (0413509790) for greenbank
Client ID 1
Savings account 1 (ext 1219dd6e-5818-4c49-999e-2c9f8579934a)
Interop party registered
vNext registration OK for 0413509790
Skipping identity-mapper for payer tenant greenbank
--- Finished client 1 ---
=== Finished tenant greenbank ===


=== Tenant: redbank ===
  redbank already has 3 client(s) - re-registering, skipping creation
vNext registration OK for 0413356886
  Skipping identity-mapper for payer tenant redbank
vNext registration OK for 0423416547
  Skipping identity-mapper for payer tenant redbank
vNext registration OK for 0412728990
  Skipping identity-mapper for payer tenant redbank
=== Finished tenant redbank (existing clients re-registered) ===


✓ All tenants processed successfully.
[  ok  ]
    Generating sample CSV files 

[  ok  ]

==================================
 Mifos Gazelle Ready
==================================

  MifosX:        https://mifos.mifos.gazelle.test
  vNext Admin:   http://vnextadmin.mifos.gazelle.test
  Ops Web:       http://ops.mifos.gazelle.test
  Zeebe Operate: http://zeebe-operate.mifos.gazelle.test

  kubectl get pods -A
```

