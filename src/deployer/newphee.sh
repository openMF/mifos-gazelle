#!/usr/bin/env bash
# newphee.sh -- Mifos Gazelle deployer script for newphee

#------------------------------------------------------------------------------
# Function : deploy_newphee
# Description: Deploys the newphee component using the operator pattern.
#------------------------------------------------------------------------------
deploy_newphee() {
    log_section "Deploying newphee"

    if is_app_running "$NEWPHEE_NAMESPACE"; then
        if [[ "$redeploy" == "false" ]]; then
            echo "    newphee already deployed — skipping."
            return 0
        fi
    fi

    log_step "Removing existing newphee resources"
    delete_resources_in_namespace_matching_pattern "$NEWPHEE_NAMESPACE"
    log_ok

    log_step "Creating namespace $NEWPHEE_NAMESPACE"
    create_namespace "$NEWPHEE_NAMESPACE"
    check_command_execution $? "create_namespace $NEWPHEE_NAMESPACE"
    log_ok

    log_step "Deploying newphee operator"
    local operator_dir="$RUN_DIR/src/deployer/operators/newphee"
    run_as_user "bash \"$operator_dir/deploy-operator.sh\" -c \"$CONFIG_FILE_PATH\" deploy"
    check_command_execution $? "deploy newphee operator"
    log_ok

    log_step "Applying newphee custom resource"
    run_as_user "kubectl apply -f \"$operator_dir/config/samples/newphee-default.yaml\" -n \"$NEWPHEE_NAMESPACE\""
    check_command_execution $? "kubectl apply newphee CR"
    log_ok

    log_step "Waiting for newphee to be ready"
    run_as_user "kubectl wait --for=condition=ready pod --all -n \"$NEWPHEE_NAMESPACE\" --timeout=${startup_timeout}s" > /dev/null 2>&1 || true
    log_ok

    log_banner "newphee Deployed"
}

#------------------------------------------------------------------------------
# Function : teardown_newphee
# Description: Removes all newphee resources from the cluster.
#------------------------------------------------------------------------------
teardown_newphee() {
    log_section "Removing newphee"

    log_step "Removing newphee resources"
    delete_resources_in_namespace_matching_pattern "$NEWPHEE_NAMESPACE"
    log_ok

    log_step "Removing newphee operator"
    local operator_dir="$RUN_DIR/src/deployer/operators/newphee"
    run_as_user "bash \"$operator_dir/deploy-operator.sh\" -c \"$CONFIG_FILE_PATH\" undeploy" || true
    log_ok

    log_banner "newphee Removed"
}

#------------------------------------------------------------------------------
# Function : status_newphee
# Description: Reports pod status for the newphee namespace.
#------------------------------------------------------------------------------
status_newphee() {
    log_section "newphee Status"
    run_as_user "kubectl get pods -n \"$NEWPHEE_NAMESPACE\""
    run_as_user "kubectl get newphees -n \"$NEWPHEE_NAMESPACE\"" 2>/dev/null || true
}
