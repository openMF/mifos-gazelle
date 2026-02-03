# Local Development Tools for Mifos Payment Hub EE

## 📋 Summary

This directory contains tools to streamline local development of Java components in the Mifos Payment Hub EE (deployed via Helm charts to a k3s Kubernetes cluster). The tools allow you to:

- **Automatically checkout** component repositories from GitHub
- **Rapidly iterate** on Java code without rebuilding/publishing Docker containers
- **Mount local code** directly into Kubernetes pods using hostPath volumes
- **Automatically protect** against accidentally committing local dev changes to git
- **Easily switch** between development and production configurations

**The Problem:** Normally, testing Java changes requires: cloning repos → building a JAR → creating a Docker image → pushing to registry → updating Helm charts → redeploying. This is slow and cumbersome for local development.

**The Solution:** Automatically checkout the repositories you need, mount your local project directories directly into the Kubernetes pods, and build JARs locally that are immediately available in your cluster.

---

## 🚀 Quick Start

### 1. Initial Setup

```bash
# Navigate to this directory
cd mifos-gazelle/src/utils/localdev

# Install git protection 
# only needed if you are pushing to Mifos Repos => so you don't accidentally push dev charts to github but not required 
# if you are not actively developin against Mifos Repos => then skip this step.
./install-git-protection.sh
```

### 2. Configure Your Components

Edit `localdev.ini` and add your components:

```ini
[general]
gazelle-home = $HOME/mifos-gazelle

[bulk-processor]
directory = ${gazelle-home}/repos/ph_template/helm/ph-ee-engine/bulk-processor
image = openjdk:26-ea-17-jdk-trixie
jarpath = /app/build/libs/ph-ee-processor-bulk-gazelle-1.1.0.jar
hostpath = /home/yourusername/ph-ee-bulk-processor
# Enable automatic repository checkout
checkout_enabled = true
reponame = https://github.com/openMF/ph-ee-bulk-processor.git
branch_or_tag = develop
checkout_to_dir = /home/yourusername

[operations-app]
directory = ${gazelle-home}/repos/ph_template/helm/ph-ee-engine/operations-app
image = openjdk:26-ea-17-jdk-trixie
jarpath = /app/build/libs/operations-app.jar
hostpath = /home/yourusername/ph-ee-operations-app
checkout_enabled = true
reponame = https://github.com/openMF/ph-ee-operations-app.git
branch_or_tag = develop
checkout_to_dir = /home/yourusername
```

### 3. Complete Setup (Checkout + Patch)

```bash
# One command to do everything: checkout repos AND patch deployments
./localdev.py --setup

# Or check status first
./localdev.py --status

# Or do it step by step:
./localdev.py --checkout  # Clone repositories
./localdev.py             # Patch Deployment.yaml => implement hostpath 
```

### 4. Develop, Build, and Test

```bash
# Make code changes in your local project
cd ~/ph-ee-bulk-processor

# Build the JAR
./gradlew clean build

# Restart the pod to pick up changes
kubectl rollout restart deployment/ph-ee-bulk-processor -n paymenthub

# View logs
kubectl logs -f deployment/ph-ee-bulk-processor -n paymenthub
```

### 5. Restore Original Configuration

```bash
# When done developing, restore all components
./localdev.py --restore

# Or restore just one
./localdev.py --restore --component bulk-processor
```

---

## 📁 Files in This Directory

| File | Purpose |
|------|---------|
| `localdev.py` | Main Python script that patches Helm deployment files |
| `localdev.ini` | Configuration file defining components and their settings |
| `pre-commit` | Git hook to prevent accidentally committing dev changes |
| `install-git-protection.sh` | Installs the pre-commit hook |
| `README.md` | This file |

---

## 🔧 Detailed Usage

### localdev.py Command Reference

