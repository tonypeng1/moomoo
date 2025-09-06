#!/usr/bin/env python3
# get_crop_coords.py
# Usage: python3 get_crop_coords.py /path/to/screenshot.png

import sys
from PIL import Image
import matplotlib.pyplot as plt

if len(sys.argv) < 2:
    print("Usage: python3 get_crop_coords.py /path/to/image.png")
    sys.exit(1)

img_path = sys.argv[1]
img = Image.open(img_path)
w,h = img.size
print(f"Image size: {w} x {h} (pixels)")
fig, ax = plt.subplots()
ax.imshow(img)
ax.set_title("Click TOP-LEFT then BOTTOM-RIGHT; close window when done")
coords = []

def onclick(event):
    if event.xdata is None or event.ydata is None:
        return
    coords.append((int(event.xdata), int(event.ydata)))
    print(f"Point {len(coords)}: {coords[-1]}")
    if len(coords) >= 2:
        plt.close()

cid = fig.canvas.mpl_connect('button_press_event', onclick)
plt.show()

if len(coords) < 2:
    print("No two points selected.")
    sys.exit(1)

(x1,y1),(x2,y2) = coords[0], coords[1]
x = min(x1,x2)
y = min(y1,y2)
width = abs(x2 - x1)
height = abs(y2 - y1)

print("\nCROP values for your script:")
print(f"CROP_X={x}")
print(f"CROP_Y={y}")
print(f"CROP_WIDTH={width}")
print(f"CROP_HEIGHT={height}")
print(f"\nscreencapture -R{x},{y},{width},{height} out.png")