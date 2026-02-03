#!/bin/bash
# Pre-commit hook to prevent accidentally committing local development configurations
# Install: cp pre-commit.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "🔍 Checking for local development configurations..."

# Get list of files being committed
FILES=$(git diff --cached --name-only --diff-filter=ACM)

if [ -z "$FILES" ]; then
    echo "✅ No files in commit"
    exit 0
fi

FOUND_LOCAL_CONFIG=0

for FILE in $FILES; do
    # Check deployment files for hostPath
    if echo "$FILE" | grep -qE 'deployment\.yaml$'; then
        # Check if file contains hostPath
        if git diff --cached "$FILE" | grep -q "hostPath:"; then
            echo -e "${RED}❌ ERROR: Found hostPath in $FILE${NC}"
            FOUND_LOCAL_CONFIG=1
        fi
        
        # Check for local development comments
        if git diff --cached "$FILE" | grep -q "# add this for local dev test"; then
            echo -e "${RED}❌ ERROR: Found local dev comments in $FILE${NC}"
            FOUND_LOCAL_CONFIG=1
        fi
        
        if git diff --cached "$FILE" | grep -q "# commented out to allow hostpath local dev"; then
            echo -e "${RED}❌ ERROR: Found local dev comments in $FILE${NC}"
            FOUND_LOCAL_CONFIG=1
        fi
        
        # Check for local paths like /home/username
        if git diff --cached "$FILE" | grep -qE "path: /home/[a-zA-Z0-9_-]+/"; then
            echo -e "${RED}❌ ERROR: Found local filesystem path in $FILE${NC}"
            FOUND_LOCAL_CONFIG=1
        fi
    fi
    
    # Check ALL files for localhost domain
    if git diff --cached "$FILE" | grep -qi "mifos\.gazelle\.localhost"; then
        echo -e "${RED}❌ ERROR: Found mifos.gazelle.localhost in $FILE${NC}"
        FOUND_LOCAL_CONFIG=1
    fi
done

if [ $FOUND_LOCAL_CONFIG -eq 1 ]; then
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  COMMIT BLOCKED: Local development changes detected   ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}These files contain local development configurations:${NC}"
    echo ""
    
    for FILE in $FILES; do
        SHOW_FILE=0
        if echo "$FILE" | grep -qE 'deployment\.yaml$'; then
            if git diff --cached "$FILE" | grep -q "hostPath:"; then
                SHOW_FILE=1
            elif git diff --cached "$FILE" | grep -q "# add this for local dev test"; then
                SHOW_FILE=1
            elif git diff --cached "$FILE" | grep -q "# commented out to allow hostpath local dev"; then
                SHOW_FILE=1
            fi
            
            if [ $SHOW_FILE -eq 1 ]; then
                echo "  • $FILE (hostPath/local dev comments)"
            fi
        fi
        
        if git diff --cached "$FILE" | grep -qi "mifos\.gazelle\.localhost"; then
            echo "  • $FILE (contains mifos.gazelle.localhost)"
        fi
    done
    
    echo ""
    echo -e "${YELLOW}To fix this:${NC}"
    echo ""
    echo "  1. Restore original files:"
    echo "     ./localdev.py --restore"
    echo ""
    echo "  2. Or unstage these files:"
    echo "     git reset HEAD <file>"
    echo ""
    echo "  3. Or verify files are marked with skip-worktree:"
    echo "     ./localdev.py --check-git-status"
    echo ""
    echo "  4. For localhost domains, replace with production domains"
    echo ""
    echo "  5. If you really need to commit these changes (careful!):"
    echo "     git commit --no-verify"
    echo ""
    exit 1
fi

echo "✅ No local development configurations found - commit allowed"
exit 0