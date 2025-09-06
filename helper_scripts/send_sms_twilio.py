#!/usr/bin/env python3
"""
send_sms_twilio.py

Send an SMS via Twilio REST API.

Usage:
    python3 send_sms_twilio.py <account_sid> <auth_token> <from_number> <to_number> "<message body>"

Example:
    python3 send_sms_twilio.py ACxxxx your_auth_token +1234567890 +1987654321 "Alert: found terms"

Notes:
* Phone numbers must be in E.164 format (e.g. +14155552671).
* The 'from_number' must be a Twilio-enabled number on your account.
"""

import sys
import requests
from urllib.parse import urlencode

def send_sms(account_sid: str, auth_token: str, from_number: str, to_number: str, body: str) -> int:
    url = f"https://api.twilio.com/2010-04-01/Accounts/{account_sid}/Messages.json"
    data = {
        "From": from_number,
        "To": to_number,
        "Body": body
    }
    try:
        resp = requests.post(url, data=data, auth=(account_sid, auth_token), timeout=15)
    except Exception as e:
        sys.stderr.write(f"Error sending request to Twilio: {e}\n")
        return 2

    if resp.status_code >= 200 and resp.status_code < 300:
        print("OK")
        return 0
    else:
        sys.stderr.write(f"Twilio API error: HTTP {resp.status_code} - {resp.text}\n")
        return 3

def main(argv):
    if len(argv) != 6:
        sys.stderr.write("Usage: python3 send_sms_twilio.py <account_sid> <auth_token> <from_number> <to_number> \"<message>\"\n")
        return 1
    account_sid = argv[1]
    auth_token = argv[2]
    from_number = argv[3]
    to_number = argv[4]
    body = argv[5]
    return send_sms(account_sid, auth_token, from_number, to_number, body)

if __name__ == "__main__":
    sys.exit(main(sys.argv))