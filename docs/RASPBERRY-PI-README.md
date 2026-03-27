
# How to boot up Ubuntu Server on Raspberry PI 5 (Headless)

## Requirements
1. Buy one Raspberry PI. Raspberry PI 5 - 16GB RAM. It does not work on RPI-8GB.
2. Buy one memory card - 16GB at least
3. A memory card reader
4. A microHDMI cable if you want to see the logs, OR you're going to boot up an OS with UI.
- In our case, we're going to boot up an Ubuntu server and then we will SSH into the server. So, no such requirement for a microHDMI cable.

## Writing SD card.
1. On your PC, install Raspberry Pi Imager. Here, download for your machine

<img width="800" height="412" alt="image" src="./pi-images/image-01.png" />

2. Now, click on Next \
   This pop-up will come.
Note: I have already configured my sd-card that's why I am seeing all the options.

<img width="800" height="412" alt="image" src="./pi-images/image-02.png" />


3. For the first time, you'll see something like this.

OR if you click on `No, Clear Settings` and then again click on next, you'll see something like this.

<img width="800" height="408" alt="image" src="./pi-images/image-03.png" />


4. Click on Edit Settings. NOTE: REMEMBER HOSTNAME, USERNAME AND PASSWORD. This will be useful when we SSH.

By Default, you'll see this.

<img width="800" height="412" alt="Screenshot 2025-08-14 142220" src="./pi-images/image-04.png" />

<img width="800" height="412" alt="Screenshot 2025-08-14 142240" src="./pi-images/image-05.png" />


5. Here, you've to

- Enable Set hostname
- Enable set username and password
- Enable Configure wireless LAN. It will fill in the details of the wifi network you're connected to. \
- Select "IN" for Wireless LAN country. If you're in India. \
  ### **Here, I have selected 'US'. because, with Wireless LAN country: IN. I was not able to connect to the 5GHz network of my router.**
- and select the *locale settings * accordingly. I have kept it Asia/kolkata
- Keyboard Layout: "us"

<img width="800" height="412" alt="Screenshot 2025-08-14 142121" src="./pi-images/image-06.png" />

6. Now in SERVICES
Enable SSH and "Use password authentication" \
Like this,

<img width="800" height="412" alt="Screenshot 2025-08-14 142315" src="./pi-images/image-07.png" />

SAVE
YES

7. Let it erase your data. Consider taking a backup if your SD card contains some important info

- Let it write, verify and finally flash your SD card.

- It will automatically eject your card from your laptop/system.

- Insert the SD card in Raspberry PI 5.

- Start the Raspberry PI 5. It will automatically connect with your Wifi, do the login and a few other things.

- If you're not using an HDMI cable and not seeing the logs.

- and if you're seeing the green light is blinking. It's a good signal

- You'll be able to SSH to it.

8. To verify you can, use the command 'ping raspberry.local', you'll get output something like this,

```bash
$ ping raspberrypi.local

Pinging raspberrypi.local [fe80::8aa2:9eff:fe04:381c%15] with 32 bytes of data:
Reply from fe80::8aa2:9eff:fe04:381c%15: time=4ms 
Reply from fe80::8aa2:9eff:fe04:381c%15: time=4ms 
Reply from fe80::8aa2:9eff:fe04:381c%15: time=4ms 
Reply from fe80::8aa2:9eff:fe04:381c%15: time=4ms 

Ping statistics for fe80::8aa2:9eff:fe04:381c%15:
    Packets: Sent = 4, Received = 4, Lost = 0 (0% loss),
Approximate round-trip times in milliseconds:
    Minimum = 4ms, Maximum = 4ms, Average = 4ms

```

OR you can log in to your router portal and see the IP address to log in

<img width="500" height="50" alt="router portal image" src="./pi-images/image-08.png" />

9. Moment of Truth. SSH.
`ssh <username>@<ip-addr>`

```bash
$ ssh devarshrpi@192.168.1.94
devarshrpi@192.168.1.94's password: 
Welcome to Ubuntu 24.04.2 LTS (GNU/Linux 6.8.0-1018-raspi aarch64)
.
.
.
.
.
.
Last login: Sat Jul 19 14:14:19 2025 from 192.168.1.65
```

## Installing Mifos Gazelle

You are now ready to install Mifos Gazelle.

