#!/bin/bash

set -e

# === Default Config ===
MODE=""
NAMESPACE="infra"
LABEL_SELECTOR="app.kubernetes.io/name=mongodb"
MONGO_USER="root"
MONGO_PW=""
AUTH_DB="admin"
DUMP_FILE="/tmp/mongodump.gz"
COPY_TO_LOCAL=false
COPY_FROM_LOCAL=false

usage() {
  echo ""
  echo "Usage: $0 -m <dump|restore|delete> -p <password> [options]"
  echo ""
  echo "Required:"
  echo "  -m <mode>            Operation mode: 'dump', 'restore', or 'delete'"
  echo "  -p <password>        MongoDB root password"
  echo ""
  echo "Optional:"
  echo "  -n <namespace>       Kubernetes namespace (default: infra)"
  echo "  -l <label>           Pod label selector (default: app.kubernetes.io/name=mongodb)"
  echo "  -u <username>        MongoDB username (default: root)"
  echo "  -f <dumpfile>        Dump file path (default: /tmp/mongodump.gz)"
  echo "  --copy-to-local      Copy dump from pod to ./mongodump.gz after dump"
  echo "  --copy-from-local    Copy ./mongodump.gz to pod before restore"
  echo "  -h                   Show this help"
  echo ""
  echo "Examples:"
  echo "  Dump and copy to local:"
  echo "    $0 -m dump -p mongoDbPas42 --copy-to-local"
  echo ""
  echo "  Restore from local file:"
  echo "    $0 -m restore -p mongoDbPas42 --copy-from-local"
  echo ""
  echo "  Delete all user databases:"
  echo "    $0 -m delete -p mongoDbPas42"
  echo ""
  exit 1
}

# === Parse args ===
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m) MODE="$2"; shift 2 ;;
    -n) NAMESPACE="$2"; shift 2 ;;
    -l) LABEL_SELECTOR="$2"; shift 2 ;;
    -u) MONGO_USER="$2"; shift 2 ;;
    -p) MONGO_PW="$2"; shift 2 ;;
    -f) DUMP_FILE="$2"; shift 2 ;;
    --copy-to-local) COPY_TO_LOCAL=true; shift ;;
    --copy-from-local) COPY_FROM_LOCAL=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# === Validate required ===
if [[ -z "$MODE" || -z "$MONGO_PW" ]]; then
  echo "❌ Error: -m <mode> and -p <password> are required"
  usage
fi

# === Locate MongoDB Pod ===
echo "🔍 Locating MongoDB pod in namespace '$NAMESPACE' with label '$LABEL_SELECTOR'..."
PODS=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [[ -z "$PODS" ]]; then
  echo "⚠️  No pods found with label '$LABEL_SELECTOR'. Trying fallback by pod name..."
  POD=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep mongo | head -n 1)
  if [[ -z "$POD" ]]; then
    echo "❌ Still no pod found. Check your namespace and label selector."
    echo "Hint: run 'kubectl get pods -n $NAMESPACE --show-labels'"
    exit 1
  fi
  echo "✅ Fallback matched pod: $POD"
else
  POD=$(echo "$PODS" | awk '{print $1}')
  echo "✅ Found MongoDB Pod: $POD"
fi

# === Handle Modes ===
if [[ "$MODE" == "dump" ]]; then
  echo "📦 Creating dump inside pod..."
  kubectl exec -n "$NAMESPACE" "$POD" -- bash -c "
    mongodump -u $MONGO_USER -p '$MONGO_PW' --authenticationDatabase $AUTH_DB \
              --gzip --archive=$DUMP_FILE
  "
  echo "✅ Dump complete: $DUMP_FILE in pod"

  if $COPY_TO_LOCAL; then
    echo "📥 Copying dump to local machine..."
    kubectl cp "$NAMESPACE/$POD:$DUMP_FILE" ./mongodump.gz
    echo "✅ Local dump saved as ./mongodump.gz"
  fi

elif [[ "$MODE" == "restore" ]]; then
  if $COPY_FROM_LOCAL; then
    echo "📤 Copying local dump to pod..."
    kubectl cp ./mongodump.gz "$NAMESPACE/$POD:$DUMP_FILE"
  fi

  echo "♻️  Restoring dump inside pod..."
  kubectl exec -n "$NAMESPACE" "$POD" -- bash -c "
    mongorestore -u $MONGO_USER -p '$MONGO_PW' --authenticationDatabase $AUTH_DB \
                 --gzip --archive=$DUMP_FILE
  "
  echo "✅ Restore complete from $DUMP_FILE"

elif [[ "$MODE" == "delete" ]]; then
  echo "🧨 Dropping all user databases (except admin/local/config)..."
  kubectl exec -n "$NAMESPACE" "$POD" -- mongo -u "$MONGO_USER" -p "$MONGO_PW" --authenticationDatabase "$AUTH_DB" --quiet --eval '
    db.adminCommand("listDatabases").databases
      .forEach(function(d) {
        var name = d.name;
        if (["admin", "local", "config"].indexOf(name) === -1) {
          print("Dropping DB: " + name);
          db.getSiblingDB(name).dropDatabase();
        }
      });
  '
  echo "✅ All non-system databases dropped."

else
  echo "❌ Invalid mode: $MODE"
  usage
fi
