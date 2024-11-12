#!/usr/bin/env python3

import sys
import subprocess
import re
from datetime import datetime, timezone, timedelta
from argparse import ArgumentParser

# Global variable for debugging
DEBUG = False

def fetch_certificate_details(ip, hostname, port=443):
    """
    Fetch certificate details using openssl s_client and parse with openssl x509.
    """
    try:
        # Call openssl s_client to get the certificate, then pipe to openssl x509
        s_client = subprocess.run(
            ["openssl", "s_client", "-connect", f"{ip}:{port}", "-servername", hostname, "-showcerts"],
            capture_output=True,
            text=True,
            input="Q",  # Input "Q" to quit the openssl s_client interactive mode
        )
        cert_data = s_client.stdout

        if DEBUG:
            # Debug: Print raw cert_data
            print("DEBUG: Raw cert_data from openssl s_client")
            print(cert_data)

        if "no peer certificate available" in cert_data or "Verify return code: 0 (ok)" not in cert_data:
            print(f"CRITICAL: No certificate available for {hostname} at IP {ip}")
            sys.exit(2)

        # Extract the first certificate (server certificate)
        cert_start = cert_data.find("-----BEGIN CERTIFICATE-----")
        cert_end = cert_data.find("-----END CERTIFICATE-----", cert_start) + len("-----END CERTIFICATE-----")
        cert_pem = cert_data[cert_start:cert_end]

        if not cert_pem:
            print(f"CRITICAL: Failed to fetch valid certificate data for {hostname} at IP {ip}")
            sys.exit(2)

        # Decode certificate details using openssl x509
        x509 = subprocess.run(
            ["openssl", "x509", "-noout", "-text"],
            input=cert_pem,
            capture_output=True,
            text=True,
        )

        if DEBUG:
            # Debug: Print parsed x509 output
            print("DEBUG: Parsed x509 output from openssl x509")
            print(x509.stdout)

        return x509.stdout

    except Exception as e:
        print(f"CRITICAL: Failed to fetch certificate details using openssl: {str(e)}")
        sys.exit(2)

def parse_certificate_details(cert_output):
    """
    Parse certificate details such as SANs, CN, and expiration date.
    """
    # Use regex to find the SAN section
    san_block_pattern = re.compile(
        r"X509v3 Subject Alternative Name:\s*(.*?)\n\s*[A-Z]", 
        re.DOTALL
    )
    cn_pattern = re.compile(r"Subject:.*?CN\s*=\s*([^,\s]+)")
    not_after_pattern = re.compile(r"Not\s*After\s*:\s*(.*)")

    san_block_match = san_block_pattern.search(cert_output)
    cn_match = cn_pattern.findall(cert_output)
    not_after_match = not_after_pattern.findall(cert_output)

    if DEBUG:
        # Debug: Print matches found by regex
        print("DEBUG: SAN block match")
        print(san_block_match.group(1) if san_block_match else "No SAN block found")
        print("DEBUG: CN match")
        print(cn_match)
        print("DEBUG: Not After match")
        print(not_after_match)

    san_list = []
    if san_block_match:
        san_block = san_block_match.group(1)
        san_entries = re.findall(r"DNS:([^\s,]+)", san_block)
        san_list = san_entries

    cn = cn_match[0] if cn_match else "Unknown"
    not_after_str = not_after_match[0] if not_after_match else None

    if not_after_str:
        # Remove the "GMT" part for parsing and assume UTC
        not_after_str = not_after_str.replace(" GMT", "")
        exp_date = datetime.strptime(not_after_str, "%b %d %H:%M:%S %Y")
        exp_date = exp_date.replace(tzinfo=timezone.utc)  # Treat as UTC
        days_remaining = (exp_date - datetime.now(timezone.utc)).days
    else:
        exp_date = None
        days_remaining = -1

    return san_list, cn, exp_date, days_remaining

def matches_wildcard(hostname, cn):
    """
    Check if the hostname matches the wildcard CN (e.g., *.example.com).
    """
    if cn.startswith("*."):
        base_domain = cn[2:]  # Remove the *.
        if hostname.endswith(base_domain):
            # Ensure only one subdomain level is matched
            hostname_subdomains = hostname.split(".")
            base_domain_subdomains = base_domain.split(".")
            if len(hostname_subdomains) == len(base_domain_subdomains) + 1:
                return True
    return False

def check_certificate(hostname, ip, warn_days, crit_days):
    # Fetch certificate details
    cert_output = fetch_certificate_details(ip, hostname)
    san_list, cn, exp_date, days_remaining = parse_certificate_details(cert_output)

    # Check hostname match, including wildcard and SANs
    if hostname not in san_list and hostname != cn and not matches_wildcard(hostname, cn):
        print(f"CRITICAL: Hostname '{hostname}' doesn't match certificate for IP {ip}")
        print_cert_details(san_list, cn, exp_date, days_remaining)
        sys.exit(2)

    # Check certificate expiration
    if days_remaining < crit_days:
        print(f"CRITICAL - Certificate expires in {days_remaining} days")
        print_cert_details(san_list, cn, exp_date, days_remaining)
        sys.exit(2)
    elif days_remaining < warn_days:
        print(f"WARNING - Certificate expires in {days_remaining} days")
        print_cert_details(san_list, cn, exp_date, days_remaining)
        sys.exit(1)
    else:
        print(f"OK - Certificate expires in {days_remaining} days")
        print_cert_details(san_list, cn, exp_date, days_remaining)
        sys.exit(0)

def print_cert_details(san_list, cn, exp_date, days_remaining):
    """
    Prints certificate details including matched hostnames and expiry date.
    """
    print(f"Certificate contains these hostnames: CN={cn}, SANs={', '.join(san_list)}")
    if exp_date:
        print(f"Certificate expires on {exp_date.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    else:
        print("Certificate expiration date not found.")
    print(f"| 'days_until_expiry'={days_remaining}")

if __name__ == "__main__":
    parser = ArgumentParser(description="Check SSL certificate expiry using openssl s_client")
    parser.add_argument("-H", "--hostname", required=True, help="Hostname of the certificate to check")
    parser.add_argument("-I", "--ip", required=True, help="IP address of the host to send the request to")
    parser.add_argument("-w", "--warning", type=int, required=True, help="Warning threshold for expiry in days")
    parser.add_argument("-c", "--critical", type=int, required=True, help="Critical threshold for expiry in days")
    parser.add_argument("-d", "--debug", action='store_true', help="Enable debug output")

    args = parser.parse_args()

    DEBUG = args.debug

    check_certificate(args.hostname, args.ip, args.warning, args.critical)

