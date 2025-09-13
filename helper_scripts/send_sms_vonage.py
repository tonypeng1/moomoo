#!/usr/bin/env python3
"""
send_sms_vonage.py

Send an SMS via the official vonage Python SDK.

Usage:
    python3 send_sms_vonage.py <api_key> <api_secret> <from> <to> "<message>"

Returns:
    0 on success, non-zero on failure. Errors written to stderr.
"""

import sys

def send_with_vonage(api_key: str, api_secret: str, from_number: str, to_number: str, text: str) -> int:
    # detect if text contains non-ascii -> force unicode sms
    msg_type = "unicode" if any(ord(ch) > 127 for ch in text) else "text"
    response = None
    sdk_errors = []
    try:
        import vonage
    except Exception as e:
        vonage = None
        sdk_errors.append(f"Failed to import vonage SDK: {e}")
    else:
        ctor_attempts = []
        if hasattr(vonage, "Client"):
            ctor_attempts.append((vonage.Client, {"key": api_key, "secret": api_secret}))
        if hasattr(vonage, "Vonage"):
            ctor_attempts.append((vonage.Vonage, {"key": api_key, "secret": api_secret}))
            ctor_attempts.append((vonage.Vonage, {"api_key": api_key, "api_secret": api_secret}))
        for ctor, kwargs in ctor_attempts:
            try:
                client = ctor(**kwargs)
                if hasattr(vonage, "Sms"):
                    # include type field for unicode when needed
                    payload = {"from": from_number, "to": to_number, "text": text}
                    if msg_type == "unicode":
                        payload["type"] = "unicode"
                    response = vonage.Sms(client).send_message(payload)
                    break
            except Exception as e:
                sdk_errors.append(f"{ctor.__name__}() failed: {e}")
                continue

    if response is None:
        if sdk_errors:
            for err in sdk_errors:
                sys.stderr.write(err + "\n")
        try:
            import requests
        except Exception as e:
            sys.stderr.write(f"Neither vonage SDK usable nor requests available: {e}\n")
            return 2
        url = "https://rest.nexmo.com/sms/json"
        data = {
            "api_key": api_key,
            "api_secret": api_secret,
            "from": from_number,
            "to": to_number,
            "text": text,
            "type": msg_type,
        }
        try:
            resp = requests.post(url, data=data, timeout=15)
            resp.raise_for_status()
            response = resp.json()
        except Exception as e:
            sys.stderr.write(f"Vonage REST request failed: {e}\n")
            return 2

    # Normalize response checking
    if isinstance(response, dict) and "messages" in response and len(response["messages"]) > 0:
        msg = response["messages"][0]
        status = msg.get("status")
        if status == "0":
            print("OK")
            return 0
        else:
            err_text = msg.get("error-text", str(msg))
            sys.stderr.write(f"Vonage API error status={status}: {err_text}\n")
            return 3
    else:
        sys.stderr.write(f"Unexpected Vonage response: {response}\n")
        return 3

def main(argv):
    if len(argv) != 6:
        sys.stderr.write("Usage: python3 send_sms_vonage.py <api_key> <api_secret> <from> <to> \"<message>\"\n")
        return 1
    api_key, api_secret, from_number, to_number, message = argv[1:6]
    return send_with_vonage(api_key, api_secret, from_number, to_number, message)

if __name__ == "__main__":
    sys.exit(main(sys.argv))
