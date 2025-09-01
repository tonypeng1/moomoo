#!/bin/bash
#
# ocr_monitor.sh
#
# Takes a cropped macOS screenshot, runs multiple preprocessing variants,
# performs OCR with Tesseract (Chinese+English), searches for target Chinese terms,
# logs results, sends email and macOS notification if matches are found.
#
# Modified to call external Python script for HSV-based processing:
#   ./ocr_color_extract.py <input.png> <output_hsv.png>
#
# Modified OCR monitor that sends SMS via Twilio (instead of email) when terms are found.
#
set -euo pipefail

# ---------------------
# Configuration
# ---------------------
CROP_X=498
CROP_Y=1117
CROP_WIDTH=2126
CROP_HEIGHT=176
SEARCH_TERMS=("抄底" "卖出")
SCREENSHOT_DIR="/Users/tony3/Documents/moomoo/screenshots"
LOG_FILE="/Users/tony3/Documents/moomoo/screenshots/ocr_log.txt"

# Twilio configuration (fill these in)
TWILIO_ACCOUNT_SID="ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
TWILIO_AUTH_TOKEN="your_auth_token_here"
TWILIO_FROM="+1XXXXXXXXXX"  # your Twilio number in E.164
TWILIO_TO="+1YYYYYYYYYY"    # recipient number in E.164

# Path to helper scripts (assume same directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_HSV_SCRIPT="${SCRIPT_DIR}/helper_scripts/ocr_color_extract.py"
PY_SMS_SCRIPT="${SCRIPT_DIR}/helper_scripts/send_sms_twilio.py"

# Ensure helper scripts exist
if [ ! -x "$PY_HSV_SCRIPT" ]; then
    echo "$(date): ERROR - Python HSV script not found or not executable at $PY_HSV_SCRIPT" >> "$LOG_FILE"
    echo "Make sure $PY_HSV_SCRIPT exists and is executable."
    exit 1
fi

if [ ! -f "$PY_SMS_SCRIPT" ]; then
    echo "$(date): ERROR - SMS script not found at $PY_SMS_SCRIPT" >> "$LOG_FILE"
    echo "Make sure $PY_SMS_SCRIPT exists."
    exit 1
fi

# Create screenshots directory if needed
mkdir -p "$SCREENSHOT_DIR"

# Snapshot file
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
SCREENSHOT_FILE="$SCREENSHOT_DIR/crop_${TIMESTAMP}.png"

/usr/sbin/screencapture -x -R${CROP_X},${CROP_Y},${CROP_WIDTH},${CROP_HEIGHT} "$SCREENSHOT_FILE"

if [ ! -f "$SCREENSHOT_FILE" ]; then
    echo "$(date): ERROR - Screenshot failed" >> "$LOG_FILE"
    exit 1
fi

# Preprocess function (same as before, but calling external python)
preprocess_colored_on_black() {
    local input_file="$1"
    local base_name="${input_file%.*}"
    local processed_files=()

    local red_file="${base_name}_red_enhanced.png"
    convert "$input_file" \
        -channel Red -separate \
        -resize 400% \
        -normalize \
        -contrast-stretch 0 \
        -threshold 30% \
        -morphology Close Diamond:1 \
        "$red_file"
    processed_files+=("$red_file")

    local green_file="${base_name}_green_enhanced.png"
    convert "$input_file" \
        -channel Green -separate \
        -resize 400% \
        -normalize \
        -contrast-stretch 0 \
        -threshold 30% \
        -morphology Close Diamond:1 \
        "$green_file"
    processed_files+=("$green_file")

    local hsv_file="${base_name}_hsv_dark.png"
    if python3 "$PY_HSV_SCRIPT" "$input_file" "$hsv_file"; then
        if [ -f "$hsv_file" ]; then
            processed_files+=("$hsv_file")
        fi
    else
        echo "$(date): Warning - HSV Python processing failed for $input_file" >> "$LOG_FILE"
    fi

    local luma_file="${base_name}_luma.png"
    convert "$input_file" \
        -colorspace YUV \
        -channel U,V -separate +channel \
        -evaluate-sequence Add \
        -resize 400% \
        -normalize \
        -threshold 25% \
        "$luma_file"
    processed_files+=("$luma_file")

    echo "${processed_files[@]}"
}

IFS=' ' read -r -a PROCESSED_FILES <<< "$(preprocess_colored_on_black "$SCREENSHOT_FILE")"

ALL_OCR_TEXT=""
FOUND_TERMS=()
SUCCESSFUL_METHODS=()

for processed_file in "${PROCESSED_FILES[@]}"; do
    if [ -f "$processed_file" ]; then
        OCR_TEXT=$(tesseract "$processed_file" stdout -l chi_sim+eng --psm 6 -c preserve_interword_spaces=1 2>/dev/null || true)
        method_name=$(basename "$processed_file" | sed 's/.*_\([^.]*\)\.png/\1/')
        ALL_OCR_TEXT="$ALL_OCR_TEXT\n--- Method: $method_name ---\n$OCR_TEXT"

        method_found_terms=()
        for term in "${SEARCH_TERMS[@]}"; do
            if echo "$OCR_TEXT" | grep -q "$term"; then
                method_found_terms+=("$term")
                if [[ ! " ${FOUND_TERMS[@]} " =~ " ${term} " ]]; then
                    FOUND_TERMS+=("$term")
                fi
            fi
        done

        if [ ${#method_found_terms[@]} -gt 0 ]; then
            SUCCESSFUL_METHODS+=("$method_name: ${method_found_terms[*]}")
        fi

        rm -f "$processed_file"
    fi
done

if [ ${#FOUND_TERMS[@]} -gt 0 ]; then
    FOUND_LIST=$(IFS=', '; echo "${FOUND_TERMS[*]}")
    SUCCESSFUL_LIST=$(IFS='; '; echo "${SUCCESSFUL_METHODS[*]}")

    {
        echo "$(date): FOUND Chinese characters: $FOUND_LIST in screenshot $SCREENSHOT_FILE"
        echo "Successful methods: $SUCCESSFUL_LIST"
        echo -e "All OCR Text: $ALL_OCR_TEXT"
        echo "---"
    } >> "$LOG_FILE"

    # Build SMS message (keep short; SMS length limits apply)
    SMS_BODY="OCR Alert: found [$FOUND_LIST] - methods: $SUCCESSFUL_LIST. Image: $SCREENSHOT_FILE"

    # Call the Python Twilio sender
    # Ensure any double quotes in SMS_BODY are escaped
    ESCAPED_BODY=$(printf '%s' "$SMS_BODY" | sed 's/"/\\"/g')
    python3 "$PY_SMS_SCRIPT" "$TWILIO_ACCOUNT_SID" "$TWILIO_AUTH_TOKEN" "$TWILIO_FROM" "$TWILIO_TO" "$ESCAPED_BODY" >/dev/null 2>>"$LOG_FILE" || {
        echo "$(date): ERROR - Failed to send SMS via Twilio" >> "$LOG_FILE"
    }

    # macOS notification as well
    osascript -e "display notification \"Found Chinese characters: $FOUND_LIST\" with title \"OCR Alert - SMS Sent\""

    echo "$(date): SMS attempted to $TWILIO_TO for terms: $FOUND_LIST" >> "$LOG_FILE"
else
    echo "$(date): No target Chinese characters found in $SCREENSHOT_FILE (dark background processing)" >> "$LOG_FILE"
fi