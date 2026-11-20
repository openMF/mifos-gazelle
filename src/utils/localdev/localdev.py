#!/usr/bin/env python3
"""
localdev.py - Runs PHEE components from local builds for local development
Operator-managed components (PaymentHubDeployment CRs) get spec.localDev set on
their CR, and the operator renders the hostPath Deployment (PHEE-455). Anything
without a CR (the operator itself) has its live Deployment patched directly.
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
        self._fork_owner_cache: Optional[str] = None
    
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
        """Get the current branch of a git repository ("HEAD" when detached)"""
        success, output = self._run_git_command(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], repo_path)
        return output if success else None

    def _repo_exists(self, repo_path: Path) -> bool:
        """Check if a directory is a git repository"""
        if not repo_path.exists():
            return False
        success, _ = self._run_git_command(['git', 'rev-parse', '--git-dir'], repo_path)
        return success

    def _ref_exists(self, repo_path: Path, ref: str) -> bool:
        success, _ = self._run_git_command(['git', 'rev-parse', '--verify', '--quiet', ref], repo_path)
        return success

    def _is_dirty(self, repo_path: Path) -> bool:
        """True if tracked files have uncommitted changes"""
        success, output = self._run_git_command(
            ['git', 'status', '--porcelain', '--untracked-files=no'], repo_path)
        return success and bool(output)

    # ── Fork / repository resolution ─────────────────────────────────────────

    def _opt(self, comp_config, key: str, default: str = '') -> str:
        """Component option, falling back to [general], then to default."""
        if key in comp_config:
            return self._expand_vars(comp_config[key])
        return self._expand_vars(self.config['general'].get(key, default))

    def _fork_owner(self) -> Optional[str]:
        """
        GitHub user/org holding the developer's forks (see fork-phee-repos.sh).
        LOCALDEV_FORK_OWNER overrides [general] fork_owner; "auto" means the
        `gh` login. None means no fork: clone straight from upstream.
        """
        if self._fork_owner_cache is not None:
            return self._fork_owner_cache or None

        general = self.config['general']
        owner = os.environ.get('LOCALDEV_FORK_OWNER') or general.get('fork_owner', 'auto')
        owner = owner.strip()
        if owner.lower() == 'auto':
            try:
                result = subprocess.run(['gh', 'api', 'user', '--jq', '.login'],
                                        capture_output=True, text=True, timeout=15)
                owner = result.stdout.strip() if result.returncode == 0 else ''
            except Exception:
                owner = ''
            if not owner:
                print("⚠️  fork_owner = auto but `gh` is not logged in — using upstream repos "
                      "directly (run `gh auth login` or set fork_owner in localdev.ini)")
        if owner.lower() in ('', 'none') or owner.lower() == general.get('upstream_owner', 'openMF').lower():
            owner = ''

        self._fork_owner_cache = owner
        return owner or None

    def _repo_info(self, component: str) -> Optional[dict]:
        """
        Resolve where a component's repo lives and which remotes it should have.

        `repo = <name>`  → origin is <fork_owner>/<name>, upstream is <upstream_owner>/<name>
        `reponame = URL` → origin is that URL, no upstream remote (repos that aren't forked)
        """
        comp_config = self.config[component]
        base = self._opt(comp_config, 'base_branch', 'dev')
        branch = self._expand_vars(comp_config.get('branch_or_tag', base))
        checkout_to_dir = Path(self._opt(comp_config, 'checkout_to_dir', str(Path.home())))

        if comp_config.get('repo'):
            name = comp_config['repo'].strip()
            upstream_url = f"https://github.com/{self._opt(comp_config, 'upstream_owner', 'openMF')}/{name}.git"
            owner = self._fork_owner()
            if owner:
                if self._opt(comp_config, 'git_protocol', 'ssh') == 'https':
                    origin_url = f"https://github.com/{owner}/{name}.git"
                else:
                    origin_url = f"git@github.com:{owner}/{name}.git"
            else:
                origin_url, upstream_url = upstream_url, None
        elif comp_config.get('reponame'):
            origin_url = comp_config['reponame'].strip()
            upstream_url = None
            name = origin_url.rstrip('/').split('/')[-1]
            if name.endswith('.git'):
                name = name[:-4]
        else:
            return None

        return {
            'name': name,
            'origin': origin_url,
            'upstream': upstream_url,
            'branch': branch,
            'base': base,
            # Work branches are cut from upstream/<base>; without a fork, origin is upstream
            'base_ref': f"{'upstream' if upstream_url else 'origin'}/{base}",
            'path': checkout_to_dir / name,
        }

    def _hostpath(self, component: str) -> str:
        """hostpath if set, else <checkout_to_dir>/<repo>[/<module>]"""
        comp_config = self.config[component]
        if comp_config.get('hostpath'):
            return self._expand_vars(comp_config['hostpath'])
        info = self._repo_info(component)
        if not info:
            return ''
        path = info['path']
        if comp_config.get('module'):
            path = path / comp_config['module']
        return str(path)

    @staticmethod
    def _repo_slug(url: str) -> str:
        """owner/name from an ssh or https GitHub URL, lowercased, for comparisons"""
        match = re.search(r'github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$', url)
        return f"{match.group(1)}/{match.group(2)}".lower() if match else url.lower()

    def _ensure_remotes(self, info: dict) -> None:
        """
        Add the upstream remote (fetch-only: push URL set to DISABLED) if missing.
        A mismatched origin is reported but never changed — fork-phee-repos.sh
        repoints clones whose origin is still upstream.
        """
        path = info['path']
        success, current = self._run_git_command(['git', 'remote', 'get-url', 'origin'], path)
        if success and self._repo_slug(current) != self._repo_slug(info['origin']):
            print(f"  ⚠️  origin is {current}, expected {info['origin']} — left unchanged")

        if not info['upstream']:
            return
        success, current = self._run_git_command(['git', 'remote', 'get-url', 'upstream'], path)
        if not success:
            self._run_git_command(['git', 'remote', 'add', 'upstream', info['upstream']], path)
            self._run_git_command(['git', 'remote', 'set-url', '--push', 'upstream', 'DISABLED'], path)
            print(f"  ➕ Added remote upstream → {info['upstream']} (push disabled)")
        elif self._repo_slug(current) != self._repo_slug(info['upstream']):
            print(f"  ⚠️  upstream is {current}, expected {info['upstream']} — left unchanged")

    def _switch_branch(self, info: dict) -> bool:
        """
        Put the repo on info['branch']: an existing local branch, a branch on the
        fork, or a tag. Otherwise create it — locally only — from base_ref.
        Refuses to switch with uncommitted changes.
        """
        path, branch = info['path'], info['branch']
        current = self._get_current_branch(path)
        if current == branch:
            return True
        if self._is_dirty(path):
            print(f"  ❌ Uncommitted changes on {current} — not switching to {branch}. Commit or stash first.")
            return False

        created = False
        if self._ref_exists(path, f"refs/heads/{branch}"):
            cmd = ['git', 'switch', branch]
        elif self._ref_exists(path, f"refs/remotes/origin/{branch}"):
            cmd = ['git', 'switch', '-c', branch, '--track', f"origin/{branch}"]
        elif self._ref_exists(path, f"refs/tags/{branch}"):
            cmd = ['git', 'switch', '--detach', f"refs/tags/{branch}"]
        elif self._ref_exists(path, f"refs/remotes/{info['base_ref']}"):
            cmd = ['git', 'switch', '--no-track', '-c', branch, info['base_ref']]
            created = True
        else:
            print(f"  ❌ {branch} not found locally, on origin or as a tag, and {info['base_ref']} "
                  f"doesn't exist to create it from")
            return False

        success, output = self._run_git_command(cmd, path)
        if not success:
            print(f"  ❌ Failed to switch to {branch}: {output}")
            return False
        if created:
            print(f"  🌱 Created local branch {branch} from {info['base_ref']} "
                  f"(not pushed — `git push -u origin {branch}` when ready)")
        else:
            print(f"  🔀 Switched to {branch}")
        return True

    def _behind_base(self, info: dict) -> Optional[int]:
        """Commits on base_ref not in HEAD (from the last fetch), or None if unknown"""
        success, output = self._run_git_command(
            ['git', 'rev-list', '--count', f"HEAD..{info['base_ref']}"], info['path'])
        return int(output) if success and output.isdigit() else None

    def _fast_forward(self, info: dict) -> None:
        """
        Fast-forward only — never merges, rebases or pushes. The base branch follows
        base_ref (upstream); a work branch follows its own tracking branch, if any.
        """
        path, branch = info['path'], info['branch']
        if self._get_current_branch(path) == 'HEAD':
            return  # tag / detached — nothing to follow
        if branch == info['base']:
            target = info['base_ref']
        else:
            success, target = self._run_git_command(
                ['git', 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'], path)
            if not success:
                target = None
        if target:
            success, output = self._run_git_command(['git', 'merge', '--ff-only', target], path)
            if success:
                print(f"  ✅ Up to date with {target}")
            else:
                print(f"  ⚠️  Can't fast-forward to {target} (diverged?) — left as is")
        if branch != info['base']:
            behind = self._behind_base(info)
            if behind:
                print(f"  ℹ️  {behind} commit(s) behind {info['base_ref']} — rebase/merge when ready")

    def checkout_component(self, component: str, update: bool = False) -> bool:
        """
        Checkout or update a component's repository

        Args:
            component: Name of the component
            update: If True, fetch, switch to branch_or_tag and fast-forward existing repos

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

        info = self._repo_info(component)
        if not info:
            print(f"❌ Missing 'repo' (or 'reponame') for {component}")
            return False
        repo_path = info['path']

        print(f"\n{'Processing' if not update else 'Updating'} {component}...")
        print(f"  📦 Repository: {info['origin']}")
        if info['upstream']:
            print(f"  ⬆️  Upstream  : {info['upstream']}")
        print(f"  🌿 Branch/Tag: {info['branch']}")
        print(f"  📁 Target: {repo_path}")

        if self._repo_exists(repo_path):
            self._ensure_remotes(info)
            if not update:
                current = self._get_current_branch(repo_path)
                print(f"  ℹ️  Repository already exists (on {current})")
                if current != info['branch']:
                    print(f"  💡 Use --update to switch to {info['branch']}")
                return True

            print(f"  🔄 Repository exists, updating...")
            success, output = self._run_git_command(['git', 'fetch', '--all', '--prune'], repo_path)
            if not success:
                print(f"  ⚠️  Warning: Failed to fetch: {output}")
            if not self._switch_branch(info):
                return False
            self._fast_forward(info)
            return True

        # Clone the repository
        print(f"  📥 Cloning repository...")
        Path(repo_path.parent).mkdir(parents=True, exist_ok=True)
        success, output = self._run_git_command(
            ['git', 'clone', info['origin'], str(repo_path)], repo_path.parent)
        if not success:
            print(f"  ❌ Clone failed: {output}")
            if info['upstream']:
                print(f"  💡 No fork yet? Run src/utils/localdev/fork-phee-repos.sh "
                      f"-o {self._fork_owner()} -r {info['name']}")
            return False

        self._ensure_remotes(info)
        if info['upstream']:
            self._run_git_command(['git', 'fetch', 'upstream'], repo_path)
        if not self._switch_branch(info):
            return False
        print(f"  ✅ Cloned successfully")
        return True

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

        # Several components can share one repo (e.g. data-pipeline modules):
        # process it once, and flag sections that ask for different branches.
        seen = {}
        success_count = 0
        for component in enabled_components:
            info = self._repo_info(component)
            if info and info['path'] in seen:
                first, first_branch = seen[info['path']]
                if info['branch'] != first_branch:
                    print(f"\n⚠️  {component} wants {info['branch']} but shares {info['path']} "
                          f"with {first} ({first_branch}) — using {first_branch}")
                success_count += 1
                continue
            if info:
                seen[info['path']] = (component, info['branch'])
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
    
    def _visual_width(self, s: str) -> int:
        """Terminal display width, treating wide emoji as 2 chars."""
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
        return vis_w

    def _visual_ljust(self, s: str, width: int) -> str:
        """Left-justify to terminal display width."""
        return s + ' ' * max(0, width - self._visual_width(s))

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

        # Deployments the operator rendered from spec.localDev carry this annotation.
        local_dev_annotations = set()
        try:
            result = subprocess.run(
                ['kubectl', 'get', 'deployments', '-n', 'paymenthub', '-o',
                 'jsonpath={range .items[*]}{.metadata.name}={.metadata.annotations.paymenthub\\.mifos\\.org/local-dev}{"\\n"}{end}'],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                for line in result.stdout.strip().splitlines():
                    name, _, value = line.partition('=')
                    if value.strip():
                        local_dev_annotations.add(name.strip())
        except Exception:
            pass

        backup_dir = Path.home() / '.localdev-backups'

        patchable_rows = []
        checkout_rows  = []

        for component in components:
            if component not in self.config:
                continue
            comp_config = self.config[component]

            # ── Branch / upstream columns ─────────────────────────────────────
            info = self._repo_info(component) if comp_config.get('checkout_enabled', '').lower() == 'true' else None
            up_col = "—"
            if info:
                if self._repo_exists(info['path']):
                    current = self._get_current_branch(info['path'])
                    expected = info['branch']
                    co_col = f"✅ {current}" if current == expected else f"⚠️  {current} (ini: {expected})"
                    behind = self._behind_base(info)
                    if behind is not None:
                        up_col = f"{behind} behind" if behind else "current"
                else:
                    co_col = "❌ not cloned"
            else:
                co_col = "—"

            # ── Cluster column ────────────────────────────────────────────────
            is_patched = False

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

                local = "local files" if app_type_comp == 'webapp' else "local JAR"
                if deploy_name in local_dev_annotations:
                    cluster_col = f"🔧 {local}  (CR)"
                    is_patched = True
                elif backup_file.exists() and live_hostpath:
                    cluster_col = f"🔧 {local}  (direct)"
                    is_patched = True
                elif backup_is_stale:
                    _, tag = k8s_images[deploy_name]
                    cluster_col = f"📦 image {tag}  (stale backup — run --clean-backups)"
                elif backup_file.exists() and in_cluster:
                    _, tag = k8s_images[deploy_name]
                    cluster_col = f"⚠️  reverted → image {tag}"
                elif backup_file.exists():
                    cluster_col = "⚠️  reverted → not deployed"
                elif in_cluster:
                    _, tag = k8s_images[deploy_name]
                    cluster_col = f"📦 image {tag}"
                else:
                    cluster_col = "not deployed"
                patchable_rows.append({'name': component, 'co': co_col, 'up': up_col,
                                       'cluster': cluster_col, 'is_patched': is_patched})
            else:
                checkout_rows.append({'name': component, 'co': co_col, 'up': up_col})

        all_named = patchable_rows + checkout_rows
        name_w = max((len(r['name']) for r in all_named), default=12) + 2
        co_w   = max((self._visual_width(r['co']) for r in all_named), default=6) + 2
        up_w   = max(len('UPSTREAM'), *(len(r['up']) for r in all_named)) + 2
        cl_w   = max((self._visual_width(r['cluster']) for r in patchable_rows), default=7)
        W      = min(max(72, name_w + co_w + up_w + cl_w + 4), 110)

        print(f"\n{'═' * W}")
        print(f"  Local Dev Status")
        print(f"{'═' * W}")

        def divider(label=''):
            if label:
                fill = '─' * max(0, W - len(label) - 6)
                print(f"\n  ── {label} {fill}")
            else:
                print(f"  {'─' * (W - 4)}")

        def row(r, cluster=''):
            print(f"  {self._visual_ljust(r['name'], name_w)}{self._visual_ljust(r['co'], co_w)}"
                  f"{r['up']:<{up_w}}{cluster}".rstrip())

        # Patchable components table
        divider('deployable  (run your build in the cluster)')
        print(f"  {'COMPONENT':<{name_w}}{'BRANCH':<{co_w}}{'UPSTREAM':<{up_w}}RUNNING")
        divider()
        for r in patchable_rows:
            row(r, r['cluster'])

        # Checkout-only
        divider('checkout only')
        print(f"  {'COMPONENT':<{name_w}}{'BRANCH':<{co_w}}UPSTREAM")
        divider()
        for r in checkout_rows:
            row(r)

        print("\n  BRANCH    ✅ = branch_or_tag in localdev.ini   ⚠️  = other branch (ini: what the ini says)")
        print("  UPSTREAM  commits on upstream/<base_branch> missing from your branch, as of last fetch")
        print("  RUNNING   🔧 your build — (CR) via spec.localDev, (direct) patched Deployment;"
              "  📦 registry image")

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

        # Components with a PaymentHubDeployment CR are switched through the CR so the
        # operator keeps them on the local build; the rest (the operator itself) are
        # patched directly.
        if comp_config.get('k8s_deploy_name'):
            if self._has_cr(component):
                return self._patch_cr(component, dry_run)
            return self._patch_k8s_deployment(component, dry_run)

        print(f"\n⏭️  Skipping {component} - checkout-only component, no deployment to patch")
        print(f"  ℹ️  Add k8s_deploy_name/hostpath/jarpath to localdev.ini to enable direct-patch mode")
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
        hostpath = self._hostpath(component)
        app_type = comp_config.get('app_type', 'springboot')

        backup_dir = Path.home() / '.localdev-backups'
        backup_file = backup_dir / f"{component}-deployment.json"

        # A backup file alone doesn't mean the live Deployment is still patched —
        # a redeploy (run.sh -m deploy / cleanapps) recreates it from scratch and
        # silently reverts any prior patch, leaving a stale backup on disk. Check
        # the live image too (same "temurin" check --status already uses).
        live_check = subprocess.run(
            ['kubectl', 'get', 'deployment', k8s_deploy_name, '-n', k8s_namespace,
             '-o', 'jsonpath={.spec.template.spec.containers[0].image}'],
            capture_output=True, text=True
        )
        live_image = live_check.stdout.strip() if live_check.returncode == 0 else ''
        live_is_patched = 'temurin' in live_image

        if backup_file.exists() and live_is_patched:
            print(f"\n⏭️  Skipping {component} - already k8s-patched")
            print(f"  ℹ️  Backup: {backup_file}")
            print(f"  💡 Use --restore first to re-patch")
            return True
        elif backup_file.exists():
            print(f"\n⚠️  Stale backup for {component} — live Deployment reverted to "
                  f"{live_image or 'a registry image'} (likely from a redeploy). "
                  f"Re-patching and refreshing the backup.")

        print(f"\n{'[DRY RUN] ' if dry_run else ''}Processing {component} (k8s direct-patch)...")

        # Check the host side before touching the cluster: a missing hostPath
        # directory leaves the pod stuck in ContainerCreating.
        if not Path(hostpath).is_dir():
            print(f"  ❌ Host path {hostpath} does not exist — run --checkout first")
            return False
        if app_type == 'springboot':
            jarpath = self._resolve_jarpath(component, hostpath)
            if not jarpath:
                return False
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

    # ── Operator-managed components: spec.localDev on the CR (PHEE-455) ──────────

    CR_KIND = 'paymenthubdeployments.gazelle.mifos.io'
    LOCALDEV_ANNOTATION = 'paymenthub.mifos.org/local-dev'
    OPERATOR_DEPLOYMENT = 'paymenthub-ee-operator'

    def _kubectl(self, *args: str, input: Optional[str] = None) -> subprocess.CompletedProcess:
        return subprocess.run(['kubectl', *args], input=input, capture_output=True, text=True)

    def _has_cr(self, component: str) -> bool:
        comp_config = self.config[component]
        return self._kubectl('get', self.CR_KIND, comp_config['k8s_deploy_name'],
                             '-n', comp_config.get('k8s_namespace', 'paymenthub')).returncode == 0

    def _operator_allows_localdev(self, namespace: str) -> bool:
        result = self._kubectl('get', 'deployment', self.OPERATOR_DEPLOYMENT, '-n', namespace, '-o',
                               'jsonpath={.spec.template.spec.containers[0].env[?(@.name=="LOCALDEV_ENABLED")].value}')
        return result.returncode == 0 and result.stdout.strip().lower() == 'true'

    def _deployment_annotation(self, name: str, namespace: str) -> str:
        result = self._kubectl('get', 'deployment', name, '-n', namespace, '-o',
                               "jsonpath={.metadata.annotations['paymenthub\\.mifos\\.org/local-dev']}")
        return result.stdout.strip() if result.returncode == 0 else ''

    def _wait_for_operator(self, name: str, namespace: str, want_local: bool, timeout_s: int = 90) -> bool:
        """Wait until the operator has re-rendered the Deployment, then for its rollout."""
        import time
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            if bool(self._deployment_annotation(name, namespace)) == want_local:
                subprocess.run(['kubectl', 'rollout', 'status', 'deployment', name,
                                '-n', namespace, '--timeout=180s'])
                return True
            time.sleep(2)
        print(f"  ⚠️  The operator hasn't re-rendered {name} after {timeout_s}s — "
              f"check: kubectl logs deploy/{self.OPERATOR_DEPLOYMENT} -n {namespace}")
        return False

    def _patch_cr(self, component: str, dry_run: bool = False) -> bool:
        """Set spec.localDev on the component's CR from localdev.ini."""
        import json as _json

        comp_config = self.config[component]
        name = comp_config['k8s_deploy_name']
        namespace = comp_config.get('k8s_namespace', 'paymenthub')
        app_type = comp_config.get('app_type', 'springboot')
        hostpath = self._hostpath(component)

        print(f"\n{'[DRY RUN] ' if dry_run else ''}Processing {component} (operator CR: spec.localDev)...")
        if not Path(hostpath).is_dir():
            print(f"  ❌ Host path {hostpath} does not exist — run --checkout first")
            return False

        local_dev = {'enabled': True, 'hostPath': hostpath}
        if app_type == 'springboot':
            jarpath = self._resolve_jarpath(component, hostpath)
            if not jarpath:
                return False
            local_dev['jarPath'] = jarpath
            if comp_config.get('image'):
                local_dev['image'] = comp_config['image']
        elif app_type == 'webapp':
            local_dev['mountPath'] = '/usr/share/nginx/html'

        print(f"  📦 CR         : {name}  ns: {namespace}")
        for key in ('image', 'jarPath', 'hostPath', 'mountPath'):
            if key in local_dev:
                print(f"  {'🔗' if key == 'hostPath' else '📦'} {key:<11}: {local_dev[key]}")

        if not self._operator_allows_localdev(namespace):
            print(f"  ⚠️  The operator isn't running with LOCALDEV_ENABLED=true, so it will ignore "
                  f"spec.localDev. Redeploy PaymentHub on a local cluster, or set it with:\n"
                  f"      kubectl set env deployment/{self.OPERATOR_DEPLOYMENT} -n {namespace} LOCALDEV_ENABLED=true")

        if dry_run:
            print(f"  ℹ️  Would set spec.localDev on {name} (dry run)")
            return True

        result = self._kubectl('patch', self.CR_KIND, name, '-n', namespace, '--type', 'merge',
                               '-p', _json.dumps({'spec': {'localDev': local_dev}}))
        if result.returncode != 0:
            print(f"  ❌ kubectl patch failed: {result.stderr.strip()}")
            return False
        print(f"  ✅ spec.localDev set — waiting for the operator...")
        self._wait_for_operator(name, namespace, want_local=True)
        # The operator re-renders the whole Deployment, so an earlier direct patch is gone.
        old_backup = Path.home() / '.localdev-backups' / f"{component}-deployment.json"
        if old_backup.exists():
            old_backup.unlink()
            print(f"  🗑  Removed old direct-patch backup {old_backup}")
        print(f"  💡 After rebuilding: ./localdev.py --restart --component {component}")
        return True

    def _restore_cr(self, component: str) -> bool:
        """Remove spec.localDev so the operator puts the image back."""
        comp_config = self.config[component]
        name = comp_config['k8s_deploy_name']
        namespace = comp_config.get('k8s_namespace', 'paymenthub')

        current = self._kubectl('get', self.CR_KIND, name, '-n', namespace, '-o', 'jsonpath={.spec.localDev}')
        if not current.stdout.strip():
            if (Path.home() / '.localdev-backups' / f"{component}-deployment.json").exists():
                return self._restore_k8s_deployment(component)   # patched directly before PHEE-455
            print(f"⏭️  {component}: spec.localDev not set — already on its image")
            return True
        result = self._kubectl('patch', self.CR_KIND, name, '-n', namespace, '--type', 'merge',
                               '-p', '{"spec":{"localDev":null}}')
        if result.returncode != 0:
            print(f"  ❌ kubectl patch failed: {result.stderr.strip()}")
            return False
        print(f"✅ Removed spec.localDev from {component} — waiting for the operator...")
        self._wait_for_operator(name, namespace, want_local=False)
        return True

    def restart_component(self, component: str) -> bool:
        """Delete the component's pods so the replacements load the rebuilt jar.
        (Not `rollout restart`: the operator strips its annotation on the next reconcile.)"""
        if component not in self.config or not self.config[component].get('k8s_deploy_name'):
            print(f"❌ Component '{component}' has no k8s_deploy_name in localdev.ini")
            return False
        comp_config = self.config[component]
        name = comp_config['k8s_deploy_name']
        namespace = comp_config.get('k8s_namespace', 'paymenthub')
        print(f"🔄 Restarting {component}...")
        # --wait: return once the old pods are gone, so the Ready wait below only sees replacements.
        result = self._kubectl('delete', 'pod', '-n', namespace, '-l', f'app={name}', '--wait=true')
        if result.returncode != 0:
            print(f"  ❌ kubectl delete pod failed: {result.stderr.strip()}")
            return False
        result = subprocess.run(['kubectl', 'wait', '--for=condition=Ready', 'pod', '-l', f'app={name}',
                                 '-n', namespace, '--timeout=300s'])
        return result.returncode == 0

    def _resolve_jarpath(self, component: str, hostpath: str) -> Optional[str]:
        """
        Container path of the jar to run. Uses jarpath when set and present on the
        host; otherwise the boot jar in <hostpath>/build/libs (ignoring *-plain.jar,
        newest wins if there are several), so jar renames don't break patching.
        """
        configured = self.config[component].get('jarpath', '').strip()
        libs = Path(hostpath) / 'build' / 'libs'
        if configured and configured.lower() != 'auto':
            if not configured.startswith('/app/'):
                return configured
            if (Path(hostpath) / configured[len('/app/'):]).is_file():
                return configured
            print(f"  ⚠️  jarpath {configured} not found on host — looking in {libs}")

        jars = [j for j in libs.glob('*.jar') if not j.name.endswith('-plain.jar')] if libs.is_dir() else []
        if not jars:
            print(f"  ❌ No boot jar in {libs} — build first (e.g. ./gradlew bootJar)")
            return None
        jar = max(jars, key=lambda j: j.stat().st_mtime)
        if len(jars) > 1:
            print(f"  ⚠️  {len(jars)} jars in {libs} — using the newest, {jar.name}")
        return f"/app/build/libs/{jar.name}"

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

    def restore_deployment(self, component: str) -> bool:
        """Restore a deployment from its backup"""
        if component not in self.config:
            print(f"❌ Component '{component}' not found in config")
            return False
        
        comp_config = self.config[component]

        if comp_config.get('k8s_deploy_name'):
            if self._has_cr(component):
                return self._restore_cr(component)
            return self._restore_k8s_deployment(component)

        print(f"\n⏭️  Skipping {component} - checkout-only component, nothing to restore")
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
        description='Patch live Kubernetes Deployments for local development',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Show status of all components
  ./localdev.py --status

  # Complete setup: checkout repos + patch deployments
  ./localdev.py --setup

  # Setup the operator itself (same k8s-direct mechanism as any other component)
  ./localdev.py --setup --component paymenthub-operator

  # Just checkout component repositories
  ./localdev.py --checkout

  # Fetch, switch to each branch_or_tag, fast-forward (never pushes)
  ./localdev.py --update

  # Dry run - see what would be changed
  ./localdev.py --dry-run

  # Patch all components
  ./localdev.py

  # Setup specific component (checkout + patch)
  ./localdev.py --setup --component bulk-processor

  # Checkout specific component
  ./localdev.py --checkout --component bulk-processor

  # Restore all from backups
  ./localdev.py --restore

  # Restore specific component
  ./localdev.py --restore --component bulk-processor

  # Pick up a rebuilt jar
  ./localdev.py --restart --component bulk-processor
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
        '--checkout',
        action='store_true',
        help='Clone missing component repositories (components with checkout_enabled=true)'
    )
    parser.add_argument(
        '--update',
        action='store_true',
        help='Fetch, switch to branch_or_tag (creating it from upstream/<base_branch> if new) and fast-forward'
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
        '--restart',
        action='store_true',
        help='Restart the component pod(s) to pick up a rebuilt jar (use with --component)'
    )
    parser.add_argument(
        '--clean-backups',
        action='store_true',
        help='Remove stale localdev backup files whose deployments have been replaced by a full redeploy'
    )

    args = parser.parse_args()

    try:
        patcher = LocalDevPatcher(args.config)

        if args.clean_backups:
            patcher.clean_backups()
        elif args.restart:
            if not args.component:
                print("❌ --restart needs --component")
                sys.exit(1)
            patcher.restart_component(args.component)
        elif args.status:
            patcher.status_all()
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