#!/usr/bin/env python3
"""
Mastercard Payment Tracker
Tracks Mastercard CBS payments from CSV input through to sandbox completion
"""

import subprocess
import json
import csv
import sys
import re
from datetime import datetime
from typing import List, Dict, Optional
import argparse


class MastercardPaymentTracker:
    def __init__(self, csv_file: Optional[str] = None, batch_id: Optional[str] = None,
                 config_file: Optional[str] = None):
        self.csv_file = csv_file
        self.batch_id = batch_id
        self.config_file = config_file
        self.payments = []

    def load_csv_data(self) -> List[Dict]:
        """Load payment data from CSV file"""
        if not self.csv_file:
            return []

        payments = []
        with open(self.csv_file, 'r') as f:
            reader = csv.DictReader(f)
            for row in reader:
                payments.append({
                    'id': row['id'],
                    'request_id': row['request_id'],
                    'payment_mode': row['payment_mode'],
                    'payer_identifier': row['payer_identifier'],
                    'payee_identifier': row['payee_identifier'],
                    'amount': row['amount'],
                    'currency': row['currency'],
                    'note': row['note']
                })
        return payments

    def get_supplementary_data(self) -> List[Dict]:
        """Query Mastercard CBS supplementary data from operations DB"""
        cmd = [
            'kubectl', 'exec', '-n', 'paymenthub', 'operationsmysql-0', '--',
            'mysql', '-uroot', '-pethieTieCh8ahv', 'operations', '-e',
            '''SELECT
                payee_msisdn,
                payee_account_number,
                sender_organisation_name,
                payment_type,
                recipient_first_name,
                recipient_last_name,
                bank_name,
                bank_swift_code,
                purpose_of_payment,
                created_at
            FROM mastercard_cbs_supplementary_data
            ORDER BY created_at DESC
            LIMIT 20'''
        ]

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            return []

        lines = result.stdout.strip().split('\n')
        if len(lines) < 2:
            return []

        headers = lines[0].split('\t')
        data = []
        for line in lines[1:]:
            values = line.split('\t')
            if len(values) == len(headers):
                data.append(dict(zip(headers, values)))

        return data

    def get_connector_status(self, minutes: int = 5) -> List[Dict]:
        """Get payment status from Mastercard CBS connector logs"""
        cmd = [
            'kubectl', 'logs', '-n', 'mastercard-demo',
            '-l', 'app=ph-ee-connector-mastercard-cbs',
            f'--since={minutes}m'
        ]

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            return []

        statuses = []
        # Parse lines like: "Updating operations DB for transaction: xxx, status: COMPLETED, externalId: PAY_xxx"
        pattern = r'Updating operations DB for transaction: ([\w-]+), success: (\w+), status: (\w+)'
        external_pattern = r'externalId: (PAY_[\w-]+)'

        lines = result.stdout.split('\n')
        for i, line in enumerate(lines):
            match = re.search(pattern, line)
            if match:
                transaction_id = match.group(1)
                success = match.group(2)
                status = match.group(3)

                # Look for externalId in same line or next few lines
                external_id = None
                for j in range(i, min(i+3, len(lines))):
                    ext_match = re.search(external_pattern, lines[j])
                    if ext_match:
                        external_id = ext_match.group(1)
                        break

                statuses.append({
                    'transaction_id': transaction_id,
                    'success': success == 'true',
                    'status': status,
                    'external_id': external_id
                })

        return statuses

    def match_payments(self, csv_data: List[Dict],
                      connector_status: List[Dict], supplementary_data: List[Dict]) -> List[Dict]:
        """Match payments across all data sources"""
        matched = []

        for csv_payment in csv_data:
            match_info = {
                'csv': csv_payment,
                'connector': None,
                'supplementary': None
            }

            # Find connector status by transaction_id (request_id from CSV)
            for conn_status in connector_status:
                if conn_status.get('transaction_id') == csv_payment['request_id']:
                    match_info['connector'] = conn_status
                    break

            # Find supplementary data by payee MSISDN
            for supp in supplementary_data:
                if supp.get('payee_msisdn') == csv_payment['payee_identifier']:
                    match_info['supplementary'] = supp
                    break

            matched.append(match_info)

        return matched

    def print_report(self, matched_payments: List[Dict]):
        """Print formatted tracking report"""
        print("\n" + "="*100)
        print("MASTERCARD PAYMENT TRACKER REPORT")
        print("="*100)
        print(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"Total Payments: {len(matched_payments)}")
        print("="*100)

        for i, match in enumerate(matched_payments, 1):
            csv = match['csv']
            conn = match['connector']
            supp = match['supplementary']

            print(f"\n{'─'*100}")
            print(f"PAYMENT #{i}")
            print(f"{'─'*100}")

            # CSV Input
            print(f"\n📄 CSV Input:")
            print(f"   Request ID:       {csv['request_id']}")
            print(f"   Payee MSISDN:     {csv['payee_identifier']}")
            print(f"   Amount:           {csv['amount']} {csv['currency']}")
            print(f"   Note:             {csv['note']}")

            # Supplementary Data
            if supp:
                print(f"\n📋 Supplementary Data:")
                print(f"   Account Number:   {supp.get('payee_account_number', 'N/A')}")
                print(f"   Recipient:        {supp.get('recipient_first_name', '')} {supp.get('recipient_last_name', '')}")
                print(f"   Bank:             {supp.get('bank_name', 'N/A')}")
                print(f"   SWIFT Code:       {supp.get('bank_swift_code', 'N/A')}")
                print(f"   Purpose:          {supp.get('purpose_of_payment', 'N/A')}")
            else:
                print(f"\n📋 Supplementary Data: ⚠️  NOT FOUND")

            # Connector Status
            if conn:
                status_icon = '✅' if conn.get('success') else '❌'
                print(f"\n🔌 Connector Status:")
                print(f"   Transaction ID:   {conn.get('transaction_id', 'N/A')}")
                print(f"   External ID:      {conn.get('external_id', 'N/A')}")
                print(f"   Status:           {status_icon} {conn.get('status', 'N/A')}")
                print(f"   DB Update:        {'✅ SUCCESS' if conn.get('success') else '⚠️  FAILED (expected)'}")
            else:
                print(f"\n🔌 Connector Status: ⚠️  NO STATUS UPDATE")

        print(f"\n{'='*100}")
        print("END OF REPORT")
        print("="*100 + "\n")

    def run(self):
        """Execute the tracking report"""
        print("\n🔍 Loading payment data...")

        csv_data = self.load_csv_data()
        print(f"   ✓ Loaded {len(csv_data)} payments from CSV")

        print("\n📊 Querying Mastercard infrastructure...")
        connector_status = self.get_connector_status(minutes=10)
        print(f"   ✓ Found {len(connector_status)} status updates from connector")

        supplementary_data = self.get_supplementary_data()
        print(f"   ✓ Found {len(supplementary_data)} records in supplementary data")

        print("\n🔗 Matching payments across systems...")
        matched = self.match_payments(csv_data, connector_status, supplementary_data)

        self.print_report(matched)


