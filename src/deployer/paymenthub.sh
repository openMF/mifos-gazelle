#!/usr/bin/env bash
# paymenthub.sh -- Mifos Gazelle deployer script for PaymentHub EE
#
# Deployment sequence:
#   1. deploy_ph_infra_helm  -- Helm --wait: Zeebe, operationsmysql, Redis, MinIO, Kafka into paymenthub ns
#   2. elastic + TLS secrets
#   3. deploy_ph_operator      -- CRD + operator pod + PaymentHubDeployment CRs
#   4. wait_for_phee_crs_ready -- poll until all enabled CRs reach ready; zeebe-ops confirmed up
#   4b. wait_for_pods_ready    -- CRs report ready once Deployments exist, not once pods pass
#                                 their readiness probes — this waits for the latter
#   5. deploy_bpmns            -- curl BPMN files to zeebe-ops ingress (https://zeebeops.$GAZELLE_DOMAIN)

#------------------------------------------------------------------------------
# Function : deploy_ph
# Description: Top-level entry point — deploys Payment Hub EE infrastructure
#              via Helm then hands app-layer components to the Java operator.
#------------------------------------------------------------------------------
deploy_ph(){
  log_section "Deploying Payment Hub EE"

  if is_app_running "$PH_NAMESPACE"; then
    if [[ "$redeploy" == "false" ]]; then
      echo "    Payment Hub EE already deployed — skipping."
      return 0
    fi
  fi

  log_step "Removing existing Payment Hub resources"
  clean_phee
  kubectl wait --for=delete "namespace/$PH_NAMESPACE" --timeout=300s > /dev/null 2>&1 || true
  log_ok

  kubectl wait --for=condition=ready pod --all -n "$VNEXT_NAMESPACE" --timeout=600s > /dev/null 2>&1

  log_step "Creating namespace $PH_NAMESPACE"
  create_namespace "$PH_NAMESPACE"
  log_ok

  # Step 1 — infra services via Helm (Zeebe, operationsmysql, Redis, MinIO, Kafka)
  # Helm --wait already blocks until all chart pods are ready; no extra wait needed.
  deploy_ph_infra_helm

  # Step 2 — secrets
  log_step "Creating elastic secrets"
  manage_elastic_secrets delete "$INFRA_NAMESPACE"
  manage_elastic_secrets create "$PH_NAMESPACE"
  manage_elastic_secrets create "$INFRA_NAMESPACE"
  log_ok

  create_ingress_secret "$PH_NAMESPACE" \
    "bulk-processor.$GAZELLE_DOMAIN" \
    "sandbox-secret" \
    "ops.$GAZELLE_DOMAIN,ops-bk.$GAZELLE_DOMAIN,api.$GAZELLE_DOMAIN,*.$GAZELLE_DOMAIN,localhost,ph-ee-connector-channel,ph-ee-connector-channel.$PH_NAMESPACE.svc.cluster.local"

  # Step 3 — operator reconciles app component Deployments, Services, Ingresses
  deploy_ph_operator || { log_failed "PaymentHub operator deployment failed"; return 1; }

  # Step 4 — wait for all CRs to reach ready (operator has created K8s resources)
  wait_for_phee_crs_ready

  # Step 4b — wait for all operator-managed pods to pass their readiness probes
  # (CRs become ready when Deployments are created, not when pods are Running)
  wait_for_pods_ready "$PH_NAMESPACE" "${startup_timeout:-600}"

  # Step 5 — curl BPMN files directly to zeebe-ops via its ingress
  deploy_bpmns

  log_banner "Payment Hub EE Deployed"
}

