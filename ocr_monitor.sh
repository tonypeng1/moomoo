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

# Exit immediately if a command fails, treat unset variables as errors,
# and don't hide errors in pipelines
set -euo pipefail

# ---------------------
# Configuration
# ---------------------
# Screen coordinates for capturing a specific area of the screen
CROP_X=1150          # X position (from left) to start capture
CROP_Y=640         # Y position (from top) to start capture 
CROP_WIDTH=200     # Width of capture area in pixels
CROP_HEIGHT=180     # Height of capture area in pixels

# Chinese terms to search for in the OCR results
# SEARCH_TERMS=("抄底" "卖出")  # Terms mean "bottom fishing" and "sell"
SEARCH_TERMS=("卖出")  # Term means "sell"

# Directories and files for storing screenshots and logs
SCREENSHOT_DIR="/Users/tony3/Documents/moomoo/screenshots"
LOG_FILE="/Users/tony3/Documents/moomoo/screenshots/ocr_log.txt"

# # Twilio API credentials and phone numbers for SMS messaging
# # (these are placeholders - real values need to be provided)
# TWILIO_ACCOUNT_SID="ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# TWILIO_AUTH_TOKEN="your_auth_token_here"
# TWILIO_FROM="+1XXXXXXXXXX"  # your Twilio phone number
# TWILIO_TO="+1YYYYYYYYYY"    # recipient phone number

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Paths to helper Python scripts
PY_HSV_SCRIPT="${SCRIPT_DIR}/helper_scripts/ocr_color_extract.py"  # For HSV color processing
PY_SMS_SCRIPT="${SCRIPT_DIR}/helper_scripts/send_sms_twilio.py"    # For sending SMS

# Verify that helper scripts exist and are executable
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

# Create screenshots directory if it doesn't exist
mkdir -p "$SCREENSHOT_DIR"

# Create a timestamp for the current screenshot
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")  # Format: YYYYMMDD_HHMMSS
SCREENSHOT_FILE="$SCREENSHOT_DIR/crop_${TIMESTAMP}.png"

# Take a screenshot of the specified screen region using macOS screencapture
/usr/sbin/screencapture -x -R${CROP_X},${CROP_Y},${CROP_WIDTH},${CROP_HEIGHT} "$SCREENSHOT_FILE"

# Check if screenshot was successful
if [ ! -f "$SCREENSHOT_FILE" ]; then
    echo "$(date): ERROR - Screenshot failed" >> "$LOG_FILE"
    exit 1
fi

# Function to preprocess the screenshot with different methods
# to improve OCR accuracy for text on dark backgrounds
preprocess_colored_on_black() {
    local input_file="$1"
    local base_name=$(basename "$input_file" .png)
    local dir_name=$(dirname "$input_file")
    
    # Define output file paths for each processing method
    local red_enhanced="${dir_name}/${base_name}_red_enhanced.png"
    local green_enhanced="${dir_name}/${base_name}_green_enhanced.png"
    local hsv_enhanced="${dir_name}/${base_name}_hsv_enhanced.png"
    local luma_enhanced="${dir_name}/${base_name}_luma_enhanced.png"
    local sharp_enhanced="${dir_name}/${base_name}_sharp_enhanced.png"
    local clahe_enhanced="${dir_name}/${base_name}_clahe_enhanced.png"
    
    # Increase resize to 500% and add sharpening/denoising to help tiny Chinese strokes
    magick "$input_file" -resize 500% -normalize -contrast-stretch 5%x95% -threshold 25% \
        -unsharp 0x1 -morphology close diamond:1 "$red_enhanced"
    
    magick "$input_file" -channel green -separate -resize 500% \
        -normalize -contrast-stretch 5%x95% -threshold 25% \
        -unsharp 0x1 -morphology close diamond:1 "$green_enhanced"
    
    # HSV-based extractor (existing Python helper)
    python3 "$PY_HSV_SCRIPT" "$input_file" "$hsv_enhanced"
    
    magick "$input_file" -colorspace HSL -channel lightness -separate \
        -resize 500% -normalize -contrast-stretch 15%x85% \
        -unsharp 0x1 -threshold 25% -morphology close diamond:1 "$luma_enhanced"
    
    # Additional sharpened variant (helps with broken strokes)
    magick "$input_file" -resize 500% -colorspace Gray -normalize \
        -sigmoidal-contrast 4,50% -unsharp 0x1 -morphology close diamond:1 "$sharp_enhanced"
    
    # CLAHE (local contrast) variant to bring out faint strokes (if your ImageMagick supports -clahe)
    magick "$input_file" -resize 500% -colorspace Gray -clahe 240x240+10% -unsharp 0x1 "$clahe_enhanced"
    
    # Return space-separated list of processed files (original first)
    echo "$input_file $red_enhanced $green_enhanced $hsv_enhanced $luma_enhanced $sharp_enhanced $clahe_enhanced"
}

