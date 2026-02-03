#!/bin/bash
# Install git protection for local development for paymenthub EE
# assumes mifos gazelle deployment layout 
# currently installs a githook to prevent committing mods to local charts
# that are explicitly for local dev/test such as mods to templates/deployment.yaml files
# that contain hostpath
set -e

# Directory this script is in i.e. <directory>/mifos-gazelle/src/utils/localdev
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" 

# Navigate to ph_template repo directory
PH_EE_ENV_TEMPLATE_REPO_DIR="$( cd "$(dirname "$SCRIPT_DIR")/../../repos/ph_template" ; pwd )"

echo "📂 REPOS dir is $PH_EE_ENV_TEMPLATE_REPO_DIR"

# Verify it's actually a git repository
if [ ! -d "$PH_EE_ENV_TEMPLATE_REPO_DIR/.git" ]; then
    echo "❌ Error: $PH_EE_ENV_TEMPLATE_REPO_DIR is not a git repository"
    echo "Expected .git directory at: $PH_EE_ENV_TEMPLATE_REPO_DIR/.git"
    exit 1
fi

echo "🔧 Installing Git Protection for Local Development"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Install pre-commit hook
HOOK_SOURCE="$SCRIPT_DIR/pre-commit.sh"

if [ -f "$HOOK_SOURCE" ]; then
    HOOK_PATH="$PH_EE_ENV_TEMPLATE_REPO_DIR/.git/hooks/pre-commit"
    
    # Backup existing hook if present
    if [ -f "$HOOK_PATH" ]; then
        echo "📦 Backing up existing pre-commit hook..."
        cp "$HOOK_PATH" "$HOOK_PATH.backup.$(date +%s)"
    fi
    
    echo "📥 Installing pre-commit hook..."
    echo "   Source: $HOOK_SOURCE"
    echo "   Target: $HOOK_PATH"
    
    cp "$HOOK_SOURCE" "$HOOK_PATH"
    chmod +x "$HOOK_PATH"
    
    echo "✅ Pre-commit hook installed: $HOOK_PATH"
    
    # Verify installation
    if [ -f "$HOOK_PATH" ] && [ -x "$HOOK_PATH" ]; then
        echo "✅ Hook verified: exists and is executable"
    else
        echo "⚠️  Warning: Hook may not be properly installed"
    fi
else
    echo "⚠️  pre-commit.sh not found at: $HOOK_SOURCE"
    echo "   Please ensure pre-commit.sh exists in the localdev directory"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Installation Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Your repository now has protection against accidentally committing"
echo "hostPath configurations from local development."
echo ""
echo "Installed hook location:"
echo "  $HOOK_PATH"
echo ""
echo "Usage:"
echo "  1. Patch deployments: ./localdev.py"
echo "  2. Check protection:  ./localdev.py --check-git-status"
echo "  3. Restore original:  ./localdev.py --restore"
echo ""
echo "The pre-commit hook will block commits containing:"
echo "  • hostPath: configurations"
echo "  • Local filesystem paths"
echo "  • Local development comments"
echo ""
echo "Test the hook:"
echo "  cd $PH_EE_ENV_TEMPLATE_REPO_DIR"
echo "  .git/hooks/pre-commit"
echo ""