#------------------------------------------------------------------------------
# Function : clean_phee
# Description: Orderly PHEE teardown for cleanapps mode.
#   1. Scale operator to 0 and wait for its pod to actually terminate (order
#      matters here — see inline comment).
#   2. Remove finalizers from all PaymentHubDeployment CRs — otherwise those
#      finalizers are never processed and the namespace hangs in Terminating.
#   3. helm uninstall — sends orderly SIGTERM to Zeebe/Kafka/Redis/MinIO/MySQL pods.
#   4. cleanup_phee_cluster_rbac — removes orphaned cluster-scoped RBAC.
#   5. kubectl delete ns --wait=false — fire-and-forget; Kubernetes drains in background.
#------------------------------------------------------------------------------
clean_phee() {
  # Must wait for the operator pod to actually die before clearing finalizers
  # below, not just fire the scale-down: clearing them while it's still alive
  # (even mid-shutdown) races its reconcile loop, which re-adds a finalizer to
  # any CR not yet marked for deletion. If that happens, the CR gets its
  # finalizer back moments before the operator is actually gone — and once
  # it's gone, nothing is left to process that finalizer, so the CR (and the
  # whole namespace) hangs in Terminating forever, fixable only by hand-patching
  # afterwards. Waiting here closes that window.
  kubectl scale deployment/ph-ee-operator --replicas=0 -n "$PH_NAMESPACE" > /dev/null 2>&1 || true
  kubectl wait --for=delete pod -l app=ph-ee-operator -n "$PH_NAMESPACE" --timeout=60s > /dev/null 2>&1 || true

  kubectl get paymenthubdeployments -n "$PH_NAMESPACE" -o name 2>/dev/null \
    | xargs -r -I{} kubectl patch {} -n "$PH_NAMESPACE" --type=merge -p '{"metadata":{"finalizers":[]}}' \
    > /dev/null 2>&1 || true

  if helm status "$PH_INFRA_RELEASE_NAME" -n "$PH_NAMESPACE" > /dev/null 2>&1; then
    helm uninstall "$PH_INFRA_RELEASE_NAME" -n "$PH_NAMESPACE" > /dev/null 2>&1 || true
  fi

  cleanup_phee_cluster_rbac

  kubectl delete ns "$PH_NAMESPACE" --ignore-not-found=true --wait=false > /dev/null 2>&1 || true
}