# Call preprocessing function and store the space-separated file list into array
IFS=' ' read -r -a PROCESSED_FILES <<< "$(preprocess_colored_on_black "$SCREENSHOT_FILE")"

# Variables to collect OCR results
ALL_OCR_TEXT=""           # Will store all OCR text from all methods
FOUND_TERMS=()            # Will store unique matched terms
SUCCESSFUL_METHODS=()     # Will store which preprocessing methods found which terms

# Verify tesseract is available and chi_sim language is installed
# (Temporarily disabled: OCR/tesseract commented out to add image-matching instead)
: '
if ! command -v tesseract >/dev/null 2>&1; then
    echo "$(date): ERROR - tesseract not found in PATH" >> "$LOG_FILE"
    echo "Install tesseract (brew install tesseract)" >&2
    exit 1
fi

if ! tesseract --list-langs 2>/dev/null | grep -q '"'"'chi_sim'"'"'; then
    echo "$(date): ERROR - chi_sim language not found for tesseract" >> "$LOG_FILE"
    echo "Install chi_sim training data (brew install tesseract-lang or get traineddata)" >&2
    # continue; user may still want to run with eng only
fi

# Run OCR on each processed image
for processed_file in "${PROCESSED_FILES[@]}"; do
    if [ -f "$processed_file" ]; then
        # Extract method name from filename for logging
        if [ "$processed_file" = "$SCREENSHOT_FILE" ]; then
            method_name="original"
        else
            method_name=$(basename "$processed_file" | sed '"'"'s/.*_\(.*_enhanced\)\.png/\1/'"'"')
            # Make sure method_name has a value, use '"'"'unknown'"'"' as fallback
            if [ -z "$method_name" ]; then
                method_name="unknown"
            fi
        fi
        
        # Run Tesseract OCR with Chinese Simplified and English language support
        # Do NOT use unicode Chinese whitelist (it can make Tesseract return empty results).
        # Capture stderr to a temp file for debugging.
        OCR_TMP_BASE=$(mktemp /tmp/ocr_tmp.XXXX)
        # tesseract writes output to <base>.txt
        tesseract "$processed_file" "$OCR_TMP_BASE" -l chi_sim+eng --psm 7 --oem 1 -c preserve_interword_spaces=1 >/dev/null 2>"${OCR_TMP_BASE}.err" || true
        OCR_TEXT=$(cat "${OCR_TMP_BASE}.txt" 2>/dev/null || true)

        # If output empty, log stderr for debugging
        if [ -z "$OCR_TEXT" ]; then
            echo "$(date): DEBUG - tesseract produced no text for ${processed_file}. Stderr:" >> "$LOG_FILE"
            if [ -s "${OCR_TMP_BASE}.err" ]; then
                sed 's/^/    /' "${OCR_TMP_BASE}.err" >> "$LOG_FILE"
            else
                echo "    (no stderr captured)" >> "$LOG_FILE"
            fi
        fi

        # cleanup temp files
        rm -f "${OCR_TMP_BASE}.txt" "${OCR_TMP_BASE}.err" || true

        # Append to ALL_OCR_TEXT with proper formatting
        ALL_OCR_TEXT="${ALL_OCR_TEXT}
