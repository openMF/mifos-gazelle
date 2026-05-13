#!/usr/bin/env bash
# phee.sh -- Mifos Gazelle deployer script for PaymentHub EE
#
# Deployment sequence:
#   1. deploy_ph_infra_helm  -- Helm --wait: Zeebe, operationsmysql, Redis, MinIO, Kafka into paymenthub ns
#   2. elastic + TLS secrets
#   3. deploy_ph_operator      -- CRD + operator pod + 10 PaymentHubDeployment CRs
#   4. wait_for_phee_crs_ready -- poll until all enabled CRs reach ready; zeebe-ops confirmed up
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
  delete_resources_in_namespace_matching_pattern "$PH_NAMESPACE"
  cleanup_phee_cluster_rbac
  manage_elastic_secrets delete "$INFRA_NAMESPACE"
  log_ok

  run_as_user "kubectl wait --for=condition=ready pod --all -n $VNEXT_NAMESPACE --timeout=600s" > /dev/null 2>&1

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
  deploy_ph_operator

  # Step 4 — wait for all CRs to reach ready; zeebe-ops pod confirmed running
  wait_for_phee_crs_ready

  # Step 5 — curl BPMN files directly to zeebe-ops via its ingress
  deploy_bpmns

  log_banner "Payment Hub EE Deployed"
}