(1) Clone the repo
```bash
davidhiggins@gazelle1:~$ git clone --branch main https://github.com/openMF/mifos-gazelle.git
Cloning into 'mifos-gazelle'...
remote: Enumerating objects: 2633, done.
remote: Counting objects: 100% (167/167), done.
remote: Compressing objects: 100% (103/103), done.
remote: Total 2633 (delta 82), reused 100 (delta 62), pack-reused 2466 (from 2)
Receiving objects: 100% (2633/2633), 3.23 MiB | 1.90 MiB/s, done.
Resolving deltas: 100% (1502/1502), done.
```
(2) move to the gazelle directory
```bash
davidhiggins@gazelle1:~$ cd mifos-gazelle
```
(3) start the installation in this case we are deploying `-m deploy` all components `-a all` and having verbose output `-d true`
```bash
davidhiggins@gazelle1:~/mifos-gazelle$ sudo ./run.sh -u ¢USER -m deploy -a all -d true
```
You will find this gives quite [verbose output](pi_verbose_example.md). Full install may take up to 50 mins on a Pi depending on your network speed.

(4) After install you should can run k9s to see the status of the pods
```bash
davidhiggins@gazelle1:~/mifos-gazelle$ cd ..
davidhiggins@gazelle1:~$ k9s
```
Here is an example of how it will show in k9s 

<img width="800" height="412" alt="Screenshot 2025-08-14 142121" src="./pi-images/Screenshotk9s1.png" />
<br>

<img width="800" height="412" alt="Screenshot 2025-08-14 142121" src="./pi-images/Screenshotk9s2.png" />

(5) You can now use all the tools and UIs, why not try make-payment.sh