--- Method: ${method_name} ---
${OCR_TEXT}"

        # Check each search term against OCR text
        method_found_terms=()
        for term in "${SEARCH_TERMS[@]}"; do
            if echo "$OCR_TEXT" | grep -q "$term"; then
                method_found_terms+=("$term")  # This method found this term
                # Only add to FOUND_TERMS if not already there
                if [[ ! " ${FOUND_TERMS[@]} " =~ " ${term} " ]]; then
                    FOUND_TERMS+=("$term")
                fi
            fi
        done

        # If this method found any terms, record it
        if [ ${#method_found_terms[@]} -gt 0 ]; then
            SUCCESSFUL_METHODS+=("$method_name: ${method_found_terms[*]}")
        fi
    fi
done
'

# Placeholder: OCR disabled — perform template/image matching here instead.
# echo "$(date): OCR disabled in this run; template/image-matching should be invoked here." >> "$LOG_FILE"

# --- Begin: template/image-matching using helper_scripts/template_match.py ---
# Threshold for template matching (tune 0.60..0.80)
TEMPLATE_THRESH=0.72

# Directory containing template images (create and place templates there)
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
mkdir -p "$TEMPLATE_DIR"

# For each search term, attempt to find an associated template image.
for term in "${SEARCH_TERMS[@]}"; do
    # Map known terms to template filenames (adjust names if you use different files)
    if [ "$term" = "卖出" ]; then
        tpl="$TEMPLATE_DIR/sell_template.png"
    elif [ "$term" = "抄底" ]; then
        tpl="$TEMPLATE_DIR/bottom_template.png"
    else
        # fallback: sanitize term into filename
        safe_name=$(printf '%s' "$term" | tr -cd '[:alnum:]_')
        tpl="$TEMPLATE_DIR/${safe_name}.png"
    fi

    if [ ! -f "$tpl" ]; then
        echo "$(date): DEBUG - template not found for term '$term' at $tpl" >> "$LOG_FILE"
        continue
    fi

    DEBUG_OUT="${SCREENSHOT_DIR}/debug_match_${term}_${TIMESTAMP}.png"

    # Run template matcher; capture output JSON and exit code. allow non-zero temporarily
    set +e
    RESULT_JSON=$(python3 "${SCRIPT_DIR}/helper_scripts/template_match.py" "$tpl" "$SCREENSHOT_FILE" --thresh "$TEMPLATE_THRESH" --debug "$DEBUG_OUT" 2>&1)
    RC=$?
    set -e

    echo "$(date): DEBUG - template_match output for term '$term': $RESULT_JSON" >> "$LOG_FILE"

    if [ $RC -eq 0 ]; then
        # Found: add to FOUND_TERMS and record method with score and debug image
        FOUND_TERMS+=("$term")
        score=$(printf '%s' "$RESULT_JSON" | python3 -c 'import sys,json; j=json.load(sys.stdin); print(j.get("best",{}).get("score",""))' 2>/dev/null || echo "")
        SUCCESSFUL_METHODS+=("template_match:${term}:score=${score}:debug=${DEBUG_OUT}")
        echo "$(date): TEMPLATE MATCH found for '${term}' (score=${score}) in $SCREENSHOT_FILE; debug image: $DEBUG_OUT" >> "$LOG_FILE"
    else
        echo "$(date): TEMPLATE MATCH NOT found for '${term}' (RC=${RC})" >> "$LOG_FILE"
    fi
done
# --- End: template/image-matching ---

# Original end-of-script logic (kept but adjusted) - use FOUND_TERMS if template matcher updates it
if [ ${#FOUND_TERMS[@]} -gt 0 ]; then
    FOUND_LIST=$(IFS=', '; echo "${FOUND_TERMS[*]}")
    SUCCESSFUL_LIST=$(IFS='; '; echo "${SUCCESSFUL_METHODS[*]}")

    {
        echo "$(date): FOUND Chinese characters: $FOUND_LIST in screenshot $SCREENSHOT_FILE"
        echo "Successful methods: $SUCCESSFUL_LIST"
        echo -e "All OCR Text: $ALL_OCR_TEXT"
        echo "---"
    } >> "$LOG_FILE"
else
    # Log that no matches were found (or OCR disabled)
    echo "$(date): No target Chinese characters found in $SCREENSHOT_FILE (OCR disabled / image-match pending)" >> "$LOG_FILE"
    echo -e "All OCR Text: $ALL_OCR_TEXT" >> "$LOG_FILE"
    echo "---" >> "$LOG_FILE"
fi