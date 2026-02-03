#!/usr/bin/env python3
"""
Kubernetes Pod Error Summary Script
Fetches logs from running pods and summarizes errors by namespace/pod/error

Usage:
    ./k8s-error-summary.py                      # Use current namespace (default)
    ./k8s-error-summary.py --all                # Check all namespaces
    ./k8s-error-summary.py <namespace>          # Check specific namespace
    ./k8s-error-summary.py --fatalonly          # Show only fatal/startup-blocking errors
    ./k8s-error-summary.py paymenthub --fatalonly  # Combine namespace with fatal filter
    ./k8s-error-summary.py --help               # Show this help

Features:
    - Identifies pods with startup issues (CrashLoopBackOff, ImagePullBackOff, etc.)
    - Shows previous container logs for restarted pods
    - Detects connection/dependency errors (e.g., waiting for services)
    - Highlights restart counts and exit codes
    - Organizes errors by namespace and pod
    - --fatalonly: Shows only pods with fatal errors or startup issues
      Excludes: pods running successfully, completed pods, restart counts for healthy pods
"""

import subprocess
import json
import re
import sys
from collections import defaultdict
from typing import Dict, List, Tuple, Optional

# Common error patterns to search for
ERROR_PATTERNS = [
    r'ERROR',
    r'Error',
    r'error',
    r'FATAL',
    r'Fatal',
    r'Exception',
    r'EXCEPTION',
    r'WARN',
    r'Warning',
    r'Failed',
    r'failed',
    r'FAILED',
    r'Connection refused',
    r'connection refused',
    r'Could not connect',
    r'Unable to connect',
    r'timeout',
    r'Timeout',
    r'TIMEOUT',
    r'timed out',
    r'panic',
    r'OOMKilled',
    r'CrashLoopBackOff',
    r'waiting for',
    r'Waiting for',
    r'WAITING FOR',
    r'No route to host',
    r'Network is unreachable',
    r'Name or service not known',
    r'cannot connect',
    r'failed to connect',
]

# Fatal error patterns - errors that prevent application from starting/running properly
FATAL_ERROR_PATTERNS = [
    r'FATAL',
    r'Fatal',
    r'fatal',
    r'panic',
    r'Connection refused',
    r'connection refused',
    r'Could not connect',
    r'Unable to connect',
    r'Failed to start',
    r'failed to start',
    r'Cannot start',
    r'cannot start',
    r'waiting for',
    r'Waiting for',
    r'timed out',
    r'timeout.*connect',
    r'No route to host',
    r'Network is unreachable',
    r'Name or service not known',
    r'cannot connect',
    r'failed to connect',
    r'NullPointerException',
    r'Cannot load',
    r'Failed to load',
    r'missing.*required',
    r'Required.*not found',
    r'ClassNotFoundException',
    r'NoClassDefFoundError',
    r'OutOfMemoryError',
    r'BindException',
    r'Address already in use',
]

def run_command(cmd: List[str]) -> Tuple[str, int]:
    """Run a shell command and return output and return code"""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30
        )
        return result.stdout, result.returncode
    except subprocess.TimeoutExpired:
        return "", 1
    except Exception as e:
        print(f"Error running command {' '.join(cmd)}: {e}")
        return "", 1

def get_current_namespace() -> str:
    """Get the current kubectl context namespace"""
    output, rc = run_command(['kubectl', 'config', 'view', '--minify', '-o', 'json'])

    if rc != 0:
        return "default"

    try:
        data = json.loads(output)
        namespace = data.get('contexts', [{}])[0].get('context', {}).get('namespace', 'default')
        return namespace or "default"
    except (json.JSONDecodeError, IndexError):
        return "default"

def get_all_namespaces() -> List[str]:
    """Get all namespaces in the cluster"""
    output, rc = run_command(['kubectl', 'get', 'namespaces', '-o', 'json'])

    if rc != 0:
        return []

    try:
        data = json.loads(output)
        return [item['metadata']['name'] for item in data.get('items', [])]
    except (json.JSONDecodeError, KeyError):
        return []