```bash
davidhiggins@gazelle1:~/mifos-gazelle/src/utils$ ./make-payment.sh 
🔧 GAZELLE_DOMAIN: mifos.gazelle.test
🔍 Auto-detecting payer MSISDN from tenant: greenbank...
🔍 Querying first payer client in tenant: greenbank...
✓ Auto-detected payer MSISDN: 0413509790

🔍 Auto-detecting payee MSISDN from tenant: bluebank...
🔍 Querying first payee client in tenant: bluebank...
✓ Auto-detected payee MSISDN: 0495822412

=== Client Lookup ===
🔍 Looking up payer for MSISDN: 0413509790 in tenant: greenbank...
🔍 Looking up payee for MSISDN: 0495822412 in tenant: bluebank...
=== Payment Details ===
Payer: Sebastian Moore (0413509790) [Tenant: greenbank]
Payee: James Ramirez (0495822412) [Tenant: bluebank]
Tenant ID: greenbank
Payee DFSP ID: bluebank

Enter amount to transfer (0–500): 456

=== Transfer Summary ===
From: Sebastian Moore (0413509790)
To: James Ramirez (0495822412)
Amount: $456 USD

📤 Sending transfer request...
✅ Transfer successful (HTTP 200)
Response: {"transactionId":"a2142834-8cc9-41b3-b626-1332b3a2e717"}

=== Payment Completed ===
✓ $456 USD transferred from Sebastian Moore to James Ramirez
davidhiggins@gazelle1:~/mifos-gazelle/src/utils$ ./view-mifos-transactions.py 
Cannot read config /home/davidhiggins/config/config.ini
davidhiggins@gazelle1:~/mifos-gazelle/src/utils$ id
uid=1000(davidhiggins) gid=1003(davidhiggins) groups=1003(davidhiggins),4(adm),20(dialout),24(cdrom),27(sudo),29(audio),44(video),46(plugdev),60(games),100(users),107(netdev),988(docker),992(render),995(input),1000(gpio),1001(spi),1002(i2c)
davidhiggins@gazelle1:~/mifos-gazelle/src/utils$ ./view-mifos-transactions.py 
Cannot read config /home/davidhiggins/config/config.ini
davidhiggins@gazelle1:~/mifos-gazelle/src/utils$ ./view-mifos-transactions.py -c ~/mifos-gazelle/config/config.ini 
================================================================================
MIFOS TRANSACTION HISTORY - mifos.gazelle.test
================================================================================

================================================================================
TENANT: BLUEBANK
================================================================================
  Client: James Ramirez | Mobile: 0495822412 | ID: 1
    Account #000000001 (ID: 1) | Status: Active | Balance: USD 5,456.00
      Transactions (2):
      [7] 2026-03-13 | Deposit              | Credit: USD 456.00   | Balance: USD 5,456.00
      [1] 2025-12-29 | Deposit              | Credit: USD 5,000.00 | Balance: USD 5,000.00
  Client: Caleb Harris | Mobile: 0424942603 | ID: 2
    Account #000000002 (ID: 2) | Status: Active | Balance: USD 5,000.00
      Transactions (1):
      [2] 2025-12-29 | Deposit              | Credit: USD 5,000.00 | Balance: USD 5,000.00
  Client: Scarlett Taylor | Mobile: 0445271476 | ID: 7
    Account #000000003 (ID: 3) | Status: Active | Balance: USD 5,000.00
      Transactions (1):
      [3] 2025-12-29 | Deposit              | Credit: USD 5,000.00 | Balance: USD 5,000.00
  Client: Sophia Nguyen | Mobile: 0450258089 | ID: 8
    Account #000000004 (ID: 4) | Status: Active | Balance: USD 5,000.00
      Transactions (1):
      [4] 2025-12-29 | Deposit              | Credit: USD 5,000.00 | Balance: USD 5,000.00
  Client: Nathan Hall | Mobile: 0498660918 | ID: 9
    Account #000000005 (ID: 5) | Status: Active | Balance: USD 5,000.00
      Transactions (1):
      [5] 2025-12-29 | Deposit              | Credit: USD 5,000.00 | Balance: USD 5,000.00
  Client: Gabriel Garcia | Mobile: 0472794194 | ID: 10
    Account #000000006 (ID: 6) | Status: Active | Balance: USD 5,000.00
      Transactions (1):
      [6] 2025-12-29 | Deposit              | Credit: USD 5,000.00 | Balance: USD 5,000.00

================================================================================
TENANT: GREENBANK
================================================================================
  Client: Sebastian Moore | Mobile: 0413509790 | ID: 1
    Account #000000001 (ID: 1) | Status: Active | Balance: USD 4,544.00
      Transactions (4):
      [4] 2026-03-13 | Withdrawal           | Debit: USD 456.00    | Balance: USD 4,544.00
      [3] 2026-03-13 | Release Amount       | Amount: USD 456.00   | Balance: USD 5,000.00
      [2] 2026-03-13 | Amount on hold       | Amount: USD 456.00   | Balance: USD 4,544.00
      [1] 2026-03-13 | Deposit              | Credit: USD 5,000.00 | Balance: USD 5,000.00

================================================================================
TENANT: REDBANK
================================================================================
  Client: Charlie White | Mobile: 0413356886 | ID: 1
    Account #000000001 (ID: 1) | Status: Active | Balance: USD 5,000.00
      Transactions (1):
      [1] 2025-12-29 | Deposit              | Credit: USD 5,000.00 | Balance: USD 5,000.00
  Client: Olivia Taylor | Mobile: 0423416547 | ID: 4
    Account #000000002 (ID: 2) | Status: Active | Balance: USD 5,000.00
      Transactions (1):
      [2] 2025-12-29 | Deposit              | Credit: USD 5,000.00 | Balance: USD 5,000.00
  Client: Zoe Lee | Mobile: 0412728990 | ID: 5
    Account #000000003 (ID: 3) | Status: Active | Balance: USD 5,000.00
      Transactions (1):
      [3] 2025-12-29 | Deposit              | Credit: USD 5,000.00 | Balance: USD 5,000.00

================================================================================
SUMMARY: Tenants: 3 | Clients: 10 | Accounts: 10 | Transactions: 14
================================================================================
davidhiggins@gazelle1:~/mifos-gazelle/src/utils$ ./view-mifos-transactions.py -c ~/mifos-gazelle/config/config.ini -h
usage: view-mifos-transactions.py [-h] [--config CONFIG] [--tenant TENANT] [--client-id CLIENT_ID] [--balance]

View Mifos transaction history for all clients

options:
  -h, --help            show this help message and exit
  --config CONFIG, -c CONFIG
                        Path to config.ini (default: /home/davidhiggins/config/config.ini)
  --tenant TENANT, -t TENANT
                        Show only specific tenant (e.g., bluebank, greenbank)
  --client-id CLIENT_ID
                        Show only specific client ID
  --balance, -b         Show condensed tenant/client/balance summary only
davidhiggins@gazelle1:~/mifos-gazelle/src/utils$ ./view-mifos-transactions.py -c ~/mifos-gazelle/config/config.ini -t greenbank
================================================================================
MIFOS TRANSACTION HISTORY - mifos.gazelle.test
================================================================================

================================================================================
TENANT: GREENBANK
================================================================================
  Client: Sebastian Moore | Mobile: 0413509790 | ID: 1
    Account #000000001 (ID: 1) | Status: Active | Balance: USD 4,544.00
      Transactions (4):
      [4] 2026-03-13 | Withdrawal           | Debit: USD 456.00    | Balance: USD 4,544.00
      [3] 2026-03-13 | Release Amount       | Amount: USD 456.00   | Balance: USD 5,000.00
      [2] 2026-03-13 | Amount on hold       | Amount: USD 456.00   | Balance: USD 4,544.00
      [1] 2026-03-13 | Deposit              | Credit: USD 5,000.00 | Balance: USD 5,000.00

================================================================================
SUMMARY: Tenants: 1 | Clients: 1 | Accounts: 1 | Transactions: 4
================================================================================
```

