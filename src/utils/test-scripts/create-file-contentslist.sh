#!/usr/bin/env bash

# Script to collect non-excluded source files from specified directories
# and output them (with contents) for uploading to Grok or other AI sessions.

set -euo pipefail

# Defaults
DRY_RUN=0
OUTPUT_FILE="grok-upload-contents.txt"
DEFAULT_TARGET_DIRS=(
  "mifos-gazelle"
  "ph-ee-bulk-processor"
  "ph-ee-connector-mock-payment-schema"
  "ph-ee-connector-channel"
  "ph-ee-id-account-validator-impl"
  "ph-ee-connector-mojaloop-java"
  "ph-ee-identity-account-mapper"
)

# Arrays for exclusions
EXCLUDED_DIRS=(
  "target" "build" "lib" ".git" "charts" ".harness" "phlabs"
  "PostmanCollections" "Keycloak" "Kibana Visualisations"
  "vnext" "ph-ee-integration-test" ".gradle"
)

EXCLUDED_PATTERNS=(
  "pycache" "app.cpython-311.pyc" "__pycache__" ".cache"
  ".png$" "jpg" "pdf" "htmx.min.js" "css"
  ".class$" ".jar$" ".war$" ".ear$" ".bin$"
  ".tgz$" ".sql$" ".gz$" ".py"
)

usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS] [DIRECTORY...]

Collects source files (excluding binaries, build artifacts, etc.) from specified
directories and writes them to an output file suitable for pasting into Grok.

Options:
  -d, --dry-run           Only list files that would be included (no contents)
  -o, --output FILE       Output file (default: grok-upload-contents.txt)
  -h, --help              Show this help message and exit

Arguments:
  DIRECTORY...            One or more directories to scan.
                          If none provided, uses default list:
                            ${DEFAULT_TARGET_DIRS[*]}

Examples:
  $(basename "$0")                              # Use default directories
  $(basename "$0") src config                   # Only scan 'src' and 'config'
  $(basename "$0") --dry-run                    # Dry run on defaults
  $(basename "$0") -o my-project.txt ph-ee-*    # Custom output + glob dirs
  $(basename "$0") -d -o preview.txt src        # Dry run to custom file

EOF
  exit 0
}

# Parse options with getopts
while getopts "do:h-:" opt; do
  case "${opt}" in
    d)
      DRY_RUN=1
      ;;
    o)
      OUTPUT_FILE="${OPTARG}"
      ;;
    h)
      usage
      ;;
    -)
      case "${OPTARG}" in
        dry-run)
          DRY_RUN=1
          ;;
        output)
          OUTPUT_FILE="${!OPTIND}"; OPTIND=$(( OPTIND + 1 ))
          ;;
        help)
          usage
          ;;
        *)
          echo "Unknown long option: --${OPTARG}" >&2
          usage
          ;;
      esac
      ;;
    \?)
      echo "Invalid option: -${OPTARG}" >&2
      usage
      ;;
    :)
      echo "Option -${OPTARG} requires an argument." >&2
      usage
      ;;
  esac
done
shift $((OPTIND-1))

# Use provided directories or defaults
if [[ $# -gt 0 ]]; then
  TARGET_DIRS=("$@")
  echo "🔍 Using custom target directories: ${TARGET_DIRS[*]}"
else
  TARGET_DIRS=("${DEFAULT_TARGET_DIRS[@]}")
  echo "🔍 Using default target directories: ${TARGET_DIRS[*]}"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "--- 🚀 DRY RUN MODE ACTIVE: Only listing files (no contents) ---"
fi

echo "📄 Output will be written to: $OUTPUT_FILE"
echo ""

# Truncate output file
> "$OUTPUT_FILE"

# Build prune command
PRUNE_COMMAND=""
for dir in "${EXCLUDED_DIRS[@]}"; do
  [[ -n "$PRUNE_COMMAND" ]] && PRUNE_COMMAND+=" -o "
  PRUNE_COMMAND+="-name \"$dir\""
done

if [[ -n "$PRUNE_COMMAND" ]]; then
  PRUNE_COMMAND="\( -type d \( $PRUNE_COMMAND \) \) -prune"
fi

# Build grep pattern
GREP_PATTERNS=$(IFS="|"; echo "${EXCLUDED_PATTERNS[*]}")

# Build target string
TARGET_STRING="${TARGET_DIRS[*]}"

if [[ -z "$TARGET_STRING" ]]; then
  echo "❌ No target directories specified." >&2
  exit 1
fi

# Build find command
find_command="find $TARGET_STRING ${PRUNE_COMMAND:+-} ${PRUNE_COMMAND} -o -type f -print 2>/dev/null"

echo "🔍 Scanning directories..."
echo ""

# Execute and write to output file
eval "$find_command" | while IFS= read -r file; do
  # Skip if matches excluded patterns
  if [[ -n "$GREP_PATTERNS" ]] && echo "$file" | grep -E "$GREP_PATTERNS" >/dev/null; then
    continue
  fi

  # Write to both stdout (for feedback) and output file
  echo "FILE: $file"
  echo "FILE: $file" >> "$OUTPUT_FILE"

  if [[ $DRY_RUN -eq 0 ]]; then
    # echo '###FILE IS NOT A BINARY - HERE IS THE CONTENTS###'
    # echo '###FILE IS NOT A BINARY - HERE IS THE CONTENTS###' >> "$OUTPUT_FILE"
    cat "$file" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
  fi
done

echo ""
echo "✅ Done! Output written to: $OUTPUT_FILE"
echo "   You can now copy-paste the contents of this file into Grok."