def get_all_pods(namespace: Optional[str] = None) -> List[Dict]:
    """Get all pods in specified namespace or all namespaces if None"""
    if namespace:
        cmd = ['kubectl', 'get', 'pods', '-n', namespace, '-o', 'json']
    else:
        cmd = ['kubectl', 'get', 'pods', '--all-namespaces', '-o', 'json']

    output, rc = run_command(cmd)

    if rc != 0:
        print("Failed to get pods. Is kubectl configured correctly?")
        return []

    try:
        data = json.loads(output)
        return data.get('items', [])
    except json.JSONDecodeError:
        print("Failed to parse kubectl output")
        return []

def get_pod_logs(namespace: str, pod_name: str, tail_lines: int = 100, previous: bool = False) -> str:
    """Get recent logs from a pod, optionally from previous container instance"""
    cmd = [
        'kubectl', 'logs',
        pod_name,
        '-n', namespace,
        '--tail', str(tail_lines),
        '--all-containers=true'
    ]

    if previous:
        cmd.append('--previous')

    output, rc = run_command(cmd)

    if rc != 0:
        # Try without all-containers flag for single container pods
        cmd = [
            'kubectl', 'logs',
            pod_name,
            '-n', namespace,
            '--tail', str(tail_lines)
        ]
        if previous:
            cmd.append('--previous')

        output, rc = run_command(cmd)

    return output if rc == 0 else ""

def extract_errors(logs: str, fatal_only: bool = False) -> Dict[str, int]:
    """Extract and count error patterns from logs"""
    error_counts = defaultdict(int)
    patterns = FATAL_ERROR_PATTERNS if fatal_only else ERROR_PATTERNS

    for line in logs.split('\n'):
        line = line.strip()
        if not line:
            continue

        for pattern in patterns:
            if re.search(pattern, line):
                # Truncate long lines for readability
                display_line = line[:200] + '...' if len(line) > 200 else line
                error_counts[display_line] += 1
                break  # Only count each line once

    return error_counts

def get_pod_status_errors(pod: Dict) -> Tuple[List[str], bool, str]:
    """
    Extract errors from pod status (not from logs)
    Returns: (errors, is_startup_issue, pod_phase)
    """
    errors = []
    is_startup_issue = False
    status = pod.get('status', {})
    phase = status.get('phase', 'Unknown')

    # Startup issue indicators
    startup_phases = ['Pending', 'Failed']
    startup_reasons = [
        'CrashLoopBackOff', 'ImagePullBackOff', 'ErrImagePull',
        'CreateContainerConfigError', 'InvalidImageName',
        'CreateContainerError', 'RunContainerError',
        'ImageInspectError', 'ErrImageNeverPull'
    ]

    if phase in startup_phases:
        is_startup_issue = True

    # Check init container statuses (these run before main containers)
    init_container_statuses = status.get('initContainerStatuses', [])
    for container in init_container_statuses:
        container_name = container.get('name', 'unknown')
        state = container.get('state', {})
        ready = container.get('ready', False)

        if not ready:
            is_startup_issue = True

        # Check waiting state
        if 'waiting' in state:
            reason = state['waiting'].get('reason', '')
            message = state['waiting'].get('message', '')
            if reason or message:
                errors.append(f"[INIT] Container '{container_name}' waiting: {reason} - {message}")
                if reason in startup_reasons:
                    is_startup_issue = True

        # Check terminated state
        if 'terminated' in state:
            reason = state['terminated'].get('reason', '')
            message = state['terminated'].get('message', '')
            exit_code = state['terminated'].get('exitCode', 'N/A')
            # Only report init container termination if it failed (non-zero exit code)
            if exit_code != 0 and exit_code != 'N/A':
                errors.append(f"[INIT] Container '{container_name}' terminated (exit {exit_code}): {reason} - {message}")
                is_startup_issue = True
            elif exit_code != 0 and exit_code == 'N/A' and reason and reason != 'Completed':
                # If exit code is unknown but reason indicates failure
                errors.append(f"[INIT] Container '{container_name}' terminated: {reason} - {message}")
                is_startup_issue = True

    # Check container statuses
    container_statuses = status.get('containerStatuses', [])
    for container in container_statuses:
        container_name = container.get('name', 'unknown')
        state = container.get('state', {})
        ready = container.get('ready', False)
        restart_count = container.get('restartCount', 0)

        # High restart count indicates startup issues
        # But only flag as startup issue if restarts are high AND container is not currently running
        if restart_count > 0:
            errors.append(f"Container '{container_name}' has restarted {restart_count} times")
            # Only treat as startup issue if many restarts and container is not in running state
            if restart_count > 3 and not (state.get('running') and ready):
                is_startup_issue = True

        # Check waiting state
        if 'waiting' in state:
            reason = state['waiting'].get('reason', '')
            message = state['waiting'].get('message', '')
            if reason or message:
                errors.append(f"Container '{container_name}' waiting: {reason} - {message}")
                if reason in startup_reasons:
                    is_startup_issue = True

        # Check terminated state (for main containers)
        if 'terminated' in state:
            reason = state['terminated'].get('reason', '')
            message = state['terminated'].get('message', '')
            exit_code = state['terminated'].get('exitCode', 'N/A')
            # Only report if container failed (non-zero exit code)
            if exit_code != 0 and exit_code != 'N/A':
                errors.append(f"Container '{container_name}' terminated (exit {exit_code}): {reason} - {message}")
                is_startup_issue = True

    # Check pod conditions
    conditions = status.get('conditions', [])
    for condition in conditions:
        if condition.get('status') == 'False':
            ctype = condition.get('type', '')
            reason = condition.get('reason', '')
            message = condition.get('message', '')
            errors.append(f"Condition {ctype} is False: {reason} - {message}")

            # PodScheduled, Initialized, ContainersReady failures are startup issues
            if ctype in ['PodScheduled', 'Initialized', 'ContainersReady']:
                is_startup_issue = True

    return errors, is_startup_issue, phase