```bash
# Show help
./localdev.py --help

# Show status of all components (repos + deployments)
./localdev.py --status

# Complete setup: checkout + patch (recommended for first time)
./localdev.py --setup

# Setup specific component
./localdev.py --setup --component bulk-processor

# Checkout all repositories (components with checkout_enabled=true)
./localdev.py --checkout

# Checkout specific repository
./localdev.py --checkout --component bulk-processor

# Update existing repos (pull latest changes)
./localdev.py --update

# Update specific repo
./localdev.py --update --component bulk-processor

# Dry run - preview what will change
./localdev.py --dry-run

# Patch all components in localdev.ini
./localdev.py

# Patch specific component
./localdev.py --component bulk-processor

# Check git protection status
./localdev.py --check-git-status

# Restore all components from backups
./localdev.py --restore

# Restore specific component
./localdev.py --restore --component operations-app

# Use custom config file
./localdev.py --config /path/to/custom.ini
```

### Repository Management

The tool can automatically manage component repositories for you:

**Enable checkout in localdev.ini:**
```ini
[your-component]
# ... other settings ...
checkout_enabled = true
reponame = https://github.com/openMF/your-repo.git
branch_or_tag = develop
checkout_to_dir = /home/username
```

**Checkout workflow:**
- `--checkout`: Clones repositories if they don't exist
- `--update`: Pulls latest changes for existing repositories
- `--setup`: Checkouts + patches in one command

**Repository URL formats:**
- HTTPS: `https://github.com/openMF/repo.git`
- SSH: `git@github.com:openMF/repo.git`

**Branch/Tag options:**
- Branch name: `develop`, `main`, `feature/xyz`
- Tag: `v1.2.3`, `release-2024`
- Commit SHA: `abc123def456`

### What the Script Does

When you run `./localdev.py`, it modifies each configured component's `deployment.yaml` to:

1. **Replace the container image** with your specified JDK image (e.g., `openjdk:26-ea-17-jdk-trixie`)
2. **Comment out the original image** line for easy reference
3. **Add a hostPath volume** pointing to your local project directory
4. **Mount the volume** at `/app` in the container
5. **Set the command** to run your local JAR file
6. **Create a backup** of the original file (`deployment.yaml.backup`)
7. **Mark the file with git skip-worktree** to prevent accidental commits

### Example Transformation

**Before:**
```yaml
containers:
  - name: ph-ee-bulk-processor
    image: "{{ .Values.image }}"
    imagePullPolicy: "{{ .Values.imagePullPolicy }}"
```

**After:**
```yaml
containers:
  - name: ph-ee-bulk-processor
    image: "openjdk:26-ea-17-jdk-trixie"  # this is the JDK to use
    #image: "{{ .Values.image }}"  # commented out to allow hostpath local dev/test
    imagePullPolicy: "{{ .Values.imagePullPolicy }}"
    volumeMounts:
      - name: local-code
        mountPath: /app
    command: ["java", "-jar", "/app/build/libs/your-app.jar"]
volumes:
  - name: local-code
    hostPath:
      path: /home/username/your-project
      type: Directory
```

---

## 🛡️ Git Protection (Preventing Accidental Commits)

### Three Layers of Protection

#### 1. **Automatic Skip-Worktree**
When `localdev.py` patches files, it automatically marks them with `git update-index --skip-worktree`. This tells git to ignore your local changes.

Check status:
```bash
./localdev.py --check-git-status
```

Output:
```
🔒 Protected: bulk-processor
  File: /path/to/deployment.yaml
⚠️  Unprotected: operations-app
  File: /path/to/deployment.yaml
```

Manually manage skip-worktree:
```bash
# Protect a file
git update-index --skip-worktree path/to/deployment.yaml

# Unprotect a file
git update-index --no-skip-worktree path/to/deployment.yaml

# List all skip-worktree files
git ls-files -v | grep ^S
```

#### 2. **Pre-Commit Hook**
Install with `./install-git-protection.sh`. The hook scans commits for:
- `hostPath:` configurations
- Local filesystem paths (e.g., `/home/username/`)
- Dev comments like `# add this for local dev test`

If detected, the commit is **blocked** with helpful instructions.

#### 3. **Backup Files**
Original files are saved as `deployment.yaml.backup` so you can always restore:

