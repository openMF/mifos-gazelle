#!/usr/bin/env bash
# start-fresh.sh -- wipes everything, rebuilds from scratch, deploys all DPGs,
# and tests that they actually work. Run as your normal user; it sudos itself
# where needed. Driven entirely by config/config.ini -- no flags.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

CONFIG="config/config.ini"
get() { crudini --get "$CONFIG" "$1" "$2" 2>/dev/null || echo "${3:-}"; }

k8s_user="${USER:-$(id -un)}"
node_host="$(get multinode NODE_HOST)"
node_user="$(get multinode NODE_SSH_USER "$k8s_user")"
[[ "$node_user" == '$USER' ]] && node_user="$k8s_user"

echo "==> Pulling latest code"
git pull

echo "==> Wiping everything (full teardown)"
sudo ./setup-env.sh -m cleanall -u "$k8s_user" -y

if [[ -n "$node_host" ]]; then
    echo "==> Cleaning 2nd node's old k3s agent"
    ssh -o StrictHostKeyChecking=accept-new "$node_user@$node_host" \
        'sudo /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true'
fi

echo "==> Rebuilding environment from scratch"
sudo ./setup-env.sh -u "$k8s_user" -y

if [[ -n "$node_host" ]]; then
    echo "==> Joining 2nd node"
    sudo ./setup-env.sh -m join -N "$node_host" -U "$node_user" -r openg2p -u "$k8s_user"
fi

echo "==> Deploying the 3 core DPGs"
./run.sh -m deploy -a all

echo "==> Testing: endpoints respond"
src/utils/test-scripts/verify-endpoints.sh

echo "==> Testing: a real payment goes through"
echo "50" | src/utils/make-payment.sh -v

if [[ "$(get openg2p enabled false)" == "true" ]]; then
    echo "==> Deploying openg2p"
    ./run.sh -m deploy -a openg2p
    echo "==> Testing: openg2p works"
    src/utils/openg2p/openg2p-data-setup.sh
fi

if [[ "$(get openspp enabled false)" == "true" ]]; then
    echo "==> Deploying openspp"
    ./run.sh -m deploy -a openspp
    echo "==> Testing: openspp works"
    demos/openspp/run_demo.sh
    demos/openspp/run_credit_demo.sh
fi

echo "==> All done -- everything deployed and tested."
