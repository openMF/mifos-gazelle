#!/usr/bin/env python3
"""
List valid tenants configured in Payment Hub.

Queries the tenant_server_connections table in the operationsmysql pod
to show which tenants are available for batch submission.
"""

import subprocess
import base64
import sys
import argparse


def get_valid_tenants(namespace='paymenthub', pod='operationsmysql-0', verbose=False):
    """
    Query the operationsmysql pod to get list of valid tenant names.

    Returns:
        list: List of tenant names, or None if query fails
    """
    try:
        # First get the mysql root password from secret
        password_cmd = [
            'kubectl', 'get', 'secret', '-n', namespace, 'operationsmysql',
            '-o', "jsonpath={.data.mysql-root-password}"
        ]

        if verbose:
            print(f"Getting mysql password from secret...", file=sys.stderr)

        password_result = subprocess.run(
            password_cmd,
            capture_output=True,
            text=False,
            timeout=10
        )

        if password_result.returncode != 0:
            print(f"Error: Could not retrieve mysql password from secret", file=sys.stderr)
            return None

        # Decode base64 password
        password = base64.b64decode(password_result.stdout).decode('utf-8').strip()

        # Query tenants database for detailed info
        query_cmd = [
            'kubectl', 'exec', '-n', namespace, pod, '--',
            'mysql', '-uroot', f'-p{password}', 'tenants',
            '-e', 'SELECT id, schema_name, schema_server, schema_server_port FROM tenant_server_connections ORDER BY id',
            '--batch'
        ]

        if verbose:
            print(f"Querying tenants database...", file=sys.stderr)

        result = subprocess.run(
            query_cmd,
            capture_output=True,
            text=True,
            timeout=10
        )

        if result.returncode != 0:
            print(f"Error: Could not query tenants database", file=sys.stderr)
            print(f"stderr: {result.stderr}", file=sys.stderr)
            return None

        # Parse output
        lines = [line.strip() for line in result.stdout.split('\n')
                 if line.strip() and not line.startswith('mysql:')]

        if not lines:
            return None

        # First line is header
        header = lines[0].split('\t')
        tenant_data = []

        for line in lines[1:]:
            fields = line.split('\t')
            if len(fields) >= 4:
                tenant_data.append({
                    'id': fields[0],
                    'name': fields[1],
                    'server': fields[2],
                    'port': fields[3]
                })

        return tenant_data

    except subprocess.TimeoutExpired:
        print("Error: Query timed out", file=sys.stderr)
        return None
    except FileNotFoundError:
        print("Error: kubectl not found", file=sys.stderr)
        return None
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return None


def main():
    parser = argparse.ArgumentParser(
        description="List valid tenants configured in Payment Hub",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # List all tenants
  ./list-tenants.py

  # List with verbose output
  ./list-tenants.py -v

  # Just tenant names (for scripting)
  ./list-tenants.py --names-only
        """
    )

    parser.add_argument('--namespace', '-n', type=str, default='paymenthub',
                       help='Kubernetes namespace (default: paymenthub)')
    parser.add_argument('--pod', '-p', type=str, default='operationsmysql-0',
                       help='MySQL pod name (default: operationsmysql-0)')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Verbose output')
    parser.add_argument('--names-only', action='store_true',
                       help='Output only tenant names (one per line)')

    args = parser.parse_args()

    tenant_data = get_valid_tenants(
        namespace=args.namespace,
        pod=args.pod,
        verbose=args.verbose
    )

    if tenant_data is None:
        sys.exit(1)

    if args.names_only:
        # Just output tenant names for scripting
        for tenant in tenant_data:
            print(tenant['name'])
    else:
        # Pretty output
        print("="*80)
        print("CONFIGURED TENANTS")
        print("="*80)
        print(f"Namespace: {args.namespace}")
        print(f"MySQL Pod: {args.pod}")
        print()

        if not tenant_data:
            print("No tenants found!")
        else:
            # Calculate column widths
            max_id = max(len(str(t['id'])) for t in tenant_data)
            max_name = max(len(t['name']) for t in tenant_data)
            max_server = max(len(t['server']) for t in tenant_data)

            # Print header
            print(f"{'ID':<{max_id}}  {'Tenant Name':<{max_name}}  {'Server':<{max_server}}  Port")
            print(f"{'-'*max_id}  {'-'*max_name}  {'-'*max_server}  ----")

            # Print rows
            for tenant in tenant_data:
                print(f"{tenant['id']:<{max_id}}  {tenant['name']:<{max_name}}  {tenant['server']:<{max_server}}  {tenant['port']}")

            print()
            print(f"Total: {len(tenant_data)} tenant(s)")
            print()
            print("Use these tenant names with:")
            print("  ./submit-batch.py --tenant <name> ...")

    sys.exit(0)


if __name__ == "__main__":
    main()