```bash
./localdev.py --restore
```

### If You Need to Commit Intentionally

```bash
# Bypass the pre-commit hook (use with caution!)
git commit --no-verify

# Or temporarily remove skip-worktree
git update-index --no-skip-worktree path/to/file
git add path/to/file
git commit -m "Your message"
git update-index --skip-worktree path/to/file
```

---

## ⚙️ Configuration File Format

### localdev.ini Structure

```ini
[general]
gazelle-home = $HOME/mifos-gazelle

[component-name]
# Required deployment settings
directory = ${gazelle-home}/path/to/helm/chart
image = container-image:tag
jarpath = /app/path/to/your.jar
hostpath = /local/filesystem/path/to/project

# Optional repository checkout settings
checkout_enabled = true
reponame = https://github.com/org/repo.git
branch_or_tag = develop
checkout_to_dir = /home/username
```

### Configuration Parameters

| Parameter | Required | Description | Example |
|-----------|----------|-------------|---------|
| **[general]** | Yes | Global settings section | |
| `gazelle-home` | Yes | Root path to your gazelle repo | `$HOME/mifos-gazelle` |
| **[component-name]** | Yes | Section for each component | `[bulk-processor]` |
| `directory` | Yes | Path to Helm chart directory | `${gazelle-home}/helm/.../bulk-processor` |
| `image` | Yes | Container image with JDK to use | `openjdk:26-ea-17-jdk-trixie` |
| `jarpath` | Yes | Path to JAR inside container | `/app/build/libs/your-app.jar` |
| `hostpath` | Yes | Local project directory on host | `/home/username/ph-ee-bulk-processor` |
| `checkout_enabled` | No | Enable automatic repo checkout | `true` or `false` (default: false) |
| `reponame` | No* | Git repository URL | `https://github.com/openMF/repo.git` |
| `branch_or_tag` | No | Branch or tag to checkout | `develop` (default: `main`) |
| `checkout_to_dir` | No | Where to clone the repository | `/home/username` (default: `$HOME`) |

*Required if `checkout_enabled = true`

### Variable Expansion

The configuration supports:
- **Environment variables:** `$HOME`, `$USER`, etc.
- **Custom variables:** `${gazelle-home}` references `[general]` section

---

## 🔄 Typical Development Workflow

### Full Workflow Example

```bash
# 1. One-time setup
cd ~/mifos-gazelle/src/utils/localdev
./install-git-protection.sh
nano localdev.ini  # Configure your components

# 2. Check status to see what will happen
./localdev.py --status

# 3. Complete setup: checkout repos + patch deployments
./localdev.py --setup

# 4. Deploy/update your Helm charts
cd ~/mifos-gazelle
helm upgrade gazelle ./ph-ee-gazelle -n mifos

# 5. Make code changes
cd ~/ph-ee-bulk-processor  # This was checked out automatically
# Edit your Java files...

# 6. Build and test
./gradlew clean build
kubectl rollout restart deployment/ph-ee-bulk-processor -n mifos
kubectl logs -f deployment/ph-ee-bulk-processor -n mifos

# 7. Iterate (repeat steps 5-6 as needed)

# 8. Pull latest changes from upstream (if needed)
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --update --component bulk-processor

# 9. When done, restore original configuration
./localdev.py --restore

# 10. Redeploy with production config
cd ~/mifos-gazelle
helm upgrade gazelle ./ph-ee-gazelle -n mifos
```

### Quick Update Script

Create `~/bin/update-component.sh` for rapid iterations:

```bash
#!/bin/bash
set -e

COMPONENT=$1
NAMESPACE=${2:-mifos}

if [ -z "$COMPONENT" ]; then
    echo "Usage: $0 <component-name> [namespace]"
    exit 1
fi

echo "🔨 Building $COMPONENT..."
cd ~/$COMPONENT
./gradlew clean build

echo "🔄 Restarting deployment..."
kubectl rollout restart deployment/$COMPONENT -n $NAMESPACE
kubectl rollout status deployment/$COMPONENT -n $NAMESPACE

echo "📋 Showing logs..."
kubectl logs -f deployment/$COMPONENT -n $NAMESPACE
```

