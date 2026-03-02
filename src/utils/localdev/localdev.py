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
        """Show compact table status of all components, grouped by patch state."""
        import unicodedata
        components = self.get_components()
        rows = []

        for component in components:
            if component not in self.config:
                continue
            comp_config = self.config[component]

            # ── Checkout column ───────────────────────────────────────────────
            if comp_config.get('checkout_enabled', '').lower() == 'true':
                checkout_to_dir = self._expand_vars(comp_config.get('checkout_to_dir', str(Path.home())))
                reponame = comp_config.get('reponame', '')
                repo_name = reponame.rstrip('/').split('/')[-1].replace('.git', '')
                repo_path = Path(checkout_to_dir) / repo_name
                expected = comp_config.get('branch_or_tag', 'main')

                if self._repo_exists(repo_path):
                    current = self._get_current_branch(repo_path)
                    if current == expected:
                        co_col = f"✅ {current}"
                    else:
                        co_col = f"⚠️  {current} (want {expected})"
                else:
                    co_col = "❌ not cloned"
            else:
                co_col = "— disabled"

            # ── Deploy column ─────────────────────────────────────────────────
            is_patched = False
            if 'directory' not in comp_config:
                dep_col = "— operator"
            else:
                directory = Path(self._expand_vars(comp_config['directory']))
                deployment_file = directory / "templates" / "deployment.yaml"
                backup_file = deployment_file.parent / "_deployment.yaml.backup"

                if not deployment_file.exists():
                    dep_col = "❌ missing"
                else:
                    try:
                        result = subprocess.run(
                            ['git', 'ls-files', '-v', str(deployment_file.name)],
                            cwd=deployment_file.parent,
                            capture_output=True, text=True
                        )
                        if result.returncode == 0 and result.stdout:
                            if result.stdout.startswith('S'):
                                dep_col = "🔒 patched"
                                is_patched = True
                            elif backup_file.exists():
                                dep_col = "⚠️  patched (unprotected)"
                                is_patched = True
                            else:
                                dep_col = "— not patched"
                        else:
                            dep_col = "— not patched"
                    except Exception:
                        dep_col = "? unknown"

            rows.append({'name': component, 'co': co_col, 'dep': dep_col, 'is_patched': is_patched})

        patched_rows = [r for r in rows if r['is_patched']]
        other_rows   = [r for r in rows if not r['is_patched']]
        all_rows     = patched_rows + other_rows

        W      = 64
        name_w = max((len(r['name']) for r in all_rows), default=12) + 2
        co_w   = 27  # wide enough for "✅ mifos-v2.0.0  " with emoji offset

        print(f"\n{'═' * W}")
        print(f"  Local Dev Status")
        print(f"{'═' * W}")
        print(f"  {'COMPONENT':<{name_w}}  {'CHECKOUT':<{co_w}}  DEPLOY")
        print(f"  {'─' * (W - 4)}")

        def print_section(label, section_rows):
            if not section_rows:
                return
            fill = '─' * max(0, W - len(label) - 7)
            print(f"\n  ── {label} {fill}")
            for r in section_rows:
                print(f"  {self._visual_ljust(r['name'], name_w)}  {self._visual_ljust(r['co'], co_w)}  {r['dep']}")

        print_section("PATCHED  (active local dev)", patched_rows)
        print_section("NOT PATCHED", other_rows)
        print(f"\n{'═' * W}\n")
    
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

        # Operator-managed components have no Helm chart to patch
        if 'directory' not in comp_config:
            print(f"\n⏭️  Skipping {component} - operator-managed (no Helm chart to patch)")
            print(f"  ℹ️  Use the CR samples in src/operators/ to configure this component")
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

        if 'directory' not in comp_config:
            print(f"\n⏭️  Skipping {component} - operator-managed (no Helm chart to restore)")
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
    
    args = parser.parse_args()
    
    try:
        patcher = LocalDevPatcher(args.config)
        
        if args.status:
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