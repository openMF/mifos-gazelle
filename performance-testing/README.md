# Mifos Gazelle Performance Testing and TCO Estimation

This directory contains tools for performance testing, analysis, and Total Cost of Ownership (TCO) estimation for the Mifos Gazelle platform components including PaymentHub EE and Mojaloop vNext.

## Overview

The performance testing suite includes:
- JMeter test plans for PaymentHub EE API testing
- Integration with vNext performance tools
- TCO estimation based on performance metrics
- Comprehensive reporting

The tools can be used individually or together to assess performance, analyze bottlenecks, and estimate infrastructure costs for deploying Mifos Gazelle components.

## Prerequisites

Before you begin, ensure that you have the following installed:
- [Apache JMeter](https://jmeter.apache.org/download_jmeter.cgi) version 5.X.X (Recommended)
- [Bash](https://www.gnu.org/software/bash/) version 4.0+ (Standard on most Linux distributions)
- [jq](https://stedolan.github.io/jq/download/) for JSON processing
- [bc](https://www.gnu.org/software/bc/) for calculations
- [git](https://git-scm.com/downloads) for accessing repositories
- [kubectl](https://kubernetes.io/docs/tasks/tools/) for Kubernetes interaction (if testing deployed components)

## Available Scripts

### Master Script

The master script coordinates all testing activities:

```bash
./master-perf-test.sh [options]
```

Options:
- `--phee`: Test PaymentHub EE APIs (default: enabled)
- `--vnext`: Test Mojaloop vNext (default: enabled)
- `--tco`: Generate TCO estimation (default: enabled)
- `--no-phee`: Disable PaymentHub EE testing
- `--no-vnext`: Disable vNext testing
- `--no-tco`: Disable TCO estimation
- `-u, --users NUM`: Number of users/threads (default: 10)
- `-d, --duration NUM`: Test duration in seconds (default: 60)
- `-r, --results-dir DIR`: Results directory (default: auto-generated)
- `-h, --help`: Display help message

Examples:
```bash
./master-perf-test.sh --users 50 --duration 120
./master-perf-test.sh --no-vnext
./master-perf-test.sh --no-tco --users 100
```

### Individual Component Testing

#### PaymentHub EE Testing

```bash
./run-performance-tests.sh [options]
```

Options:
- `-t, --test-plan FILE`: JMeter test plan file (default: paymentHubEE.jmx)
- `-u, --users NUM`: Number of users/threads (default: 10)
- `-r, --ramp-up NUM`: Ramp-up period in seconds (default: 5)
- `-d, --duration NUM`: Test duration in seconds (default: 60)
- `-h, --host STRING`: Host to test (default: paymenthub.local)
- `-p, --protocol STRING`: Protocol [http|https] (default: https)
- `--help`: Display help message

#### vNext Integration

```bash
./vnext-performance-integration.sh [options]
```

Options:
- `-r, --results-dir DIR`: Directory to store results (default: auto-generated)
- `-n, --ndogo-branch BRANCH`: ndogo-loop branch (default: dev)
- `-v, --vnext-branch BRANCH`: vNext tools branch (default: main)
- `-u, --users NUM`: Number of users/threads (default: 10)
- `-d, --duration NUM`: Test duration in seconds (default: 60)
- `--help`: Display help message

### TCO Estimation

```bash
./estimate-tco.sh [options]
```

Options:
- `-r, --results FILE`: JMeter results file (.jtl)
- `-o, --output FILE`: Output file for TCO estimate (default: tco-estimate.json)
- `-i, --instance TYPE`: Instance type (default: t3.xlarge)
- `-g, --region REGION`: Cloud region (default: us-east-1)
- `-d, --days DAYS`: Duration in days (default: 30)
- `--help`: Display help message

## Running the JMeter Test Plan Manually

### 1. Download and Install JMeter

- Download JMeter from the official [JMeter website](https://jmeter.apache.org/download_jmeter.cgi).
- Extract the downloaded file and follow the installation instructions appropriate for your operating system.

### 2. Update the Hosts File

- Open your hosts file in a text editor with administrative privileges:
  - **Windows:** `C:\Windows\System32\drivers\etc\hosts`
  - **Mac/Linux:** `/etc/hosts`
- Add the necessary entries for the PaymentHub EE environment. For example:
  ```plaintext
  127.0.0.1  paymenthub.local
  ```
- Save the file and close the editor.

### 3. Open the Test Plan in JMeter

In JMeter, navigate to `File > Open` and choose the `paymentHubEE.jmx` file.

### 4. Configure the Test Plan

- **Number of Threads (Users):**
  - In JMeter, navigate to the `Thread Group` section.
  - Adjust the `Number of Threads (users)` and `Ramp-Up Period` as per your testing requirements.

- **Enable/Disable APIs:**
  - Expand the test plan to view the API requests.
  - Right-click on any API you want to disable and select `Disable`.

- **Output Configuration:**
  - Add listeners such as `Summary Report`, `Aggregate Report`, or `View Results Tree` to analyze results.
  - For detailed analysis, export results to a `.jtl` file for post-processing.

### 5. Run the Test

Once your configuration is complete, click the green start button (triangle icon) in the JMeter interface to run the test.

## Integration with Mifos Gazelle Deployment

The performance testing tools are designed to work with deployed Mifos Gazelle components. When running tests against a deployed environment:

1. Make sure the appropriate components (PaymentHub EE, vNext) are deployed.
2. Configure the host names in the test scripts to match your deployment.
3. Run the tests as described above.

To integrate with CI/CD pipelines, the master script can be executed as part of post-deployment verification.

## Output and Reports

The test results are organized in a directory structure:
```
results/
  ├── YYYYMMDD_HHMMSS/
      ├── phee/                 # PaymentHub EE test results
      │   ├── results.jtl       # JMeter results
      │   ├── jmeter.log        # JMeter log
      │   └── html-report/      # HTML report
      ├── vnext/                # vNext test results
      │   ├── vnext-results.jtl # JMeter results for vNext
      │   └── integrated-report.md # vNext report
      └── reports/              # Combined reports
          ├── phee-tco-estimate.json   # TCO for PaymentHub EE
          ├── vnext-tco-estimate.json  # TCO for vNext
          └── combined-report.md       # Combined performance and TCO report
```

The combined report (`combined-report.md`) provides a comprehensive overview of test results and TCO estimations.

## TCO Estimation Methodology

The TCO estimation tool analyzes JMeter performance test results to estimate cloud infrastructure costs. It considers:

1. **Performance Metrics:**
   - Average response time
   - Throughput (transactions per second)
   - Total transactions processed

2. **Infrastructure Requirements:**
   - Required number of instances based on performance
   - Instance types and associated costs
   - Storage and network requirements

3. **Cost Factors:**
   - Instance costs (various types available)
   - Storage costs (per GB)
   - Network costs (data transfer)
   - Regional cost variations

The estimates are provided for monthly, annual, and optional multi-year periods. The tool offers recommendations for cost optimization based on performance patterns.

## Contributing

To contribute to the performance testing tools:

1. Review the existing test plans and scripts
2. Add or modify test cases as needed
3. Update documentation for any changes
4. Test your changes before submitting
5. Follow the project's coding standards and guidelines

## Troubleshooting

Common issues and solutions:

1. **JMeter tests fail to connect:**
   - Verify host configuration in host file
   - Check that services are running and accessible
   - Ensure firewalls allow the test traffic

2. **TCO estimation script errors:**
   - Verify JMeter output file format
   - Ensure jq and bc are installed
   - Check file permissions

3. **vNext integration issues:**
   - Check that ndogo-loop repository is accessible
   - Verify Kubernetes cluster access
   - Ensure vNext is properly deployed


