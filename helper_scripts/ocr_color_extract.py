#!/usr/bin/env python3
"""
ocr_color_extract.py

Separate Python script for HSV-based extraction targeted at colored text on dark backgrounds.

Usage:
    python3 ocr_color_extract.py input_image.png output_image.png

Produces a grayscale, enlarged image (white text on black background) optimized for Tesseract OCR.
"""

import sys
import cv2
import numpy as np

def extract_colored_on_dark(input_path: str, output_path: str) -> int:
    """
    Read input image, detect red/green colored text on dark background using HSV masks,
    apply morphology to clean the mask, produce white-on-black, grayscale, and resize ×4.
    Save to output_path.

    Returns:
        0 on success, non-zero on failure.
    """
    # Read image
    img = cv2.imread(input_path)
    if img is None:
        sys.stderr.write(f"Error: Could not read image '{input_path}'\n")
        return 1

    # Convert to HSV for color segmentation
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)

    # Red detection - account for hue wrap-around by using two ranges
    # These thresholds are tuned for bright colored text on dark backgrounds.
    red_lower1 = np.array([0, 100, 100])
    red_upper1 = np.array([10, 255, 255])
    red_lower2 = np.array([170, 100, 100])
    red_upper2 = np.array([180, 255, 255])
    red_mask1 = cv2.inRange(hsv, red_lower1, red_upper1)
    red_mask2 = cv2.inRange(hsv, red_lower2, red_upper2)
    red_mask = cv2.bitwise_or(red_mask1, red_mask2)

    # Green detection
    green_lower = np.array([40, 100, 100])
    green_upper = np.array([80, 255, 255])
    green_mask = cv2.inRange(hsv, green_lower, green_upper)

    # Combine masks
    combined_mask = cv2.bitwise_or(red_mask, green_mask)

    # Morphological operations to remove noise and close gaps
    kernel = np.ones((2, 2), np.uint8)
    combined_mask = cv2.morphologyEx(combined_mask, cv2.MORPH_CLOSE, kernel)
    combined_mask = cv2.morphologyEx(combined_mask, cv2.MORPH_OPEN, kernel)

    # Optionally apply a slight blur to smooth edges (comment/uncomment as needed)
    # combined_mask = cv2.GaussianBlur(combined_mask, (3, 3), 0)

    # Create white text on black background
    result = np.zeros_like(img)
    result[combined_mask > 0] = [255, 255, 255]

    # Convert to grayscale
    gray_result = cv2.cvtColor(result, cv2.COLOR_BGR2GRAY)

    # Resize for better OCR results (Tesseract benefits from larger glyphs)
    gray_result = cv2.resize(gray_result, None, fx=4, fy=4, interpolation=cv2.INTER_CUBIC)

    # Additional morphological close to improve character connectivity
    kernel2 = np.ones((2, 2), np.uint8)
    gray_result = cv2.morphologyEx(gray_result, cv2.MORPH_CLOSE, kernel2)

    # Write output
    ok = cv2.imwrite(output_path, gray_result)
    if not ok:
        sys.stderr.write(f"Error: Could not write output image to '{output_path}'\n")
        return 2

    return 0

def main(argv):
    if len(argv) != 3:
        sys.stderr.write("Usage: python3 ocr_color_extract.py input_image.png output_image.png\n")
        return 2

    input_path = argv[1]
    output_path = argv[2]
    ret = extract_colored_on_dark(input_path, output_path)
    return ret

if __name__ == "__main__":
    sys.exit(main(sys.argv))