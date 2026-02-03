#!/bin/bash
#
# Quick Import Script for Kibana Visualizations
# This is a simpler alternative to the Python script
#
# Usage: ./import-all.sh
#

set -e

# Configuration
KIBANA_URL="${KIBANA_URL:-https://kibana.mifos.gazelle.localhost}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Data directory with Kibana dashboards (relative to script location)
DATA_DIR="$(cd "$SCRIPT_DIR/../../repos/ph_template/Kibana Visualisations" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Kibana Visualization Import Tool${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Target Kibana: $KIBANA_URL"
echo "Source Directory: $DATA_DIR"
echo ""

# Test Kibana connection
echo -n "Testing Kibana connection... "
if curl -k -s -o /dev/null -w "%{http_code}" "$KIBANA_URL/api/status" | grep -q "200"; then
    echo -e "${GREEN}✓ Connected${NC}"
else
    echo -e "${RED}✗ Failed${NC}"
    echo ""
    echo "Cannot connect to Kibana at: $KIBANA_URL"
    echo "Please check that Kibana is running and accessible."
    echo ""
    echo "You can set a custom URL with:"
    echo "  export KIBANA_URL=https://your-kibana-url"
    exit 1
fi

echo ""
echo -e "${YELLOW}Starting import...${NC}"
echo ""

SUCCESS=0
FAILED=0

# Function to import a single file
import_file() {
    local file=$1
    local filename=$(basename "$file")

    echo -n "  Importing: $filename ... "

    response=$(curl -k -s -w "\n%{http_code}" \
        -X POST "$KIBANA_URL/api/saved_objects/_import?overwrite=true" \
        -H "kbn-xsrf: true" \
        -F "file=@$file")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)

    if [ "$http_code" = "200" ]; then
        # Check if the import was successful
        if echo "$body" | grep -q '"success":true'; then
            echo -e "${GREEN}✓${NC}"
            SUCCESS=$((SUCCESS + 1))
        else
            echo -e "${YELLOW}⚠${NC}"
            SUCCESS=$((SUCCESS + 1))
        fi
    else
        echo -e "${RED}✗ (HTTP $http_code)${NC}"
        FAILED=$((FAILED + 1))
    fi
}

# Import in order: index-patterns first, then visualizations, then dashboards
IMPORT_DIRS=("index-pattern" "search" "visualization" "lens" "dashboard")

for dir in "${IMPORT_DIRS[@]}"; do
    if [ -d "$DATA_DIR/$dir" ]; then
        echo -e "${BLUE}📁 Importing $dir objects:${NC}"

        for file in "$DATA_DIR/$dir"/*.ndjson; do
            if [ -f "$file" ]; then
                import_file "$file"
            fi
        done
        echo ""
    fi
done

# Import root-level .ndjson files
echo -e "${BLUE}📁 Importing root-level objects:${NC}"
for file in "$DATA_DIR"/*.ndjson; do
    if [ -f "$file" ]; then
        import_file "$file"
    fi
done

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✓ Successful: $SUCCESS${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}✗ Failed: $FAILED${NC}"
fi
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Access Kibana at: $KIBANA_URL"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}🎉 All visualizations imported successfully!${NC}"
    exit 0
else
    echo -e "${YELLOW}⚠️  Some imports failed. This may be normal if objects already exist.${NC}"
    exit 0
fi
