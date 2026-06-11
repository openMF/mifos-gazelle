#!/usr/bin/env python3
"""
localdev.py - Patches Helm chart Deployment.yaml files for local development
Modifies deployments to use hostPath volumes and custom images for rapid iteration
Also handles checking out GitHub repositories for components
"""

import configparser
import os
import re
import subprocess
from pathlib import Path
from typing import Dict, Optional, Tuple
import sys


class LocalDevPatcher:
    def __init__(self, config_path: Optional[Path] = None):
        """Initialize the patcher with configuration from localdev.ini"""
        if config_path is None:
            # Get config from localdev.ini in same directory as this script
            script_dir = Path(__file__).parent
            config_path = script_dir / "localdev.ini"
        
        self.config_path = config_path.resolve()
        self.config = self._load_config()
        self.gazelle_home = Path(os.path.expandvars(self.config['general']['gazelle-home']))
    
    def _load_config(self) -> configparser.ConfigParser:
        """Load and parse the INI configuration file"""
        if not self.config_path.exists():
            raise FileNotFoundError(f"Config file not found: {self.config_path}")
        
        config = configparser.ConfigParser()
        config.read(self.config_path)
        return config
    
    def _expand_vars(self, value: str) -> str:
        """Expand variables like ${gazelle-home} in config values"""
        # First expand environment variables like $HOME
        value = os.path.expandvars(value)
        
        # Then expand custom variables like ${gazelle-home}
        pattern = r'\$\{([^}]+)\}'
        matches = re.findall(pattern, value)
        
        for match in matches:
            if match in self.config['general']:
                replacement = os.path.expandvars(self.config['general'][match])
                value = value.replace(f'${{{match}}}', replacement)
        
        return value
    
    def get_components(self) -> list:
        """Get list of components to patch from config file"""
        return [section for section in self.config.sections() if section != 'general']
    
    def _is_operator_running_locally(self) -> bool:
        """Check if the PHEE operator is running as a local process."""
        try:
            result = subprocess.run(
                ['pgrep', '-f', 'com.paymenthub.OperatorMain'],
                capture_output=True, text=True
            )
            return result.returncode == 0
        except Exception:
            return False

    def run_operator(self) -> None:
        """Run the PaymentHub operator locally against the cluster via ./gradlew run."""
        if 'paymenthub-operator' not in self.config:
            print("❌ [paymenthub-operator] section not found in localdev.ini")
            return

        comp_config = self.config['paymenthub-operator']
        operator_dir_str = comp_config.get('operator_dir', '')
        if not operator_dir_str:
            print("❌ 'operator_dir' not set in [paymenthub-operator]")
            return

        operator_dir = Path(self._expand_vars(operator_dir_str))

        if not operator_dir.exists():
            print(f"❌ Operator directory not found: {operator_dir}")
            print("  Run first:  ./localdev.py --checkout --component paymenthub-operator")
            return

        if not (operator_dir / 'gradlew').exists():
            print(f"❌ gradlew not found in {operator_dir} — is the repo fully checked out?")
            return

        kubeconfig = os.environ.get('KUBECONFIG', str(Path.home() / '.kube' / 'config'))

        print(f"\n{'═' * 60}")
        print(f"  Running PaymentHub Operator locally")
        print(f"{'═' * 60}")
        print(f"  Directory : {operator_dir}")
        print(f"  KUBECONFIG: {kubeconfig}")
        print()
        print("  ⚠️  Scale down the in-cluster operator first to avoid dual reconcilers:")
        print("     kubectl scale deployment paymenthub-operator -n paymenthub --replicas=0")
        print()

        # Apply CRD if not already installed
        crd_file = operator_dir / 'deploy' / 'crds' / 'ph-ee-CustomResourceDefinition.yaml'
        if crd_file.exists():
            result = subprocess.run(
                ['kubectl', 'get', 'crd', 'paymenthubdeployments.gazelle.mifos.io'],
                capture_output=True, text=True
            )
            if result.returncode != 0:
                print("  Applying CRD (paymenthubdeployments.gazelle.mifos.io)...")
                subprocess.run(['kubectl', 'apply', '-f', str(crd_file)], check=True)
                subprocess.run(
                    ['kubectl', 'wait', '--for=condition=Established',
                     'crd/paymenthubdeployments.gazelle.mifos.io', '--timeout=30s'],
                    check=True
                )
                print("  CRD ready.")
        else:
            print(f"  ⚠️  CRD file not found at {crd_file} — skipping auto-apply")

        print("  Press Ctrl+C to stop\n")

        try:
            subprocess.run(
                ['./gradlew', 'run'],
                cwd=operator_dir,
                env={**os.environ, 'KUBECONFIG': kubeconfig}
            )
        except KeyboardInterrupt:
            print("\n\nOperator stopped.")
        except FileNotFoundError:
            print("❌ ./gradlew not found — check operator_dir in localdev.ini")

    def _git_skip_worktree(self, file_path: Path, enable: bool = True) -> bool:
        """
        Mark a file to be ignored by git (skip-worktree)
        This prevents accidentally committing local dev changes
        """
        try:
            # Check if we're in a git repo
            result = subprocess.run(
                ['git', 'rev-parse', '--git-dir'],
                cwd=file_path.parent,
                capture_output=True,
                text=True
            )
            if result.returncode != 0:
                return False
            
            # Apply skip-worktree
            action = '--skip-worktree' if enable else '--no-skip-worktree'
            result = subprocess.run(
                ['git', 'update-index', action, str(file_path.name)],
                cwd=file_path.parent,
                capture_output=True,
                text=True
            )
            
            if result.returncode == 0:
                status = "protected from git" if enable else "unprotected"
                print(f"  🔒 File {status}: {file_path.name}")
                return True
            else:
                print(f"  ⚠️  Warning: Could not set git skip-worktree: {result.stderr.strip()}")
                return False
                
        except FileNotFoundError:
            print(f"  ⚠️  Git not found - skipping git protection")
            return False
        except Exception as e:
            print(f"  ⚠️  Git protection error: {e}")
            return False
    
    def check_git_status(self, component: Optional[str] = None) -> None:
        """Check which deployment files are marked with skip-worktree"""
        components = [component] if component else self.get_components()
        
        print(f"\n{'=' * 60}")
        print(f"Git Skip-Worktree Status")
        print(f"{'=' * 60}\n")
        
        for comp in components:
            if comp not in self.config:
                continue
                
            comp_config = self.config[comp]
            if 'directory' not in comp_config:
                continue
            directory = Path(self._expand_vars(comp_config['directory']))
            deployment_file = directory / "templates" / "deployment.yaml"

            if not deployment_file.exists():
                continue
            
            try:
                result = subprocess.run(
                    ['git', 'ls-files', '-v', str(deployment_file.name)],
                    cwd=deployment_file.parent,
                    capture_output=True,
                    text=True
                )
                
                if result.returncode == 0 and result.stdout:
                    # 'S' prefix means skip-worktree is set
                    status = "🔒 Protected" if result.stdout.startswith('S') else "⚠️  Unprotected"
                    print(f"{status}: {comp}")
                    print(f"  File: {deployment_file}")
                    
            except Exception as e:
                print(f"❌ Error checking {comp}: {e}")
        
        print(f"\n{'=' * 60}\n")
    
    def _run_git_command(self, cmd: list, cwd: Path) -> Tuple[bool, str]:
        """Run a git command and return success status and output"""
        try:
            result = subprocess.run(
                cmd,
                cwd=cwd,
                capture_output=True,
                text=True,
                check=False
            )
            return result.returncode == 0, result.stdout.strip() if result.returncode == 0 else result.stderr.strip()
        except Exception as e:
            return False, str(e)
    
    def _get_current_branch(self, repo_path: Path) -> Optional[str]:
        """Get the current branch of a git repository"""
        success, output = self._run_git_command(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], repo_path)
        return output if success else None
    
    def _repo_exists(self, repo_path: Path) -> bool:
        """Check if a directory is a git repository"""
        if not repo_path.exists():
            return False
        success, _ = self._run_git_command(['git', 'rev-parse', '--git-dir'], repo_path)
        return success
    
    def checkout_component(self, component: str, update: bool = False) -> bool:
        """
        Checkout or update a component's repository
        
        Args:
            component: Name of the component
            update: If True, pull latest changes for existing repos
        
        Returns:
            True if successful, False otherwise
        """
        if component not in self.config:
            print(f"❌ Component '{component}' not found in config")
            return False
        
        comp_config = self.config[component]
        
        # Check if checkout is enabled for this component
        if 'checkout_enabled' not in comp_config or comp_config['checkout_enabled'].lower() != 'true':
            print(f"⏭️  Skipping {component} - checkout not enabled")
            return True
        
        # Get configuration
        if 'reponame' not in comp_config:
            print(f"❌ Missing 'reponame' for {component}")
            return False
        
        reponame = comp_config['reponame']
        branch_or_tag = comp_config.get('branch_or_tag', 'main')
        checkout_to_dir = self._expand_vars(comp_config.get('checkout_to_dir', str(Path.home())))
        
        # Determine repository name from URL
        repo_name = reponame.rstrip('/').split('/')[-1].replace('.git', '')
        repo_path = Path(checkout_to_dir) / repo_name
        
        print(f"\n{'Processing' if not update else 'Updating'} {component}...")
        print(f"  📦 Repository: {reponame}")
        print(f"  🌿 Branch/Tag: {branch_or_tag}")
        print(f"  📁 Target: {repo_path}")
        
        # Check if repo already exists
        if self._repo_exists(repo_path):
            if update:
                print(f"  🔄 Repository exists, updating...")
                
                # Fetch latest
                success, output = self._run_git_command(['git', 'fetch', '--all'], repo_path)
                if not success:
                    print(f"  ⚠️  Warning: Failed to fetch: {output}")
                
                # Check current branch
                current_branch = self._get_current_branch(repo_path)
                print(f"  📍 Current branch: {current_branch}")
                
                # Checkout desired branch/tag if different
                if current_branch != branch_or_tag:
                    print(f"  🔀 Switching to {branch_or_tag}...")
                    success, output = self._run_git_command(['git', 'checkout', branch_or_tag], repo_path)
                    if not success:
                        print(f"  ❌ Failed to checkout {branch_or_tag}: {output}")
                        return False
                
                # Pull latest changes
                success, output = self._run_git_command(['git', 'pull'], repo_path)
                if success:
                    print(f"  ✅ Updated successfully")
                else:
                    print(f"  ⚠️  Warning: Failed to pull: {output}")
                
                return True
            else:
                print(f"  ℹ️  Repository already exists at {repo_path}")
                print(f"  💡 Use --update to pull latest changes")
                return True
        
        # Clone the repository
        print(f"  📥 Cloning repository...")
        
        # Ensure parent directory exists
        Path(checkout_to_dir).mkdir(parents=True, exist_ok=True)
        
        # Clone with specific branch
        clone_cmd = ['git', 'clone', '--branch', branch_or_tag, reponame, str(repo_path)]
        success, output = self._run_git_command(clone_cmd, Path(checkout_to_dir))
        
        if success:
            print(f"  ✅ Cloned successfully")
            return True
        else:
            print(f"  ❌ Clone failed: {output}")
            return False
    
    def checkout_all(self, update: bool = False):
        """Checkout all components with checkout_enabled = true"""
        components = self.get_components()
        enabled_components = [
            c for c in components 
            if c in self.config and 
            self.config[c].get('checkout_enabled', '').lower() == 'true'
        ]
        
        if not enabled_components:
            print("\n⚠️  No components have checkout_enabled = true")
            print("Update your localdev.ini to enable checkout for components")
            return
        
        print(f"\n{'=' * 60}")
        print(f"{'Checking out' if not update else 'Updating'} {len(enabled_components)} component(s)")
        print(f"{'=' * 60}")
        
        success_count = 0
        for component in enabled_components:
            if self.checkout_component(component, update):
                success_count += 1
        
        print(f"\n{'=' * 60}")
        print(f"✅ Successfully processed {success_count}/{len(enabled_components)} components")
        print(f"{'=' * 60}\n")
    
    def setup_component(self, component: str) -> bool:
        """Complete setup: checkout + patch for a component"""
        print(f"\n{'=' * 60}")
        print(f"Setting up {component}")
        print(f"{'=' * 60}")
        
        # First checkout if enabled
        if component in self.config and self.config[component].get('checkout_enabled', '').lower() == 'true':
            if not self.checkout_component(component, update=False):
                print(f"\n❌ Checkout failed for {component}")
                return False
        
        # Then patch
        if not self.patch_deployment(component, dry_run=False):
            print(f"\n❌ Patch failed for {component}")
            return False
        
        print(f"\n✅ Setup complete for {component}")
        return True
    
    def setup_all(self):
        """Complete setup: checkout + patch all components"""
        components = self.get_components()
        
        print(f"\n{'=' * 60}")
        print(f"Complete Setup for {len(components)} component(s)")
        print(f"{'=' * 60}")
        
        # First checkout all enabled repos
        self.checkout_all(update=False)
        
        # Then patch all deployments
        print(f"\n{'=' * 60}")
        print(f"Patching Deployments")
        print(f"{'=' * 60}")
        
        success_count = 0
        for component in components:
            if self.patch_deployment(component, dry_run=False):
                success_count += 1
        
        print(f"\n{'=' * 60}")
        print(f"✅ Complete setup finished: {success_count}/{len(components)} components")
        print(f"{'=' * 60}\n")
    
    def _visual_ljust(self, s: str, width: int) -> str:
        """Left-justify to terminal display width, treating wide emoji as 2 chars."""
        import unicodedata
        vis_w = 0
        for ch in s:
            eaw = unicodedata.east_asian_width(ch)
            if eaw in ('W', 'F'):
                vis_w += 2
            elif unicodedata.category(ch) in ('Mn', 'Me', 'Cf'):
                vis_w += 0  # combining / variation-selector chars (e.g. U+FE0F after ⚠)
            else:
                vis_w += 1
        return s + ' ' * max(0, width - vis_w)

    def status_all(self):
        """Show compact table status of all components."""
        components = self.get_components()

        # Fetch live cluster images once: deploy_name -> (full_image, tag)
        k8s_images = {}
        try:
            result = subprocess.run(
                ['kubectl', 'get', 'deployments', '-n', 'paymenthub', '-o',
                 'jsonpath={range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{"\\n"}{end}'],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                for line in result.stdout.strip().splitlines():
                    if '=' in line:
                        name, image = line.split('=', 1)
                        image = image.strip()
                        tag = image.split(':')[-1] if ':' in image else image
                        k8s_images[name.strip()] = (image, tag)
        except Exception:
            pass

        backup_dir = Path.home() / '.localdev-backups'

        patchable_rows = []
        checkout_rows  = []
        operator_rows  = []

        for component in components:
            if component not in self.config:
                continue
            comp_config = self.config[component]

            # ── Repo column ───────────────────────────────────────────────────
            if comp_config.get('checkout_enabled', '').lower() == 'true':
                checkout_to_dir = self._expand_vars(comp_config.get('checkout_to_dir', str(Path.home())))
                reponame = comp_config.get('reponame', '')
                repo_name = reponame.rstrip('/').split('/')[-1].replace('.git', '')
                repo_path = Path(checkout_to_dir) / repo_name
                expected = comp_config.get('branch_or_tag', 'main')
                if self._repo_exists(repo_path):
                    current = self._get_current_branch(repo_path)
                    co_col = f"✅ {current}" if current == expected else f"⚠️  {current} (want {expected})"
                else:
                    co_col = "❌ not cloned"
            else:
                co_col = "—"

            # ── Cluster column ────────────────────────────────────────────────
            is_patched = False
            app_type = comp_config.get('app_type', '')

            if app_type == 'operator':
                deploy_name = comp_config.get('k8s_deploy_name', '')
                is_patched = False
                if deploy_name:
                    backup_file = backup_dir / f"{component}-deployment.json"
                    if backup_file.exists():
                        cluster_col = "🔧 LOCAL  (hostpath JAR)"
                        is_patched = True
                    elif deploy_name in k8s_images:
                        full_image, tag = k8s_images[deploy_name]
                        # eclipse-temurin base image means it's running a local JAR via hostPath
                        if 'eclipse-temurin' in full_image or 'temurin' in full_image:
                            cluster_col = f"🔧 in-cluster (hostpath JAR)"
                            is_patched = True
                        else:
                            cluster_col = f"image  {tag}"
                    else:
                        cluster_col = "not in cluster"
                else:
                    running = self._is_operator_running_locally()
                    cluster_col = "🟢 running locally" if running else "not running"
                operator_rows.append({'name': component, 'co': co_col, 'cluster': cluster_col, 'is_patched': is_patched})
                continue

            deploy_name = comp_config.get('k8s_deploy_name', '')
            if deploy_name:
                backup_file = backup_dir / f"{component}-deployment.json"
                in_cluster = deploy_name in k8s_images
                app_type_comp = comp_config.get('app_type', 'springboot')
                live_image = k8s_images[deploy_name][0] if in_cluster else ''
                live_is_hostpath = (
                    'eclipse-temurin' in live_image or
                    'temurin' in live_image
                )
                # For webapps: only treat as hostpath if the live image is NOT a
                # registry image (i.e. the operator hasn't reconciled it back yet).
                # A backup + registry image = stale backup from a previous patch
                # that was overwritten by a redeploy.
                if app_type_comp == 'webapp':
                    live_is_hostpath = live_is_hostpath  # webapps never use temurin anyway
                live_hostpath = in_cluster and live_is_hostpath

                # Detect stale backup: backup exists but operator already replaced
                # the deployment with a registry image (not a local JAR image).
                backup_is_stale = backup_file.exists() and in_cluster and not live_hostpath

                if backup_file.exists() and live_hostpath:
                    cluster_col = "🔧 LOCAL  (hostpath JAR)"
                    is_patched = True
                elif backup_is_stale:
                    _, tag = k8s_images[deploy_name]
                    cluster_col = f"image  {tag}  (stale backup — run --clean-backups)"
                elif backup_file.exists() and in_cluster:
                    _, tag = k8s_images[deploy_name]
                    cluster_col = f"⚠️  reverted → image  {tag}"
                elif backup_file.exists():
                    cluster_col = "⚠️  reverted → not deployed"
                elif in_cluster:
                    _, tag = k8s_images[deploy_name]
                    cluster_col = f"image  {tag}"
                else:
                    cluster_col = "not deployed"
                patchable_rows.append({'name': component, 'co': co_col, 'cluster': cluster_col, 'is_patched': is_patched})
            else:
                checkout_rows.append({'name': component, 'co': co_col})

        all_named = patchable_rows + checkout_rows + operator_rows
        W      = 72
        name_w = max((len(r['name']) for r in all_named), default=12) + 2
        co_w   = 22

        print(f"\n{'═' * W}")
        print(f"  Local Dev Status")
        print(f"{'═' * W}")

        def divider(label=''):
            if label:
                fill = '─' * max(0, W - len(label) - 6)
                print(f"\n  ── {label} {fill}")
            else:
                print(f"  {'─' * (W - 4)}")

        # Patchable components table
        divider('k8s-direct  (patchable)')
        print(f"  {'COMPONENT':<{name_w}}  {'REPO':<{co_w}}  CLUSTER")
        divider()
        for r in patchable_rows:
            print(f"  {self._visual_ljust(r['name'], name_w)}  {self._visual_ljust(r['co'], co_w)}  {r['cluster']}")

        # Checkout-only
        divider('checkout only')
        print(f"  {'COMPONENT':<{name_w}}  REPO")
        divider()
        for r in checkout_rows:
            print(f"  {self._visual_ljust(r['name'], name_w)}  {r['co']}")

        # Operator
        if operator_rows:
            divider('operator')
            print(f"  {'COMPONENT':<{name_w}}  {'REPO':<{co_w}}  STATUS")
            divider()
            for r in operator_rows:
                print(f"  {self._visual_ljust(r['name'], name_w)}  {self._visual_ljust(r['co'], co_w)}  {r['cluster']}")

        print(f"\n{'═' * W}\n")

    def clean_backups(self) -> None:
        """Remove backup files left over from localdev patches that have since been
        overwritten by a full redeploy (operator reconciliation replaced the patched
        Deployment with a registry image)."""
        backup_dir = Path.home() / '.localdev-backups'
        if not backup_dir.exists():
            print("  ✅ No backup directory found — nothing to clean")
            return

        # Fetch live cluster images once
        k8s_images: dict = {}
        try:
            result = subprocess.run(
                ['kubectl', 'get', 'deployments', '-n', 'paymenthub', '-o',
                 'jsonpath={range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{"\\n"}{end}'],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                for line in result.stdout.strip().splitlines():
                    if '=' in line:
                        name, image = line.split('=', 1)
                        k8s_images[name.strip()] = image.strip()
        except Exception:
            pass

        removed = []
        kept = []
        for backup_file in sorted(backup_dir.glob('*-deployment.json')):
            component = backup_file.stem.replace('-deployment', '')
            comp_config = self.config.get(component, {})
            deploy_name = comp_config.get('k8s_deploy_name', '')
            if deploy_name and deploy_name in k8s_images:
                live_image = k8s_images[deploy_name]
                is_stale = 'eclipse-temurin' not in live_image and 'temurin' not in live_image
                if is_stale:
                    backup_file.unlink()
                    removed.append(f"{component} (live: {live_image.split('/')[-1]})")
                else:
                    kept.append(component)
            else:
                # Pod not running — backup may or may not be stale; leave it
                kept.append(f"{component} (not in cluster — kept)")

        if removed:
            for r in removed:
                print(f"  🗑  Removed stale backup: {r}")
        if kept:
            for k in kept:
                print(f"  ✅ Kept active backup: {k}")
        if not removed and not kept:
            print("  ✅ No backup files found")

    def patch_deployment(self, component: str, dry_run: bool = False) -> bool:
        """
        Patch the Deployment.yaml for a given component

        Args:
            component: Name of the component section in config
            dry_run: If True, only show what would be changed without modifying files

        Returns:
            True if successful, False otherwise
        """
        if component not in self.config:
            print(f"❌ Component '{component}' not found in config")
            return False

        comp_config = self.config[component]

        # The operator itself — run it locally, don't patch anything
        if comp_config.get('app_type', '') == 'operator':
            print(f"\n⏭️  Skipping {component} - this IS the operator (nothing to patch)")
            print(f"  ℹ️  Run it locally with: ./localdev.py --run")
            return True

        # Operator-managed components with k8s_deploy_name → patch running Deployment directly
        if 'directory' not in comp_config:
            if comp_config.get('k8s_deploy_name'):
                return self._patch_k8s_deployment(component, dry_run)
            print(f"\n⏭️  Skipping {component} - managed by PHEE operator (no Helm chart)")
            print(f"  ℹ️  Add k8s_deploy_name/hostpath/jarpath to localdev.ini to enable direct-patch mode")
            print(f"  ℹ️  Or run the operator locally: ./localdev.py --run")
            return True

        # Get component configuration
        directory = Path(self._expand_vars(comp_config['directory']))
        app_type = comp_config.get('app_type', 'springboot')  # Default to springboot for backward compatibility
        image = comp_config.get('image', '')  # Optional for webapp type
        jarpath = comp_config.get('jarpath', '')  # Optional for webapp type
        hostpath = self._expand_vars(comp_config['hostpath'])

        # For webapp type, we'll patch the template directly (no JAR path needed)
        # Skip only if we don't have the required hostpath
        if app_type == 'webapp' and not hostpath:
            print(f"❌ Webapp component '{component}' requires 'hostpath' in config")
            return False

        deployment_file = directory / "templates" / "deployment.yaml"
        backup_file = deployment_file.parent / f"_deployment.yaml.backup"
        
        if not deployment_file.exists():
            print(f"❌ Deployment file not found: {deployment_file}")
            return False
        
        # Check if backup already exists - if so, skip patching
        if backup_file.exists():
            print(f"\n⏭️  Skipping {component}...")
            print(f"  ℹ️  Backup already exists: {backup_file.name}")
            print(f"  ℹ️  Component appears to be already patched")
            print(f"  💡 Use --restore first if you want to re-patch")
            return True
        
        print(f"\n{'[DRY RUN] ' if dry_run else ''}Processing {component}...")
        print(f"  📁 File: {deployment_file}")
        print(f"  📦 App Type: {app_type}")
        if app_type == 'springboot':
            print(f"  🖼️  Image: {image}")
            print(f"  📦 JAR: {jarpath}")
        print(f"  🔗 Host Path: {hostpath}")
        
        # Read the deployment file
        with open(deployment_file, 'r') as f:
            content = f.read()
        
        # Backup original if not in dry-run mode
        if not dry_run:
            if not backup_file.exists():
                with open(backup_file, 'w') as f:
                    f.write(content)
                print(f"  💾 Backup created: {backup_file.name}")
            else:
                # This shouldn't happen due to earlier check, but just in case
                print(f"  ℹ️  Using existing backup: {backup_file.name}")
        
        # Apply patches
        modified_content = self._apply_patches(content, image, jarpath, hostpath, component, app_type)
        
        if dry_run:
            print(f"  ℹ️  Would modify deployment (dry run)")
        else:
            with open(deployment_file, 'w') as f:
                f.write(modified_content)
            print(f"  ✅ Deployment patched successfully")
            
            # Protect file from accidental git commits
            self._git_skip_worktree(deployment_file, enable=True)
        
        return True

    def _patch_k8s_deployment(self, component: str, dry_run: bool = False) -> bool:
        """
        Patch a running Kubernetes Deployment directly for operator-managed components.
        Fetches current Deployment, saves backup, adds hostPath volume + volumeMount,
        overrides image and command, then kubectl applies the modified manifest.
        """
        import json as _json

        comp_config = self.config[component]
        k8s_deploy_name = comp_config['k8s_deploy_name']
        k8s_namespace = comp_config.get('k8s_namespace', 'paymenthub')
        image = comp_config.get('image', '')
        jarpath = comp_config.get('jarpath', '')
        hostpath = self._expand_vars(comp_config.get('hostpath', ''))
        app_type = comp_config.get('app_type', 'springboot')

        backup_dir = Path.home() / '.localdev-backups'
        backup_file = backup_dir / f"{component}-deployment.json"

        if backup_file.exists():
            print(f"\n⏭️  Skipping {component} - already k8s-patched")
            print(f"  ℹ️  Backup: {backup_file}")
            print(f"  💡 Use --restore first to re-patch")
            return True

        print(f"\n{'[DRY RUN] ' if dry_run else ''}Processing {component} (k8s direct-patch)...")
        print(f"  📦 Deployment : {k8s_deploy_name}  ns: {k8s_namespace}")
        if app_type == 'springboot':
            print(f"  🖼️  Image      : {image}")
            print(f"  📦 JAR        : {jarpath}")
        print(f"  🔗 Host Path  : {hostpath}")

        result = subprocess.run(
            ['kubectl', 'get', 'deployment', k8s_deploy_name, '-n', k8s_namespace, '-o', 'json'],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"  ❌ Failed to get deployment: {result.stderr.strip()}")
            return False

        try:
            deployment = _json.loads(result.stdout)
        except _json.JSONDecodeError as e:
            print(f"  ❌ Failed to parse deployment JSON: {e}")
            return False

        if not dry_run:
            backup_dir.mkdir(parents=True, exist_ok=True)
            with open(backup_file, 'w') as f:
                _json.dump(deployment, f, indent=2)
            print(f"  💾 Backup saved: {backup_file}")

        # Strip server-side fields that cause apply conflicts
        deployment.pop('status', None)
        meta = deployment.get('metadata', {})
        for field in ('resourceVersion', 'uid', 'creationTimestamp', 'generation', 'managedFields'):
            meta.pop(field, None)
        meta.get('annotations', {}).pop('kubectl.kubernetes.io/last-applied-configuration', None)
        meta.setdefault('annotations', {})['localdev.gazelle.mifos.io/patched'] = 'true'

        containers = deployment['spec']['template']['spec'].get('containers', [])
        if not containers:
            print(f"  ❌ No containers found in deployment")
            if backup_file.exists():
                backup_file.unlink()
            return False
        container = containers[0]

        if app_type == 'springboot':
            if image:
                container['image'] = image
            if jarpath:
                container['command'] = ['java', '-jar', jarpath]
                container.pop('args', None)

            mounts = container.setdefault('volumeMounts', [])
            container['volumeMounts'] = [v for v in mounts if v.get('name') != 'local-code']
            container['volumeMounts'].append({'name': 'local-code', 'mountPath': '/app'})

            spec = deployment['spec']['template']['spec']
            vols = spec.setdefault('volumes', [])
            spec['volumes'] = [v for v in vols if v.get('name') != 'local-code']
            spec['volumes'].append({
                'name': 'local-code',
                'hostPath': {'path': hostpath, 'type': 'Directory'}
            })

        elif app_type == 'webapp':
            # Mount local dist/ over nginx html root — keep original image and command
            mounts = container.setdefault('volumeMounts', [])
            container['volumeMounts'] = [v for v in mounts if v.get('name') != 'local-code']
            container['volumeMounts'].append({
                'name': 'local-code',
                'mountPath': '/usr/share/nginx/html'
            })

            spec = deployment['spec']['template']['spec']
            vols = spec.setdefault('volumes', [])
            spec['volumes'] = [v for v in vols if v.get('name') != 'local-code']
            spec['volumes'].append({
                'name': 'local-code',
                'hostPath': {'path': hostpath, 'type': 'Directory'}
            })

        if dry_run:
            print(f"  ℹ️  Would patch deployment (dry run — container: {container.get('name', '?')})")
            return True

        result = subprocess.run(
            ['kubectl', 'apply', '-f', '-'],
            input=_json.dumps(deployment), capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"  ❌ kubectl apply failed: {result.stderr.strip()}")
            if backup_file.exists():
                backup_file.unlink()
            return False

        print(f"  ✅ Deployment patched — waiting for rollout...")
        subprocess.run(
            ['kubectl', 'rollout', 'status', 'deployment', k8s_deploy_name,
             '-n', k8s_namespace, '--timeout=120s']
        )
        return True

    def _restore_k8s_deployment(self, component: str) -> bool:
        """Restore an operator-managed deployment patched via _patch_k8s_deployment."""
        import json as _json

        comp_config = self.config[component]
        k8s_deploy_name = comp_config['k8s_deploy_name']
        k8s_namespace = comp_config.get('k8s_namespace', 'paymenthub')

        backup_dir = Path.home() / '.localdev-backups'
        backup_file = backup_dir / f"{component}-deployment.json"

        if not backup_file.exists():
            print(f"❌ No k8s backup found for {component}: {backup_file}")
            return False

        with open(backup_file, 'r') as f:
            original = _json.load(f)

        original.pop('status', None)
        meta = original.get('metadata', {})
        for field in ('resourceVersion', 'uid', 'creationTimestamp', 'generation', 'managedFields'):
            meta.pop(field, None)

        result = subprocess.run(
            ['kubectl', 'apply', '-f', '-'],
            input=_json.dumps(original), capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"  ❌ kubectl apply failed: {result.stderr.strip()}")
            return False

        backup_file.unlink()
        print(f"✅ Restored {component} k8s deployment — waiting for rollout...")
        subprocess.run(
            ['kubectl', 'rollout', 'status', 'deployment', k8s_deploy_name,
             '-n', k8s_namespace, '--timeout=120s']
        )
        return True

    def _apply_patches(self, content: str, image: str, jarpath: str, hostpath: str, component: str, app_type: str = 'springboot') -> str:
        """Apply the necessary patches to the deployment YAML content"""
        
        lines = content.split('\n')
        result_lines = []
        i = 0
        
        in_init_containers = False
        in_main_containers = False
        in_main_container_def = False
        image_patched = False
        volumemounts_patched = False
        command_patched = False
        volumes_patched = False
        
        # Debug mode
        debug = os.environ.get('DEBUG_PATCH', 'false').lower() == 'true'
        
        while i < len(lines):
            line = lines[i]
            
            if debug and ('containers:' in line or 'initContainers:' in line or 'volumes:' in line or 
                         ('- name:' in line and (in_main_containers or in_init_containers)) or
                         ('image:' in line and 'Values' in line) or
                         'volumeMounts:' in line):
                print(f"  [DEBUG] Line {i}: {line.strip()[:60]}")
                print(f"    in_init={in_init_containers}, in_main={in_main_containers}, in_def={in_main_container_def}")
            
            # Detect initContainers section
            if 'initContainers:' in line and line.strip().startswith('initContainers:'):
                in_init_containers = True
                in_main_containers = False
                in_main_container_def = False
                if debug:
                    print(f"    -> Entering initContainers")
                result_lines.append(line)
                i += 1
                continue
            
            # When we see 'containers:' we're leaving initContainers and entering main containers
            if line.strip().startswith('containers:'):
                in_init_containers = False
                in_main_containers = True
                in_main_container_def = False
                if debug:
                    print(f"    -> Entering main containers")
                result_lines.append(line)
                i += 1
                continue
            
            if in_main_containers and line.strip().startswith('- name:') and not in_main_container_def:
                in_main_container_def = True
                if debug:
                    print(f"    -> Found main container definition")
                result_lines.append(line)
                i += 1
                continue
            
            if line.strip().startswith('volumes:') and in_main_containers:
                # Process volumes section when transitioning from containers
                if debug:
                    print(f"    -> Entering volumes section (from containers)")
                in_main_containers = False
                in_main_container_def = False
                
                if not volumes_patched:
                    result_lines.append(line)
                    i += 1
                    indent = len(line) - len(line.lstrip())
                    
                    # Copy existing volumes
                    while i < len(lines) and lines[i].strip().startswith('- name:'):
                        result_lines.append(lines[i])
                        i += 1
                        # Copy volume definition lines
                        while i < len(lines) and not lines[i].strip().startswith('- name:') and not lines[i].strip().startswith('{{-') and lines[i].strip():
                            result_lines.append(lines[i])
                            i += 1
                    
                    # Add our volume
                    result_lines.append(' ' * (indent + 2) + '- name: local-code')
                    result_lines.append(' ' * (indent + 4) + 'hostPath:  # add this for local dev test')
                    result_lines.append(' ' * (indent + 6) + f'path: {hostpath} # local project path')
                    result_lines.append(' ' * (indent + 6) + "type: Directory # Ensure it's a directory")
                    volumes_patched = True
                    if debug:
                        print(f"    -> Added hostPath volume")
                    continue
                else:
                    result_lines.append(line)
                    i += 1
                    continue
            
            # Also handle volumes: at spec level (after initContainers or containers)
            if line.strip().startswith('volumes:') and not volumes_patched:
                # volumes can appear after either containers or initContainers
                if debug:
                    print(f"    -> Entering volumes section (at spec level, after init or containers)")
                
                # Clear all section flags - we're at spec level now
                in_main_containers = False
                in_main_container_def = False
                in_init_containers = False
                
                result_lines.append(line)
                i += 1
                indent = len(line) - len(line.lstrip())
                
                # Copy existing volumes
                while i < len(lines) and lines[i].strip().startswith('- name:'):
                    result_lines.append(lines[i])
                    i += 1
                    # Copy volume definition lines
                    while i < len(lines) and not lines[i].strip().startswith('- name:') and not lines[i].strip().startswith('{{-') and lines[i].strip():
                        result_lines.append(lines[i])
                        i += 1
                
                # Add our volume
                result_lines.append(' ' * (indent + 2) + '- name: local-code')
                result_lines.append(' ' * (indent + 4) + 'hostPath:  # add this for local dev test')
                result_lines.append(' ' * (indent + 6) + f'path: {hostpath} # local project path')
                result_lines.append(' ' * (indent + 6) + "type: Directory # Ensure it's a directory")
                volumes_patched = True
                if debug:
                    print(f"    -> Added hostPath volume (spec level)")
                continue
            
            # Skip further processing if we're in initContainers
            if in_init_containers:
                result_lines.append(line)
                i += 1
                continue
            
            # Process main container image line
            if in_main_container_def and not image_patched and 'image:' in line and '{{' in line and 'Values.image' in line:
                indent = len(line) - len(line.lstrip())
                if app_type == 'springboot' and image:
                    result_lines.append(' ' * indent + f'image: "{image}"  # this is the JDK to use')
                    result_lines.append(' ' * indent + f'#{line.strip()}  # commented out to allow hostpath local dev/test')
                    if debug:
                        print(f"    -> Patched image to {image}")
                elif app_type == 'webapp':
                    # For webapp, keep original image (nginx) - no need to override
                    result_lines.append(line)
                    if debug:
                        print(f"    -> Keeping original image for webapp")
                else:
                    result_lines.append(line)
                image_patched = True
                i += 1
                continue
            
            # Process volumeMounts - add command BEFORE volumeMounts
            if in_main_container_def and 'volumeMounts:' in line and not volumemounts_patched:
                indent = len(line) - len(line.lstrip())

                # Add command BEFORE volumeMounts to maintain valid YAML structure
                # Only add command for springboot apps
                if app_type == 'springboot' and jarpath:
                    result_lines.append(' ' * indent + f'command: ["java", "-jar", "{jarpath}"] # replace with your jar file name')
                    command_patched = True
                    if debug:
                        print(f"    -> Added command for springboot app")
                elif app_type == 'webapp':
                    # For webapp, skip command - nginx will serve static files
                    if debug:
                        print(f"    -> Skipping command for webapp (nginx will serve static files)")

                result_lines.append(line)
                i += 1

                # Copy existing volumeMounts
                while i < len(lines) and (lines[i].strip().startswith('- name:') or lines[i].strip().startswith('mountPath:') or lines[i].strip().startswith('readOnly:') or lines[i].strip().startswith('subPath:')):
                    result_lines.append(lines[i])
                    i += 1

                # Add our volumeMount based on app type
                if app_type == 'springboot':
                    result_lines.append(' ' * (indent + 2) + '- name: local-code')
                    result_lines.append(' ' * (indent + 4) + 'mountPath: /app # Mount your local code into /app in the container')
                    if debug:
                        print(f"    -> Added volumeMount for springboot")
                elif app_type == 'webapp':
                    result_lines.append(' ' * (indent + 2) + '- name: local-code')
                    result_lines.append(' ' * (indent + 4) + 'mountPath: /usr/share/nginx/html # Mount your built webapp files')
                    if debug:
                        print(f"    -> Added volumeMount for webapp")

                volumemounts_patched = True
                continue
            
            # Default: just add the line
            result_lines.append(line)
            i += 1
        
        result = '\n'.join(result_lines)
        
        # Debug output
        if not image_patched:
            print(f"  ⚠️  Warning: Image was not patched")
        if not volumemounts_patched:
            print(f"  ⚠️  Warning: volumeMounts was not patched")
        if not volumes_patched:
            print(f"  ⚠️  Warning: volumes was not patched")
        
        return result
    
    def restore_deployment(self, component: str) -> bool:
        """Restore a deployment from its backup"""
        if component not in self.config:
            print(f"❌ Component '{component}' not found in config")
            return False
        
        comp_config = self.config[component]

        if comp_config.get('app_type', '') == 'operator':
            print(f"\n⏭️  Skipping {component} - this IS the operator (nothing to restore)")
            return True

        if 'directory' not in comp_config:
            if comp_config.get('k8s_deploy_name'):
                return self._restore_k8s_deployment(component)
            print(f"\n⏭️  Skipping {component} - managed by PHEE operator (no Helm chart to restore)")
            return True

        directory = Path(self._expand_vars(comp_config['directory']))
        deployment_file = directory / "templates" / "deployment.yaml"
        backup_file = deployment_file.parent / f"_deployment.yaml.backup"

        if not backup_file.exists():
            print(f"❌ No backup found for {component}")
            return False
        
        with open(backup_file, 'r') as f:
            content = f.read()
        
        with open(deployment_file, 'w') as f:
            f.write(content)
        
        # Remove git protection when restoring
        self._git_skip_worktree(deployment_file, enable=False)
        
        # Delete the backup file so component can be patched again
        backup_file.unlink()
        
        print(f"✅ Restored {component} from backup")
        print(f"  🗑️  Removed backup file")
        return True
    
    def patch_all(self, dry_run: bool = False):
        """Patch all components listed in the config"""
        components = self.get_components()
        print(f"\n{'=' * 60}")
        print(f"{'DRY RUN - ' if dry_run else ''}Patching {len(components)} component(s)")
        print(f"{'=' * 60}")
        
        success_count = 0
        for component in components:
            if self.patch_deployment(component, dry_run):
                success_count += 1
        
        print(f"\n{'=' * 60}")
        print(f"✅ Successfully patched {success_count}/{len(components)} components")
        print(f"{'=' * 60}\n")
    
    def restore_all(self):
        """Restore all components from their backups"""
        components = self.get_components()
        print(f"\n{'=' * 60}")
        print(f"Restoring {len(components)} component(s)")
        print(f"{'=' * 60}\n")
        
        success_count = 0
        for component in components:
            if self.restore_deployment(component):
                success_count += 1
        
        print(f"\n{'=' * 60}")
        print(f"✅ Successfully restored {success_count}/{len(components)} components")
        print(f"{'=' * 60}\n")


def main():
    """Main entry point for the script"""
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Patch Helm deployment files for local development',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Show status of all components
  ./localdev.py --status

  # Run the PHEE operator locally against Colima (no Docker image needed)
  ./localdev.py --run
  
  # Complete setup: checkout repos + patch deployments
  ./localdev.py --setup
  
  # Just checkout component repositories
  ./localdev.py --checkout
  
  # Update existing repos (pull latest)
  ./localdev.py --update
  
  # Dry run - see what would be changed
  ./localdev.py --dry-run
  
  # Patch all components (auto-protects from git commits)
  ./localdev.py
  
  # Setup specific component (checkout + patch)
  ./localdev.py --setup --component bulk-processor
  
  # Checkout specific component
  ./localdev.py --checkout --component bulk-processor
  
  # Check which files are protected from git commits
  ./localdev.py --check-git-status
  
  # Restore all from backups (removes git protection)
  ./localdev.py --restore
  
  # Restore specific component
  ./localdev.py --restore --component bulk-processor
        """
    )
    
    parser.add_argument(
        '--config',
        type=Path,
        help='Path to localdev.ini (default: localdev.ini in same directory)'
    )
    parser.add_argument(
        '--component',
        help='Specific component to patch/restore'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Show what would be changed without modifying files'
    )
    parser.add_argument(
        '--restore',
        action='store_true',
        help='Restore deployments from backups'
    )
    parser.add_argument(
        '--check-git-status',
        action='store_true',
        help='Check git skip-worktree status of deployment files'
    )
    parser.add_argument(
        '--checkout',
        action='store_true',
        help='Checkout component repositories (components with checkout_enabled=true)'
    )
    parser.add_argument(
        '--update',
        action='store_true',
        help='Update existing component repositories (pull latest changes)'
    )
    parser.add_argument(
        '--setup',
        action='store_true',
        help='Complete setup: checkout repos + patch deployments'
    )
    parser.add_argument(
        '--status',
        action='store_true',
        help='Show status of all components (repos and deployments)'
    )
    parser.add_argument(
        '--run',
        action='store_true',
        help='Run the PHEE operator locally via ./gradlew run (scales down in-cluster operator first reminder)'
    )
    parser.add_argument(
        '--clean-backups',
        action='store_true',
        help='Remove stale localdev backup files whose deployments have been replaced by a full redeploy'
    )

    args = parser.parse_args()

    try:
        patcher = LocalDevPatcher(args.config)

        if args.run:
            patcher.run_operator()
        elif args.clean_backups:
            patcher.clean_backups()
        elif args.status:
            patcher.status_all()
        elif args.check_git_status:
            patcher.check_git_status(args.component)
        elif args.checkout:
            if args.component:
                patcher.checkout_component(args.component, update=False)
            else:
                patcher.checkout_all(update=False)
        elif args.update:
            if args.component:
                patcher.checkout_component(args.component, update=True)
            else:
                patcher.checkout_all(update=True)
        elif args.setup:
            if args.component:
                patcher.setup_component(args.component)
            else:
                patcher.setup_all()
        elif args.restore:
            if args.component:
                patcher.restore_deployment(args.component)
            else:
                patcher.restore_all()
        else:
            # Default: just patch
            if args.component:
                patcher.patch_deployment(args.component, args.dry_run)
            else:
                patcher.patch_all(args.dry_run)
    
    except FileNotFoundError as e:
        print(f"❌ Error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()