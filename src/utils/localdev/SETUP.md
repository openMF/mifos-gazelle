# Quick Setup Guide

## 📂 Directory Structure

```
mifos-gazelle/
└── src/
    └── utils/
        └── localdev/
            ├── README.md                    # Full documentation (you are here)
            ├── SETUP.md                     # This quick setup guide
            ├── localdev.py                  # Main patching script
            ├── localdev.ini                 # Configuration file
            ├── pre-commit                   # Git hook script
            └── install-git-protection.sh    # Hook installer
```

## ⚡ 5-Minute Setup

### Step 1: Navigate to Directory
```bash
cd ~/mifos-gazelle/src/utils/localdev
```


### Step 2: Configure Your Components
```bash
# Edit localdev.ini
nano localdev.ini

# Update these values:
# 1. Change 'gazelle-home' if your repo is not in $HOME/mifos-gazelle
# 2. Update 'hostpath' to YOUR local project directories
# 3. Verify 'jarpath' matches your actual JAR filenames
# 4. Enable checkout: set checkout_enabled = true
# 5. Add reponame: the GitHub repository URL
# 6. Set branch_or_tag: which branch to use (e.g., develop)
```

Example configuration:
```ini
[general]
gazelle-home = $HOME/mifos-gazelle

[bulk-processor]
directory = ${gazelle-home}/repos/ph_template/helm/ph-ee-engine/bulk-processor
image = openjdk:26-ea-17-jdk-trixie
jarpath = /app/build/libs/ph-ee-processor-bulk-gazelle-1.1.0.jar
hostpath = /home/yourusername/ph-ee-bulk-processor  # <-- CHANGE THIS
# Repository settings
checkout_enabled = true
reponame = https://github.com/openMF/ph-ee-bulk-processor.git
branch_or_tag = develop
checkout_to_dir = /home/yourusername  # <-- CHANGE THIS
```

### Step 4: Install Git Protection (Recommended)
```bash
./install-git-protection.sh
```

### Step 5: Test Configuration
```bash
# Check status of all components
./localdev.py --status
```

### Step 6: Complete Setup
```bash
# One command to checkout repos AND patch deployments
./localdev.py --setup

# Or do it step by step:
./localdev.py --checkout  # Clone repositories first
./localdev.py             # Then patch deployments

# Check that files are protected from git
./localdev.py --check-git-status
```

## ✅ Verify Setup

```bash
# Check overall status
./localdev.py --status

# Check that repositories were cloned
ls -la ~/  # Look for your component directories

# Check that backups were created
find ~/mifos-gazelle -name "deployment.yaml.backup"

# Check git protection
git ls-files -v | grep ^S | grep deployment.yaml

# Verify pre-commit hook is installed
ls -la ~/mifos-gazelle/.git/hooks/pre-commit

# Test a repository was checked out correctly
cd ~/ph-ee-bulk-processor  # Or your component name
git branch  # Should show configured branch
git remote -v  # Should show correct GitHub URL
```

## 🔄 Daily Usage

```bash
# 1. Make code changes in your project
cd ~/your-project
# ... edit files ...

# 2. Build
./gradlew clean build

# 3. Restart deployment
kubectl rollout restart deployment/your-component -n mifos

# 4. Watch logs
kubectl logs -f deployment/your-component -n mifos
```

## 🧹 Cleanup

```bash
# When done developing
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --restore
```

## 📖 Next Steps

- Read the full [README.md](README.md) for detailed documentation
- Run `./localdev.py --status` regularly to check your setup
- Use `./localdev.py --update` to pull latest changes from GitHub
- Configure additional components in `localdev.ini`
- Create shell aliases for common commands:
  ```bash
  alias ld-status='cd ~/mifos-gazelle/src/utils/localdev && ./localdev.py --status'
  alias ld-update='cd ~/mifos-gazelle/src/utils/localdev && ./localdev.py --update'
  alias ld-restore='cd ~/mifos-gazelle/src/utils/localdev && ./localdev.py --restore'
  ```

## 🆘 Quick Troubleshooting

| Issue | Solution |
|-------|----------|
| Repository not cloned | Check `checkout_enabled = true` in localdev.ini |
| Clone failed | Verify git credentials: `git config --list \| grep user` |
| Wrong branch | Run `./localdev.py --update --component NAME` |
| Changes not applied | `kubectl rollout restart deployment/NAME -n mifos` |
| Permission denied | `chmod 755 ~/project && chmod 644 ~/project/build/libs/*.jar` |
| Git shows modified files | `./localdev.py --check-git-status` then reapply protection |
| Hook not blocking commits | `chmod +x ~/.../mifos-gazelle/.git/hooks/pre-commit` |

## 📞 Getting Help

1. Check the full [README.md](README.md) - comprehensive troubleshooting section
2. Run with verbose output: `./localdev.py --dry-run --component NAME`
3. Verify configuration: `cat localdev.ini`
4. Check git status: `./localdev.py --check-git-status`

---

**Ready to start?** Follow the steps above, then refer to [README.md](README.md) for detailed usage instructions!