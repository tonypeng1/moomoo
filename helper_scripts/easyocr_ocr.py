import sys
import easyocr

if len(sys.argv) < 2:
    print("Usage: easyocr_ocr.py <image_path>")
    sys.exit(1)

image_path = sys.argv[1]
reader = easyocr.Reader(['ch_sim', 'en'], gpu=False)
results = reader.readtext(image_path, detail=0)
print('\n'.join(results))