#------------------------------------------------------------------------------
# Function : cleanup_phee_cluster_rbac
# Description: Removes cluster-scoped ClusterRoles and ClusterRoleBindings
#              left over from any previous PaymentHub Helm release. These are
#              not namespace-scoped so they survive namespace deletion and block
#              re-install under a different release name.
#------------------------------------------------------------------------------
cleanup_phee_cluster_rbac() {
  local resources
  resources=$(kubectl get clusterrole,clusterrolebinding -o json 2>/dev/null \
    | jq -r '.items[]
        | select(
            .metadata.annotations["meta.helm.sh/release-name"] != null and
            .metadata.annotations["meta.helm.sh/release-name"] != "'"$PH_INFRA_RELEASE_NAME"'"  and
            (.metadata.name | startswith("ph-ee-"))
          )
        | "\(.kind) \(.metadata.name)"' 2>/dev/null)

  if [ -z "$resources" ]; then
    return 0
  fi

  log_with_verbose_check "$debug" "$DEBUG" "Removing stale PaymentHub cluster RBAC from previous Helm release"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local kind name
    kind=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    kubectl delete "$kind" "$name" --ignore-not-found > /dev/null 2>&1
  done <<< "$resources"
}

#------------------------------------------------------------------------------
# Function : deploy_ph_infra_helm
# Description: Deploys PHEE infrastructure services (Zeebe, operationsmysql,
#              Redis, MinIO, Kafka) into the paymenthub namespace via Helm.
#              App-layer components are disabled in values — operator owns them.
#------------------------------------------------------------------------------
deploy_ph_infra_helm() {
  local pheeInfraChartPath="$RUN_DIR/src/deployer/helm/paymenthub-infra"

  log_step "Updating FQDNs in Helm override values"
  apply_domain_to_file "$PH_VALUES_FILE" "$GAZELLE_DOMAIN"
  log_ok

  ensure_helm_dependencies "$pheeInfraChartPath"

  local helm_cmd=(helm upgrade --install "$PH_INFRA_RELEASE_NAME" "$pheeInfraChartPath" -n "$PH_NAMESPACE" --wait --timeout 1200s)
  if [ -n "$PH_VALUES_FILE" ]; then
    helm_cmd+=(-f "$PH_VALUES_FILE")
  fi

  log_step "Helm install ($PH_INFRA_RELEASE_NAME)"
  log_with_verbose_check "$debug" "$DEBUG" "→ ${helm_cmd[*]}"

  local install_exit_code output
  if [ "$debug" = true ]; then
    "${helm_cmd[@]}"
    install_exit_code=$?
  else
    output=$("${helm_cmd[@]}" 2>&1)
    install_exit_code=$?
  fi

  if [[ $install_exit_code -eq 0 ]]; then
    log_ok
    return 0
  else
    log_failed "Helm install of '$PH_INFRA_RELEASE_NAME' failed (exit $install_exit_code)"
    return 1
  fi
}

#------------------------------------------------------------------------------
# Function : write_operator_deployment_image
# Description: Outputs a complete Deployment YAML for the operator in image
#              mode — uses the published Docker image with its own ENTRYPOINT.
# Parameters:
#   $1 - operator Docker image (e.g. openmf/ph-ee-k8s-operators:dev-dd9ac20)
#------------------------------------------------------------------------------
write_operator_deployment_image() {
  local image="$1"
  cat <<-YAML
	apiVersion: apps/v1
	kind: Deployment
	metadata:
	  name: ph-ee-operator
	  namespace: paymenthub
	  labels:
	    app: ph-ee-operator
	spec:
	  replicas: 1
	  selector:
	    matchLabels:
	      app: ph-ee-operator
	  template:
	    metadata:
	      labels:
	        app: ph-ee-operator
	    spec:
	      serviceAccountName: ph-ee-operator-sa
	      containers:
	        - name: operator
	          image: ${image}
	          imagePullPolicy: Always
	          env:
	            - name: WATCH_NAMESPACE
	              valueFrom:
	                fieldRef:
	                  fieldPath: metadata.namespace
	            - name: LOG_LEVEL
	              value: INFO
	          resources:
	            requests:
	              memory: "256Mi"
	              cpu: "250m"
	            limits:
	              memory: "512Mi"
	              cpu: "500m"
	YAML
}

#------------------------------------------------------------------------------
# Function : deploy_ph_operator
# Description: Applies the CRD, deploys the operator pod, then applies the
#              PaymentHubDeployment CRs with the Gazelle domain substituted
#              into Ingress hostnames.
#------------------------------------------------------------------------------
deploy_ph_operator() {
  local deploy_dir="$RUN_DIR/src/deployer/operators/paymenthub"

  log_step "Applying PaymentHub operator CRD"
  kubectl apply -f "$deploy_dir/config/crd/ph-ee-CustomResourceDefinition.yaml" > /dev/null || { log_failed "CRD apply failed"; return 1; }
  kubectl wait --for=condition=Established crd/paymenthubdeployments.gazelle.mifos.io --timeout=60s > /dev/null 2>&1
  log_ok

  # Apply RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding, Role, RoleBinding).
  # Deployment is applied separately below.
  log_step "Applying PaymentHub operator RBAC"
  kubectl apply -f "$deploy_dir/operator_rbac.yaml" -n "$PH_NAMESPACE" > /dev/null || { log_failed "Operator RBAC apply failed"; return 1; }
  log_ok

  # Generate and apply the operator Deployment manifest (published image only —
  # local-source-dir mode was removed; use ./localdev.py --setup --component
  # paymenthub-operator to run from a local build instead).
  local dep_manifest
  dep_manifest=$(mktemp /tmp/ph-op-dep.XXXXXX)
  mv "$dep_manifest" "${dep_manifest}.yaml"
  dep_manifest="${dep_manifest}.yaml"
  chmod 644 "$dep_manifest"

  log_step "Deploying PaymentHub operator ($PH_OPERATOR_IMAGE)"
  write_operator_deployment_image "$PH_OPERATOR_IMAGE" > "$dep_manifest"

  kubectl apply -f "$dep_manifest" > /dev/null || { log_failed "Operator Deployment apply failed"; rm -f "$dep_manifest"; return 1; }
  rm -f "$dep_manifest"

  if ! kubectl rollout status deployment/ph-ee-operator -n "$PH_NAMESPACE" --timeout=300s > /dev/null 2>&1; then
    log_failed "Operator pod did not start — check: kubectl logs deployment/ph-ee-operator -n $PH_NAMESPACE"
    return 1
  fi
  log_ok

  # Apply CRs — the operator reconciles them once running.
  log_step "Applying PaymentHubDeployment CRs"
  local cr_rendered
  cr_rendered=$(mktemp /tmp/ph-crs.XXXXXX)
  mv "$cr_rendered" "${cr_rendered}.yaml"
  cr_rendered="${cr_rendered}.yaml"
  chmod 644 "$cr_rendered"
  generate_phee_crs > "$cr_rendered"
  kubectl apply -f "$cr_rendered" > /dev/null || { log_failed "CR apply failed"; rm -f "$cr_rendered"; return 1; }
  rm -f "$cr_rendered"
  log_ok
}

#------------------------------------------------------------------------------
# Function : generate_phee_crs
# Description: Outputs the PaymentHubDeployment CR manifest stream with the
#              Gazelle domain substituted into all Ingress hostname fields
#              (e.g. "channel.local" → "channel.mifos.gazelle.test").
#              Reads the CR file and replaces .local hostnames with real domain.
#------------------------------------------------------------------------------
generate_phee_crs() {
  local cr_dir="$RUN_DIR/src/deployer/operators/paymenthub/config/cr"
  # Two substitutions per file:
  # 1. Replace "<prefix>.local" at end-of-line with "<prefix>.$GAZELLE_DOMAIN" for Ingress hosts.
  #    The $ anchor ensures cluster.local:9200 internal DNS refs are not touched.
  # 2. Replace bare GAZELLE_DOMAIN token anywhere (spec.domain field, ConfigMap property values).
  for f in "$cr_dir"/*.yaml; do
    echo "---"
    sed -e "s/\\.local$/.${GAZELLE_DOMAIN}/g" \
        -e "s/GAZELLE_DOMAIN/${GAZELLE_DOMAIN}/g" \
        "$f"
  done
}

#------------------------------------------------------------------------------
# Function : wait_for_phee_crs_ready
# Description: Polls until all PaymentHubDeployment CRs in the paymenthub
#              namespace report status.ready == true, or until
#              ${startup_timeout:-600}s elapses.
#------------------------------------------------------------------------------
wait_for_phee_crs_ready() {
  local timeout="${startup_timeout:-600}"
  local elapsed=0
  local interval=30

  log_step "Waiting for all PaymentHub CRs to become ready"

  while [ "$elapsed" -lt "$timeout" ]; do
    local cr_output
    cr_output=$(kubectl get paymenthubdeployments -n "$PH_NAMESPACE" \
      -o jsonpath='{range .items[?(@.spec.enabled==true)]}{.metadata.name}:{.status.ready} {end}' 2>/dev/null \
      | tr ' ' '\n' | grep -v '^$')

    # Count enabled CRs that have been reconciled (status.ready is set to true or false)
    local total reconciled not_ready
    total=$(echo "$cr_output" | grep -c '.')
    reconciled=$(echo "$cr_output" | grep -c ':true\|:false')
    not_ready=$(echo "$cr_output" | grep ':false' | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')

    log_with_verbose_check "$debug" "$DEBUG" "CRs reconciled: $reconciled/$total (${elapsed}s elapsed)"

    if [ "$total" -gt 0 ] && [ "$reconciled" -eq "$total" ] && [ -z "$not_ready" ]; then
      log_ok
      return 0
    fi

    if [ -n "$not_ready" ]; then
      log_with_verbose_check "$debug" "$DEBUG" "CRs not ready: $not_ready"
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  log_failed "Timed out after ${timeout}s waiting for PaymentHub CRs. Check: kubectl get paymenthubdeployments -n $PH_NAMESPACE"
  return 1
}

#------------------------------------------------------------------------------
# Function : deploy_bpmns
# Description: Deploys BPMN diagrams to Zeebe via the zeebe-ops ingress.
#------------------------------------------------------------------------------
deploy_bpmns() {
  local host="https://zeebeops.$GAZELLE_DOMAIN/zeebe/upload"
  local bpmns_dir="$BASE_DIR/orchestration/feel"
  local failed=0

  log_step "Deploying BPMN diagrams"

  local files=()
  for f in "$bpmns_dir"/*.bpmn; do
    [ -f "$f" ] && files+=("$f")
  done

  if [ "${#files[@]}" -eq 0 ]; then
    log_warn "No BPMN files found in $bpmns_dir"
    return 0
  fi

  for file in "${files[@]}"; do
    local response http_code
    local retries=6
    local attempt=0
    while [ "$attempt" -lt "$retries" ]; do
      response=$(curl --insecure --location --request POST "$host" \
        --form "file=@$file" \
        --write-out "\n%{http_code}" \
        --silent --show-error 2>&1)
      http_code=$(echo "$response" | tail -1)
      [ "$http_code" = "200" ] || [ "$http_code" = "201" ] && break
      attempt=$((attempt + 1))
      [ "$attempt" -lt "$retries" ] && sleep 15
    done
    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
      log_warn "BPMN upload failed (HTTP $http_code): $(basename "$file")"
      log_warn "  $(echo "$response" | sed '$d')"
      failed=$((failed + 1))
    fi
    sleep 1
  done

  if [ "$failed" -eq 0 ]; then
    log_ok
  else
    log_warn "$failed BPMN upload(s) failed. Re-run manually: src/utils/deployBpmn-gazelle.sh"
  fi
}

#------------------------------------------------------------------------------
# Function: are_bpmns_loaded
# Description: Checks if the required number of BPMN diagrams are loaded in Zeebe Operate.
# Parameters:
#   $1 - Minimum required number of BPMNs (default: 1)
# Returns:
#   0 if the required number of BPMNs are loaded, 1 otherwise.
#------------------------------------------------------------------------------
are_bpmns_loaded() {
  local MIN_REQUIRED=${1:-1}
  local ES_URL="http://elasticsearch.$GAZELLE_DOMAIN"
  local INDEX="zeebe-record_process_*"

  local COUNT
  COUNT=$(curl -s "$ES_URL/$INDEX/_search" \
      -H 'Content-Type: application/json' \
      -d '{
        "size": 0,
        "query": { "term": { "valueType": "PROCESS" } },
        "aggs": {
          "by_bpmn_id": {
            "composite": {
              "size": 1000,
              "sources": [ { "bpmn_id": { "terms": { "field": "value.bpmnProcessId" } } } ]
            },
            "aggs": { "latest_version": { "max": { "field": "value.version" } } }
          }
        }
      }' 2>/dev/null | jq -r '.aggregations.by_bpmn_id.buckets | length // 0')

  [[ "$COUNT" =~ ^[0-9]+$ ]] || { log_with_verbose_check "$debug" "$DEBUG" "ES query failed — assuming BPMNs not loaded"; return 1; }

  log_with_verbose_check "$debug" "$DEBUG" "Unique BPMNs already deployed: $COUNT"
  (( COUNT >= MIN_REQUIRED )) && return 0 || return 1
}

#------------------------------------------------------------------------------
# Function: generate_sample_csvs
# Description: Generates sample bulk payment CSV files for closedloop and mojaloop
#              testing. Called from generate_mifosx_and_vnext_data() after Fineract is ready.
#------------------------------------------------------------------------------
generate_sample_csvs() {
  local csv_generator="$RUN_DIR/src/utils/data-loading/generate-example-csv-files.py"
  local output_dir="$RUN_DIR/src/utils/batch"

  if [ ! -f "$csv_generator" ]; then
    log_with_verbose_check "$debug" "$WARNING" "CSV generator not found: $csv_generator"
    return 0
  fi

  log_step "Generating sample CSV files"

  local csv_log
  csv_log=$(mktemp /tmp/ph-csv-gen.XXXXXX)

  local csv_exit=0
  if [ "$debug" == "true" ]; then
    "$PYTHON3" "$csv_generator" -c "$CONFIG_FILE_PATH" --mode closedloop --num-rows 4 --output-dir "$output_dir" 2>&1 | tee -a "$csv_log"; csv_exit=$((csv_exit + ${PIPESTATUS[0]}))
    "$PYTHON3" "$csv_generator" -c "$CONFIG_FILE_PATH" --mode mojaloop --num-rows 4 --output-dir "$output_dir" 2>&1 | tee -a "$csv_log"; csv_exit=$((csv_exit + ${PIPESTATUS[0]}))
  else
    "$PYTHON3" "$csv_generator" -c "$CONFIG_FILE_PATH" --mode closedloop --num-rows 4 --output-dir "$output_dir" >> "$csv_log" 2>&1; csv_exit=$((csv_exit + $?))
    "$PYTHON3" "$csv_generator" -c "$CONFIG_FILE_PATH" --mode mojaloop --num-rows 4 --output-dir "$output_dir" >> "$csv_log" 2>&1; csv_exit=$((csv_exit + $?))
  fi

  if [ "$csv_exit" -ne 0 ]; then
    log_warn "CSV generation failed — see $csv_log"
  else
    log_ok
  fi
}
