# PaymentHubEE API Testing with JMeter

This README provides instructions on how to set up and run the JMeter test plan for testing the APIs of PaymentHubEE. The test plan allows you to simulate multiple users, configure which APIs to test, and analyze the performance of the APIs.

## Prerequisites

Before you begin, ensure that you have the following installed:
- [Apache JMeter](https://jmeter.apache.org/download_jmeter.cgi) version 5.X.X (Recommended)

## Steps to Run the Test on Your Local Computer

### 1. Download and Install JMeter

- Download JMeter from the official [JMeter website](https://jmeter.apache.org/download_jmeter.cgi).
- Extract the downloaded file and follow the installation instructions appropriate for your operating system.

### 2. Update the Hosts File

- Open your hosts file in a text editor with administrative privileges:
  - **Windows:** `C:\Windows\System32\drivers\etc\hosts`
  - **Mac/Linux:** `/etc/hosts`
- Add the necessary entries for the PaymentHubEE environment. For example:
  ```plaintext
  127.0.0.1  paymenthub.local
- Save the file and close the editor.

### 3. Copy the Test Plan from GitHub
 - Clone the repository containing the JMeter test plan to your local machine:
   ```plaintext
   git clone https://github.com/openMF/mifos-gazelle.git
   cd performance-testing
 - Alternatively, you can download the .jmx file directly from GitHub.

### 4. Open the Test Plan in JMeter

In JMeter, navigate to `File > Open` and choose the `paymentHubEE.jmx` file from the cloned repository or the location where you downloaded it.

### 5. Configure the Test Plan

- **Number of Threads (Users):**
  - In JMeter, navigate to the `Thread Group` section.
  - Adjust the `Number of Threads (users)` and `Ramp-Up Period` as per your testing requirements.  
  - Increasing the number of threads simulates more users accessing the APIs simultaneously, which can help you test the performance under load. Reducing the number of threads simulates fewer users and allows you to test the system's behavior under lighter load conditions.

- **Enable/Disable APIs:**
  - Expand the test plan to view the API requests.
  - Right-click on any API you want to disable and select `Disable`.  
  - You can also enable specific APIs if needed. This allows you to focus on testing individual APIs or a subset of APIs, which is useful for targeted performance testing and debugging.

- **Output Configuration:**
  - **Response Time:** To get detailed response times, add a listener such as `Summary Report` or `Aggregate Report`. These listeners provide insights into average, minimum, maximum, and median response times for each API request.
  - **Error Reporting:** To capture any errors or failures during the test, add a `View Results Tree` listener. This will log each request and response, allowing you to analyze failed requests in detail.
  - **Throughput Analysis:** To monitor the number of requests processed per second (throughput), use the `Throughput vs Threads` or `Graph Results` listeners. These will give you a visual representation of how the system handles concurrent users.

  - **Data Export:** You can export the results to a `.csv` or `.xml` file for further analysis. Right-click on the listener (e.g., `Aggregate Report`) and choose `Save Table Data` to export the data.

  By configuring these elements, you can tailor the test to your specific needs, whether you're looking to assess performance under load, analyze error rates, or fine-tune individual API endpoints.
### 6. Run the Test
Once your configuration is complete, click the green start button (triangle icon) in the JMeter interface to run the test. 

JMeter will execute the test plan based on your configurations.

### 7. Analyze the Results
- View Results Tree: To see detailed logs of each request and response, right-click on the Test Plan or Thread Group and add a listener (e.g., View Results Tree).
- Aggregate Report: To get a summary of the test results, add an Aggregate Report listener.
- Review the results to identify any performance issues or API failures.


