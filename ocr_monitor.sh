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
# Usage: ./ocr_monitor.sh [interval_minutes]
#   interval_minutes: Optional. How often to run the OCR check (in minutes)
#

# Exit immediately if a command fails, treat unset variables as errors,
# and don't hide errors in pipelines
set -euo pipefail

# Function to display usage information
show_usage() {
    echo "Usage: $(basename "$0") [interval_minutes]"
    echo "  interval_minutes: Optional. How often to run the OCR check (in minutes)"
    echo "  If interval is not specified, the script will run once and exit."
}

# Function to handle script termination
cleanup() {
    echo "Stopping OCR monitor..."
    exit 0
}

# Set up trap to handle Ctrl+C gracefully
trap cleanup SIGINT SIGTERM

# Check if interval parameter was provided
INTERVAL_MINUTES=""
if [ $# -gt 0 ]; then
    # Validate that the input is a positive number
    if [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; then
        INTERVAL_MINUTES="$1"
        INTERVAL_SECONDS=$((INTERVAL_MINUTES * 60))
        echo "OCR monitor will run every $INTERVAL_MINUTES minute(s). Press Ctrl+C to stop."
    else
        echo "Error: Interval must be a positive number."
        show_usage
        exit 1
    fi
fi

# ---------------------
# Configuration
# ---------------------
# Screen coordinates for capturing a specific area of the screen
CROP_X=1150          # X position (from left) to start capture
CROP_Y=620         # Y position (from top) to start capture 
CROP_WIDTH=270     # Width of capture area in pixels
CROP_HEIGHT=190     # Height of capture area in pixels

# Chinese terms to search for in the OCR results
SEARCH_TERMS=("抄底" "卖出")  # Terms mean "bottom fishing" and "sell"
# SEARCH_TERMS=("卖出") 

# Directories and files for storing screenshots and logs
SCREENSHOT_DIR="/Users/tony3/Documents/moomoo/screenshots"
LOG_FILE="/Users/tony3/Documents/moomoo/screenshots/ocr_log.txt"

# # Twilio API credentials and phone numbers for SMS messaging
# # (these are placeholders - real values need to be provided)
# TWILIO_ACCOUNT_SID="ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# TWILIO_AUTH_TOKEN="your_auth_token_here"
# TWILIO_FROM="+1XXXXXXXXXX"  # your Twilio phone number
# TWILIO_TO="+1YYYYYYYYYY"    # recipient phone number

# Vonage (Nexmo) API credentials and numbers
# VONAGE_API_KEY="your_api_key_here"
# VONAGE_API_SECRET="your_api_secret_here"
# VONAGE_FROM="YourSender"    # sender ID (alphanumeric or number depending on region)
# VONAGE_TO="+1YYYYYYYYYY"    # recipient phone number

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Paths to helper Python scripts
PY_HSV_SCRIPT="${SCRIPT_DIR}/helper_scripts/ocr_color_extract.py"  # For HSV color processing
# Use the official Vonage helper
PY_SMS_SCRIPT="${SCRIPT_DIR}/helper_scripts/send_sms_vonage.py"    # For sending SMS

# Path to EasyOCR helper script
PY_EASYOCR_SCRIPT="${SCRIPT_DIR}/helper_scripts/easyocr_ocr.py"

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

if [ ! -f "$PY_EASYOCR_SCRIPT" ]; then
    echo "$(date): ERROR - EasyOCR script not found at $PY_EASYOCR_SCRIPT" >> "$LOG_FILE"
    echo "Make sure $PY_EASYOCR_SCRIPT exists."
    exit 1
fi

# Load environment variables from .env file if it exists
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
fi

# Create screenshots directory if it doesn't exist
mkdir -p "$SCREENSHOT_DIR"

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
    
    # 1. Extract and enhance red channel (good for red text on dark background)
    magick "$input_file" -resize 300% -normalize -contrast-stretch 5%x95% -threshold 25% \
        -morphology close diamond:1 "$red_enhanced"
    
    # 2. Extract and enhance green channel (good for green text on dark background)
    magick "$input_file" -channel green -separate +channel \
        -resize 300% -normalize -contrast-stretch 5%x95% -threshold 25% \
        -morphology close diamond:1 "$green_enhanced"
    
    # 3. Use Python script for HSV-based color extraction (targeting specific hue ranges)
    python3 "$PY_HSV_SCRIPT" "$input_file" "$hsv_enhanced"
    
    # 4. Enhance luma (brightness) for better OCR of light text on dark background
    magick "$input_file" -colorspace HSL -channel lightness -separate \
        -resize 300% -normalize -contrast-stretch 15%x85% \
        -threshold 25% -morphology close diamond:1 "$luma_enhanced"
    
    # Return space-separated list of processed files
    echo "$red_enhanced $green_enhanced $hsv_enhanced $luma_enhanced"
}

# Function containing the main OCR monitoring logic
run_ocr_monitor() {
    # Create a timestamp for the current screenshot
    local TIMESTAMP=$(date "+%Y%m%d_%H%M%S")  # Format: YYYYMMDD_HHMMSS
    local SCREENSHOT_FILE="$SCREENSHOT_DIR/crop_${TIMESTAMP}.png"

    # Take a screenshot of the specified screen region using macOS screencapture
    /usr/sbin/screencapture -x -R${CROP_X},${CROP_Y},${CROP_WIDTH},${CROP_HEIGHT} "$SCREENSHOT_FILE"

    # Check if screenshot was successful
    if [ ! -f "$SCREENSHOT_FILE" ]; then
        echo "$(date): ERROR - Screenshot failed" >> "$LOG_FILE"
        return 1
    fi

    # Call preprocessing function and store the space-separated file list into array
    IFS=' ' read -r -a PROCESSED_FILES <<< "$(preprocess_colored_on_black "$SCREENSHOT_FILE")"

    # Variables to collect OCR results
    local ALL_OCR_TEXT=""           # Will store all OCR text from all methods
    local FOUND_TERMS=()            # Will store unique matched terms - initialize empty array
    local SUCCESSFUL_METHODS=()     # Will store which preprocessing methods found which terms

    # Run OCR on each processed image
    for processed_file in "${PROCESSED_FILES[@]}"; do
        if [ -f "$processed_file" ]; then
            # Run EasyOCR via Python helper script
            local OCR_TEXT=$(python3 "$PY_EASYOCR_SCRIPT" "$processed_file" 2>/dev/null || true)
            
            # Extract method name from filename for logging
            local method_name=$(basename "$processed_file" | sed 's/.*_\([^_]*_[^.]*\)\.png/\1/')
            ALL_OCR_TEXT="$ALL_OCR_TEXT\n--- Method: $method_name ---\n$OCR_TEXT"

            # Check each search term against OCR text
            local method_found_terms=()
            for term in "${SEARCH_TERMS[@]}"; do
                if echo "$OCR_TEXT" | grep -q "$term"; then
                    method_found_terms+=("$term")  # This method found this term
                    if [ ${#FOUND_TERMS[@]} -eq 0 ] || [[ ! " ${FOUND_TERMS[*]} " =~ " ${term} " ]]; then
                        FOUND_TERMS+=("$term")
                    fi
                fi
            done

            if [ ${#method_found_terms[@]} -gt 0 ]; then
                SUCCESSFUL_METHODS+=("$method_name: ${method_found_terms[*]}")
            fi
        fi
    done

    # If any target terms were found
    if [ ${#FOUND_TERMS[@]} -gt 0 ]; then
        # Create comma-separated list of found terms
        local FOUND_LIST=$(IFS=', '; echo "${FOUND_TERMS[*]}")
        # Create semicolon-separated list of successful methods and what they found
        local SUCCESSFUL_LIST=$(IFS='; '; echo "${SUCCESSFUL_METHODS[*]}")

        # Log the findings
        {
            echo "$(date): FOUND Chinese characters: $FOUND_LIST in screenshot $SCREENSHOT_FILE"
            echo "Successful methods: $SUCCESSFUL_LIST"
            echo -e "All OCR Text: $ALL_OCR_TEXT"
            echo "---"
        } >> "$LOG_FILE"

        # Build SMS message (keeping it concise due to SMS character limits)
        local SMS_BODY="Moomoo Alert: found [$FOUND_LIST]"

        # Escape quotes in SMS message to prevent command injection
        local ESCAPED_BODY=$(printf '%s' "$SMS_BODY" | sed 's/"/\\"/g')
        
        # Send SMS via Vonage using Python helper script
        python3 "$PY_SMS_SCRIPT" "$VONAGE_API_KEY" "$VONAGE_API_SECRET" "$VONAGE_FROM" "$VONAGE_TO" "$ESCAPED_BODY" >/dev/null 2>>"$LOG_FILE" || {
            echo "$(date): ERROR - Failed to send SMS via Vonage" >> "$LOG_FILE"
        }

        # Display a macOS notification
        osascript -e "display notification \"Found Chinese characters: $FOUND_LIST\" with title \"OCR Alert - SMS Sent\""

        # Log SMS attempt
        echo "$(date): SMS attempted to $VONAGE_TO for terms: $FOUND_LIST" >> "$LOG_FILE"
    else
        # Log that no matches were found
        echo "$(date): No target Chinese characters found in $SCREENSHOT_FILE (dark background processing)" >> "$LOG_FILE"
        echo -e "All OCR Text: $ALL_OCR_TEXT" >> "$LOG_FILE"
        echo "---" >> "$LOG_FILE"
    fi
}

# Main execution logic
if [ -z "$INTERVAL_MINUTES" ]; then
    # Run once if no interval was specified
    echo "Running OCR monitor once..."
    run_ocr_monitor
else
    # Run continuously with the specified interval
    while true; do
        echo "$(date): Running OCR check..."
        run_ocr_monitor
        echo "Next check in $INTERVAL_MINUTES minute(s). Press Ctrl+C to stop."
        sleep "$INTERVAL_SECONDS"
    done
fi