Usage:
```bash
chmod +x ~/bin/update-component.sh
update-component.sh ph-ee-bulk-processor
```

---

## 🐛 Troubleshooting

### Issue: Changes not taking effect

**Problem:** You rebuilt the JAR but the pod is still running old code.

**Solution:**
```bash
# Ensure the JAR was built in the right location
ls -lh ~/your-project/build/libs/

# Verify hostPath is correct in deployment
kubectl get deployment your-component -n mifos -o yaml | grep -A5 hostPath

# Restart the deployment
kubectl rollout restart deployment/your-component -n mifos

# Check pod logs for errors
kubectl logs deployment/your-component -n mifos
```

### Issue: Permission denied on hostPath

**Problem:** Pod can't read the JAR file from hostPath.

**Solution:**
```bash
# Make directory readable
chmod 755 ~/your-project

# Make JAR readable
chmod 644 ~/your-project/build/libs/*.jar

# Verify permissions
ls -la ~/your-project/build/libs/
```

### Issue: Git still shows modified files

**Problem:** `git status` shows deployment.yaml as modified despite skip-worktree.

**Solution:**
```bash
# Check skip-worktree status
./localdev.py --check-git-status

# Reapply skip-worktree
git update-index --skip-worktree path/to/deployment.yaml

# Verify
git ls-files -v | grep deployment.yaml
# Should show 'S' prefix if skip-worktree is active
```

### Issue: Pre-commit hook not working

**Problem:** Hook isn't blocking commits with hostPath.

**Solution:**
```bash
# Verify hook is installed and executable
ls -la ~/mifos-gazelle/.git/hooks/pre-commit

# Make it executable
chmod +x ~/mifos-gazelle/.git/hooks/pre-commit

# Test the hook manually
cd ~/mifos-gazelle
.git/hooks/pre-commit
```

### Issue: Pod fails to start

**Problem:** Pod is in CrashLoopBackOff after patching.

**Solution:**
```bash
# Check pod events
kubectl describe pod -l app=your-component -n mifos

# Check if JAR path is correct
kubectl logs deployment/your-component -n mifos

# Verify the JAR exists and is correct
kubectl exec deployment/your-component -n mifos -- ls -la /app/build/libs/

# Common issues:
# - Wrong JAR filename in command
# - JAR not in expected location
# - Permissions issue on hostPath
```

### Issue: Repository checkout failed

**Problem:** `./localdev.py --checkout` fails to clone repository.

**Solution:**
```bash
# Check your git credentials
git config --list | grep user

# For HTTPS repos, ensure you have access token configured
git config --global credential.helper store

# For SSH repos, ensure SSH key is configured
ssh -T git@github.com

# Check if reponame URL is correct in localdev.ini
cat localdev.ini | grep reponame

# Try cloning manually to test
git clone <reponame> /tmp/test-clone
```

### Issue: Repository on wrong branch

**Problem:** Repository exists but on different branch than configured.

**Solution:**
```bash
# Check current branch
cd ~/your-component
git branch

# Use --update to switch branches and pull
./localdev.py --update --component your-component

# Or manually switch
cd ~/your-component
git fetch --all
git checkout develop
git pull
```

---

## 📝 Best Practices

### DO ✅

- **Always use `--dry-run` first** to preview changes
- **Install git protection** before patching any files
- **Use descriptive component names** in localdev.ini
- **Keep backups** of your localdev.ini
- **Test in isolation** - patch one component at a time initially
- **Document your setup** - add notes about your local paths
- **Restore before committing** code changes to your Java projects

### DON'T ❌

- **Don't commit** patched deployment.yaml files
- **Don't delete** `.backup` files until you're sure patches work
- **Don't use in production** - this is for local development only
- **Don't share absolute paths** - use variables in localdev.ini
- **Don't patch shared environments** - only use on local k3s
- **Don't bypass git hooks** without careful consideration

---