def main():
    # Parse command line arguments
    selected_namespace = None
    fatal_only = False

    args = sys.argv[1:]

    # Check for help
    if "--help" in args or "-h" in args or "help" in args:
        print(__doc__)
        return

    # Check for fatal only flag
    if "--fatalonly" in args:
        fatal_only = True
        args.remove("--fatalonly")

    # Check for namespace argument
    if args:
        if args[0] == "--all" or args[0] == "-a":
            selected_namespace = None
            print("Using all namespaces\n")
        else:
            selected_namespace = args[0]
            print(f"Using namespace: {selected_namespace}\n")
    else:
        # Default to current namespace
        selected_namespace = get_current_namespace()
        print(f"Using current namespace: {selected_namespace}\n")

    if fatal_only:
        print("🔍 Fatal-only mode: Showing only errors that prevent proper application operation\n")

    print("Fetching pods...")
    pods = get_all_pods(selected_namespace)

    if not pods:
        print("No pods found or unable to access cluster")
        return

    namespace_info = f"in namespace '{selected_namespace}'" if selected_namespace else "across all namespaces"
    print(f"Found {len(pods)} pods {namespace_info}. Analyzing...\n")

    # Structure: namespace -> pod -> errors
    results = defaultdict(lambda: defaultdict(lambda: {
        'status_errors': [],
        'log_errors': {},
        'is_startup_issue': False,
        'phase': 'Unknown'
    }))

    startup_issue_pods = []

    for pod in pods:
        metadata = pod.get('metadata', {})
        namespace = metadata.get('namespace', 'unknown')
        pod_name = metadata.get('name', 'unknown')

        print(f"Checking {namespace}/{pod_name}...", end='\r')

        # Get status errors and startup issue flag
        status_errors, is_startup_issue, phase = get_pod_status_errors(pod)

        results[namespace][pod_name]['phase'] = phase
        results[namespace][pod_name]['is_startup_issue'] = is_startup_issue

        if status_errors:
            results[namespace][pod_name]['status_errors'] = status_errors

        # We'll update startup_issue_pods after checking logs
        # to catch pods that appear Running but have fatal errors

        # Get log errors (try to get logs even from failed pods)
        if phase in ['Running', 'Failed', 'Unknown', 'CrashLoopBackOff']:
            # Get current logs
            logs = get_pod_logs(namespace, pod_name, tail_lines=200)
            if logs:
                log_errors = extract_errors(logs, fatal_only)
                if log_errors:
                    results[namespace][pod_name]['log_errors'] = log_errors
                    # If pod shows as Running but has fatal errors, it's actually broken
                    if phase == 'Running' and fatal_only and log_errors:
                        # Check if errors are truly fatal (not just warnings)
                        has_fatal_errors = any(
                            any(re.search(pattern, error) for pattern in [
                                r'waiting for', r'Waiting for', r'Connection refused',
                                r'connection refused', r'Cannot connect', r'FATAL', r'panic'
                            ])
                            for error in log_errors.keys()
                        )
                        if has_fatal_errors:
                            is_startup_issue = True
                            results[namespace][pod_name]['is_startup_issue'] = True

            # For pods with restarts, also check previous container logs
            container_statuses = pod.get('status', {}).get('containerStatuses', [])
            for container in container_statuses:
                restart_count = container.get('restartCount', 0)
                if restart_count > 0:
                    # Try to get previous logs
                    prev_logs = get_pod_logs(namespace, pod_name, tail_lines=200, previous=True)
                    if prev_logs:
                        prev_errors = extract_errors(prev_logs, fatal_only)
                        if prev_errors:
                            # Store previous logs separately
                            if 'previous_log_errors' not in results[namespace][pod_name]:
                                results[namespace][pod_name]['previous_log_errors'] = {}
                            results[namespace][pod_name]['previous_log_errors'] = prev_errors
                            # If previous logs show fatal errors, flag as startup issue
                            if fatal_only:
                                has_fatal_in_previous = any(
                                    any(re.search(pattern, error) for pattern in [
                                        r'waiting for', r'Waiting for', r'Connection refused',
                                        r'connection refused', r'Cannot connect', r'FATAL', r'panic'
                                    ])
                                    for error in prev_errors.keys()
                                )
                                if has_fatal_in_previous:
                                    is_startup_issue = True
                                    results[namespace][pod_name]['is_startup_issue'] = True
                    break  # Only need to check once

        # Add to startup issues list if flagged (after log checking)
        if results[namespace][pod_name]['is_startup_issue']:
            if (namespace, pod_name, phase) not in startup_issue_pods:
                startup_issue_pods.append((namespace, pod_name, phase))

    print("\n" + "="*80)
    print("STARTUP ISSUES SUMMARY")
    print("="*80 + "\n")

    if startup_issue_pods:
        print(f"Found {len(startup_issue_pods)} pod(s) with startup issues:\n")

        for namespace, pod_name, phase in startup_issue_pods:
            pod_data = results[namespace][pod_name]
            print(f"  ⚠️  {namespace}/{pod_name} (Phase: {phase})")

            # In fatal-only mode, filter status errors in summary too
            status_errors_to_show = pod_data['status_errors']
            if fatal_only:
                status_errors_to_show = [
                    err for err in pod_data['status_errors']
                    if not (
                        # Ignore restart counts if pod is now running fine
                        (phase == 'Running' and 'has restarted' in err and 'times' in err) or
                        # Ignore successful init container completions
                        ('INIT' in err and 'exit 0' in err and 'Completed' in err) or
                        # Ignore terminated with exit 0
                        ('terminated (exit 0)' in err)
                    )
                ]

            if status_errors_to_show:
                print(f"      Status Issues:")
                for error in status_errors_to_show:
                    print(f"        • {error}")

            if pod_data.get('previous_log_errors'):
                print(f"      Previous Container Log Errors (before restart):")
                # Show top 5 most common errors from previous container
                for error_line, count in sorted(pod_data['previous_log_errors'].items(),
                                               key=lambda x: x[1],
                                               reverse=True)[:5]:
                    print(f"        [{count}x] {error_line}")

            if pod_data['log_errors']:
                print(f"      Current Log Errors:")
                # Show top 5 most common errors for startup issues
                for error_line, count in sorted(pod_data['log_errors'].items(),
                                               key=lambda x: x[1],
                                               reverse=True)[:5]:
                    print(f"        [{count}x] {error_line}")
            print()
    else:
        print("  ✓ No startup issues found - all pods are healthy!\n")

    print("\n" + "="*80)
    print("DETAILED ERROR SUMMARY BY NAMESPACE/POD")
    print("="*80 + "\n")

    # Print results organized by namespace -> pod -> errors
    total_errors = 0
    pods_with_errors = 0

    for namespace in sorted(results.keys()):
        namespace_has_errors = False
        namespace_output = []

        for pod_name in sorted(results[namespace].keys()):
            pod_data = results[namespace][pod_name]
            phase = pod_data['phase']
            is_startup = pod_data['is_startup_issue']

            # Calculate if pod actually has meaningful errors
            has_log_errors = (pod_data['log_errors'] or pod_data.get('previous_log_errors'))

            # For fatal-only mode, filter status errors
            meaningful_status_errors = pod_data['status_errors']
            if fatal_only:
                # Filter out non-critical status errors
                meaningful_status_errors = [
                    err for err in pod_data['status_errors']
                    if not (
                        # Ignore restart counts if pod is now running fine
                        (phase == 'Running' and not is_startup and 'has restarted' in err and 'times' in err) or
                        # Ignore successful init container completions
                        ('INIT' in err and 'exit 0' in err and 'Completed' in err) or
                        # Ignore terminated with exit 0
                        ('terminated (exit 0)' in err)
                    )
                ]

            has_errors = bool(meaningful_status_errors or has_log_errors)

            # In fatal-only mode, only show pods with actual problems
            if fatal_only:
                # Skip if no startup issues and no errors
                if not is_startup and not has_errors:
                    continue

                # Skip if pod is running healthy with no errors
                if phase == 'Running' and not is_startup and not has_errors:
                    continue

                # Skip if pod completed successfully (phase Succeeded)
                if phase == 'Succeeded':
                    continue

            namespace_has_errors = True
            pods_with_errors += 1

            pod_output = []
            startup_marker = " ⚠️ STARTUP ISSUE" if is_startup else ""
            pod_output.append(f"\n  POD: {pod_name} (Phase: {phase}){startup_marker}")
            pod_output.append(f"  {'-'*76}")

            # Print status errors
            if pod_data['status_errors']:
                # In fatal-only mode, filter out non-critical status errors
                status_errors_to_show = pod_data['status_errors']
                if fatal_only:
                    status_errors_to_show = [
                        err for err in pod_data['status_errors']
                        if not (
                            # Ignore restart counts if pod is now running fine
                            (phase == 'Running' and not is_startup and 'has restarted' in err and 'times' in err) or
                            # Ignore successful init container completions
                            ('INIT' in err and 'exit 0' in err and 'Completed' in err) or
                            # Ignore terminated with exit 0
                            ('terminated (exit 0)' in err)
                        )
                    ]

                if status_errors_to_show:
                    pod_output.append(f"\n    Status Errors:")
                    for error in status_errors_to_show:
                        pod_output.append(f"      • {error}")
                        total_errors += 1

            # Print previous log errors (from crashed containers)
            if pod_data.get('previous_log_errors'):
                pod_output.append(f"\n    Previous Container Log Errors (before restart):")
                for error_line, count in sorted(pod_data['previous_log_errors'].items(),
                                               key=lambda x: x[1],
                                               reverse=True)[:10]:  # Top 10 errors
                    pod_output.append(f"      [{count}x] {error_line}")
                    total_errors += count

            # Print current log errors
            if pod_data['log_errors']:
                pod_output.append(f"\n    Current Log Errors (last 200 lines):")
                for error_line, count in sorted(pod_data['log_errors'].items(),
                                               key=lambda x: x[1],
                                               reverse=True)[:10]:  # Top 10 errors
                    pod_output.append(f"      [{count}x] {error_line}")
                    total_errors += count

            if not has_errors and not fatal_only:
                pod_output.append(f"    ✓ No errors found")

            namespace_output.extend(pod_output)

        # Only print namespace header if it has errors (or not in fatal-only mode)
        if namespace_has_errors or not fatal_only:
            print(f"\n{'='*80}")
            print(f"NAMESPACE: {namespace}")
            print('='*80)
            for line in namespace_output:
                print(line)

    print(f"\n{'='*80}")
    print(f"SUMMARY")
    print('='*80)
    total_pods = len([p for ns in results.values() for p in ns.keys()])
    print(f"Total pods analyzed: {total_pods}")
    if fatal_only:
        print(f"Pods with fatal/blocking errors: {pods_with_errors}")
    else:
        print(f"Pods with errors: {pods_with_errors}")
    print(f"Pods with startup issues: {len(startup_issue_pods)}")
    print(f"Total errors found: {total_errors}")
    print('='*80 + "\n")

if __name__ == '__main__':
    main()