#------------------------------------------------------------------------------
# Function : cleanup_phee_cluster_rbac
# Description: Removes cluster-scoped ClusterRoles and ClusterRoleBindings
#              left over from any previous PHEE Helm release (e.g. release-name
#              "phee"). These are not namespace-scoped so they survive namespace
#              deletion and block re-install under a different release name.
#------------------------------------------------------------------------------
cleanup_phee_cluster_rbac() {
  local resources
  resources=$(run_as_user "kubectl get clusterrole,clusterrolebinding -o json" 2>/dev/null \
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

  log_with_verbose_check "$debug" "$DEBUG" "Removing stale PHEE cluster RBAC from previous Helm release"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local kind name
    kind=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    run_as_user "kubectl delete $kind $name --ignore-not-found" > /dev/null 2>&1
  done <<< "$resources"
}

#------------------------------------------------------------------------------
# Function : deploy_ph_infra_helm
# Description: Deploys PHEE infrastructure services (Zeebe, operationsmysql,
#              Redis, MinIO, Kafka) into the paymenthub namespace via Helm.
#              App-layer components are disabled in values — operator owns them.
#------------------------------------------------------------------------------
deploy_ph_infra_helm() {
  local pheeEngineChartPath="$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/ph-ee-engine"
  local gazelleChartPath="$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/gazelle"

  # Clone the repo and apply domain substitution
  clone_repo "$PH_EE_ENV_TEMPLATE_REPO_BRANCH" "$PH_EE_ENV_TEMPLATE_REPO_LINK" "$APPS_DIR" "$PH_EE_ENV_TEMPLATE_REPO_DIR"

  log_step "Updating FQDNs in Helm chart values and manifests"
  apply_domain_to_file "$PH_VALUES_FILE" "$GAZELLE_DOMAIN"
  apply_domain_to_dir "$APPS_DIR/ph_template" "$GAZELLE_DOMAIN"
  log_ok

  ensure_helm_dependencies "$pheeEngineChartPath"
  ensure_helm_dependencies "$gazelleChartPath"

  local helm_cmd="helm upgrade --install $PH_INFRA_RELEASE_NAME $gazelleChartPath -n $PH_NAMESPACE --wait --timeout 1200s"
  if [ -n "$PH_VALUES_FILE" ]; then
    helm_cmd="$helm_cmd -f $PH_VALUES_FILE"
  fi

  log_step "Helm install ($PH_INFRA_RELEASE_NAME) — PHEE infra services"
  log_with_verbose_check "$debug" "$DEBUG" "→ $helm_cmd"

  if [ "$debug" = true ]; then
    su - "$k8s_user" -c "bash -c '$helm_cmd'"
    install_exit_code=$?
  else
    output=$(su - "$k8s_user" -c "bash -c '$helm_cmd'" 2>&1)
    install_exit_code=$?
  fi

  su - "$k8s_user" -c "helm status $PH_INFRA_RELEASE_NAME -n $PH_NAMESPACE" > /tmp/helm_status_output 2>&1

  if grep -q "^STATUS: deployed" /tmp/helm_status_output; then
    log_ok
    return 0
  else
    log_failed "Helm release '$PH_INFRA_RELEASE_NAME' did not reach deployed status"
    return 1
  fi
}

#------------------------------------------------------------------------------
# Function : deploy_ph_operator
# Description: Applies the CRD, deploys the operator pod, then applies the
#              11 PaymentHubDeployment CRs with the Gazelle domain substituted
#              into Ingress hostnames.
#------------------------------------------------------------------------------
# Function : write_operator_deployment_local
# Description: Outputs a complete Deployment YAML for the operator in local-dev
#              mode — eclipse-temurin:21 image, java -jar command, hostPath
#              volume mounting the operator source directory at /app.
#              Requires `./gradlew build -x test` (Shadow fat-jar) first.
# Parameters:
#   $1 - operator source directory (hostPath on the node)
#   $2 - JAR filename (e.g. ph-ee-operator-1.0.0.jar)
#------------------------------------------------------------------------------
write_operator_deployment_local() {
  local src_dir="$1"
  local jar_name="$2"
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
	          image: eclipse-temurin:21
	          imagePullPolicy: IfNotPresent
	          command: ["java", "-jar", "/app/build/libs/${jar_name}"]
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
	          volumeMounts:
	            - name: local-operator
	              mountPath: /app
	      volumes:
	        - name: local-operator
	          hostPath:
	            path: ${src_dir}
	            type: Directory
	YAML
}

#------------------------------------------------------------------------------
# Function : write_operator_deployment_image
# Description: Outputs a complete Deployment YAML for the operator in image
#              mode — uses the published Docker image with its own ENTRYPOINT.
# Parameters:
#   $1 - operator Docker image (e.g. openmf/phee-operator:1.0.0)
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
deploy_ph_operator() {
  local deploy_dir="$RUN_DIR/src/deployer/operators/phee"
  local jar_name="ph-ee-operator-1.0.0.jar"

  log_step "Applying PHEE CRD"
  run_as_user "kubectl apply -f $deploy_dir/config/crd/ph-ee-CustomResourceDefinition.yaml" || { log_failed "CRD apply failed"; return 1; }
  run_as_user "kubectl wait --for=condition=Established crd/paymenthubdeployments.gazelle.mifos.io --timeout=60s"
  log_ok

  # Resolve local operator source dir — expand $HOME / ~ to the actual user home
  local operator_src_dir=""
  if [ -n "$PHEE_OPERATOR_SOURCE_DIR" ]; then
    operator_src_dir="${PHEE_OPERATOR_SOURCE_DIR/\$HOME/$k8s_user_home}"
    operator_src_dir="${operator_src_dir/#\~/$k8s_user_home}"
  fi

  # Apply RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding, Role, RoleBinding).
  # Deployment is applied separately below based on mode — never applied here.
  log_step "Applying PHEE operator RBAC"
  run_as_user "kubectl apply -f $deploy_dir/operator_rbac.yaml -n $PH_NAMESPACE" || { log_failed "Operator RBAC apply failed"; return 1; }
  log_ok

  # Determine deployment mode and generate the correct Deployment manifest.
  local dep_manifest
  dep_manifest=$(mktemp /tmp/phee-op-dep.XXXXXX.yaml)
  chmod 644 "$dep_manifest"

  if [ -n "$operator_src_dir" ] && [ -d "$operator_src_dir" ]; then
    # Local mode selected (PHEE_OPERATOR_SOURCE_DIR set and directory exists).
    # Fat JAR (Shadow) must be built before running deploy.
    if [ ! -f "$operator_src_dir/build/libs/$jar_name" ]; then
      log_failed "Local operator JAR not found: $operator_src_dir/build/libs/$jar_name"
      log_failed "Build it first:  cd $operator_src_dir && ./gradlew build -x test"
      rm -f "$dep_manifest"; return 1
    fi
    log_step "Deploying PHEE operator (local JAR + hostPath)"
    write_operator_deployment_local "$operator_src_dir" "$jar_name" > "$dep_manifest"
  else
    # Image mode — PHEE_OPERATOR_SOURCE_DIR not set or directory absent.
    log_step "Deploying PHEE operator ($PHEE_OPERATOR_IMAGE)"
    write_operator_deployment_image "$PHEE_OPERATOR_IMAGE" > "$dep_manifest"
  fi

  run_as_user "kubectl apply -f $dep_manifest" || { log_failed "Operator Deployment apply failed"; rm -f "$dep_manifest"; return 1; }
  rm -f "$dep_manifest"

  if ! run_as_user "kubectl rollout status deployment/ph-ee-operator -n $PH_NAMESPACE --timeout=300s"; then
    log_warn "Operator pod did not start — check: kubectl logs deployment/ph-ee-operator -n $PH_NAMESPACE"
  else
    log_ok
  fi

  # Apply CRs — the operator reconciles them once running.
  log_step "Applying PaymentHubDeployment CRs"
  local cr_rendered
  cr_rendered=$(mktemp /tmp/phee-crs.XXXXXX.yaml)
  chmod 644 "$cr_rendered"
  generate_phee_crs > "$cr_rendered"
  run_as_user "kubectl apply -f $cr_rendered" || { log_failed "CR apply failed"; rm -f "$cr_rendered"; return 1; }
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
  local cr_dir="$RUN_DIR/src/deployer/operators/phee/config/cr"
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
#              namespace report status.ready == true, or until STARTUP_TIMEOUT.
#------------------------------------------------------------------------------
wait_for_phee_crs_ready() {
  local timeout="${STARTUP_TIMEOUT:-600}"
  local elapsed=0
  local interval=30

  log_step "Waiting for all PHEE CRs to become ready"

  while [ "$elapsed" -lt "$timeout" ]; do
    local cr_output
    cr_output=$(run_as_user "kubectl get paymenthubdeployments -n $PH_NAMESPACE \
      -o jsonpath='{range .items[?(@.spec.enabled==true)]}{.metadata.name}:{.status.ready} {end}'" 2>/dev/null \
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

  log_failed "Timed out after ${timeout}s waiting for PHEE CRs. Check: kubectl get paymenthubdeployments -n $PH_NAMESPACE"
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

  # The operator marks the CR ready when K8s resources are created, not when the
  # Spring Boot pod passes its readiness probe. Wait for the pod to be genuinely
  # ready (readiness probe passes) before attempting uploads.
  log_with_verbose_check "$debug" "$DEBUG" "Waiting for zeebe-ops pod to be ready..."
  if ! kubectl wait pod \
      --for=condition=ready \
      --selector=app=ph-ee-zeebe-ops \
      --namespace=paymenthub \
      --timeout=300s 2>/dev/null; then
    log_warn "zeebe-ops pod did not become ready after 300s — upload may fail"
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
    ES_URL="http://elasticsearch.$GAZELLE_DOMAIN"
    INDEX="zeebe-record_process_*"

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

    > /tmp/phee-csv-gen.log

    local csv_exit=0
    if [ "$debug" == "true" ]; then
        run_as_user "\"$PYTHON3\" \"$csv_generator\" -c \"$CONFIG_FILE_PATH\" --mode closedloop --num-rows 4 --output-dir \"$output_dir\"" 2>&1 | tee -a /tmp/phee-csv-gen.log; csv_exit=$((csv_exit + ${PIPESTATUS[0]}))
        run_as_user "\"$PYTHON3\" \"$csv_generator\" -c \"$CONFIG_FILE_PATH\" --mode mojaloop --num-rows 4 --output-dir \"$output_dir\"" 2>&1 | tee -a /tmp/phee-csv-gen.log; csv_exit=$((csv_exit + ${PIPESTATUS[0]}))
    else
        run_as_user "\"$PYTHON3\" \"$csv_generator\" -c \"$CONFIG_FILE_PATH\" --mode closedloop --num-rows 4 --output-dir \"$output_dir\"" >> /tmp/phee-csv-gen.log 2>&1; csv_exit=$((csv_exit + $?))
        run_as_user "\"$PYTHON3\" \"$csv_generator\" -c \"$CONFIG_FILE_PATH\" --mode mojaloop --num-rows 4 --output-dir \"$output_dir\"" >> /tmp/phee-csv-gen.log 2>&1; csv_exit=$((csv_exit + $?))
    fi

    if [ "$csv_exit" -ne 0 ]; then
        log_warn "CSV generation failed — see /tmp/phee-csv-gen.log"
    else
        log_ok
    fi
}