## 🔍 Advanced Usage

### Multiple Configurations

Create different config files for different scenarios:

```bash
# Development config
./localdev.py --config localdev-dev.ini

# Testing config with different images
./localdev.py --config localdev-test.ini

# Minimal config for just one component
./localdev.py --config localdev-minimal.ini
```

### Selective Component Management

```bash
# Patch only critical components
./localdev.py --component bulk-processor
./localdev.py --component operations-app

# Leave others using production images

# Later, restore selectively
./localdev.py --restore --component bulk-processor
```

### Integration with IDEs

Configure your IDE to run gradle builds and trigger restarts:

**IntelliJ IDEA External Tool:**
```
Program: kubectl
Arguments: rollout restart deployment/$ComponentName$ -n mifos
Working directory: $ProjectFileDir$
```

**VS Code task.json:**
```json
{
  "label": "Deploy to k3s",
  "type": "shell",
  "command": "./gradlew clean build && kubectl rollout restart deployment/${component} -n mifos",
  "group": "build"
}
```

### Debugging with Remote JVM

Modify the command in localdev.ini to enable remote debugging:

```ini
# In your deployment after patching, manually add:
command: ["java", "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005", "-jar", "/app/build/libs/your.jar"]
```

Then port-forward and connect your debugger:
```bash
kubectl port-forward deployment/your-component 5005:5005 -n mifos
```

---

## 🤝 Contributing

If you improve these tools, consider:
1. Testing thoroughly in your local environment
2. Documenting your changes
3. Sharing improvements with the team
4. Adding examples to this README

---

## 📚 Additional Resources

- [Kubernetes Volumes Documentation](https://kubernetes.io/docs/concepts/storage/volumes/#hostpath)
- [Git Skip-Worktree](https://git-scm.com/docs/git-update-index#_skip_worktree_bit)
- [Helm Values Documentation](https://helm.sh/docs/chart_template_guide/values_files/)
- [k3s Documentation](https://docs.k3s.io/)

---

## ❓ FAQ

**Q: Will this work with multi-node Kubernetes clusters?**
A: HostPath is node-specific. For multi-node clusters, you'd need to either ensure pod scheduling on the correct node or use a shared filesystem like NFS.

**Q: Can I use this for multiple developers on the same cluster?**
A: Not recommended. HostPath points to local filesystem, so each developer should use their own cluster or namespace.

**Q: What if I want to use my custom base image instead of openjdk?**
A: Just change the `image` parameter in localdev.ini to your custom image. Make sure it has Java installed.

**Q: Does this work with Spring Boot DevTools hot reload?**
A: No, the JAR is not automatically reloaded. You need to rebuild and restart the pod.

**Q: Can I patch non-Java components?**
A: Yes! Adjust the `command` and `jarpath` to suit your runtime (e.g., Node.js, Python, etc.).

**Q: What happens if I run `helm upgrade` after patching?**
A: Helm will overwrite your patches. You'll need to re-run `localdev.py` after helm operations.

**Q: Do I need to manually clone repositories?**
A: No! Set `checkout_enabled = true` in localdev.ini and run `./localdev.py --setup`. It will automatically clone the repositories for you.

**Q: Can I use SSH URLs for repositories?**
A: Yes, both HTTPS and SSH URLs work. Just ensure your SSH keys are configured: `ssh -T git@github.com`

**Q: What if a repository already exists?**
A: The tool will detect existing repos and skip cloning. Use `--update` to pull latest changes.

**Q: Can I work on a different branch than configured?**
A: Yes, you can manually switch branches in your local repo. The tool only enforces the branch during checkout/update operations.

**Q: How do I update to the latest code from GitHub?**
A: Run `./localdev.py --update` to pull the latest changes for all configured repositories.

**Q: Can I checkout only some components?**
A: Yes! Set `checkout_enabled = false` for components you don't want to checkout, or use `--component` flag to target specific ones.

---

**Last Updated:** Nov 2025 
**Maintainer:** Mifos Development Team incuding [ tdaly61@gmail.com ]