def main():
    parser = argparse.ArgumentParser(
        description='Track Mastercard CBS payments from CSV to sandbox',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Track payments from a specific CSV file
  ./mastercard-payment-tracker.py -c ~/tomconfig.ini -f bulk-gazelle-mastercard-6.csv

  # Track recent payments (last 5 minutes)
  ./mastercard-payment-tracker.py --minutes 5

  # Track with specific batch ID
  ./mastercard-payment-tracker.py -c ~/tomconfig.ini -b 8d5c495d-a5fc-44b9-a360-26e95456b4f0

  # Use with test script
  ../test-mastercard-e2e.sh -c ~/tomconfig.ini -f bulk-gazelle-mastercard-6.csv
        """
    )

    parser.add_argument('-c', '--config',
                       default='~/tomconfig.ini',
                       help='Config file path (default: ~/tomconfig.ini)')
    parser.add_argument('-f', '--file',
                       help='CSV file path (e.g., bulk-gazelle-mastercard-6.csv)')
    parser.add_argument('-b', '--batch-id',
                       help='Batch ID to track')
    parser.add_argument('-m', '--minutes', type=int, default=10,
                       help='How many minutes back to search logs (default: 10)')

    args = parser.parse_args()

    if not args.file:
        print("⚠️  No CSV file specified. Will show recent payments from logs only.")
        print("   Use -f to specify a CSV file for full tracking.\n")

    tracker = MastercardPaymentTracker(
        csv_file=args.file,
        batch_id=args.batch_id,
        config_file=args.config
    )
    tracker.run()


if __name__ == '__main__':
    main()
