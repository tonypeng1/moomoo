#!/usr/bin/env python3
# Minimal wrapper around EasyOCR to OCR one or more image files.
# Usage: python3 ocr_easyocr.py file1.png [file2.png ...]

import sys

try:
    import easyocr
except Exception as e:
    print("MISSING_EASYOCR: " + str(e), file=sys.stderr)
    sys.exit(2)

if len(sys.argv) < 2:
    print("usage: ocr_easyocr.py <file1> [file2...]", file=sys.stderr)
    sys.exit(4)

# Use CPU by default on macOS; switch gpu=True if you have GPU support configured.
reader = easyocr.Reader(['ch_sim', 'en'], gpu=False)

for path in sys.argv[1:]:
    print(f"--- EasyOCR: {path} ---")
    try:
        results = reader.readtext(path, detail=0, paragraph=False)
        if results:
            print("\n".join(results))
        else:
            print("")  # empty result block
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stdout)
sys.exit(0)