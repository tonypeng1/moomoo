import sys
import cv2
import numpy as np
import json
from pathlib import Path

def load_gray(path):
    im = cv2.imdecode(np.fromfile(str(path), dtype=np.uint8), cv2.IMREAD_UNCHANGED)
    if im is None:
        raise FileNotFoundError(path)
    if im.ndim == 3:
        im = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY)
    return im

def edge_image(im):
    im_blur = cv2.GaussianBlur(im, (3,3), 0)
    return cv2.Canny(im_blur, 50, 150)

def multi_scale_template_search(large, templ, scales=(0.5,1.5,0.05), method=cv2.TM_CCOEFF_NORMED):
    best = {"score": -1.0}
    h0, w0 = templ.shape[:2]
    min_s, max_s, step = scales
    s = min_s
    while s <= max_s + 1e-9:
        th = max(2, int(round(h0 * s)))
        tw = max(2, int(round(w0 * s)))
        if th >= large.shape[0] or tw >= large.shape[1]:
            s += step
            continue
        resized = cv2.resize(templ, (tw, th), interpolation=cv2.INTER_AREA)
        res = cv2.matchTemplate(large, resized, method)
        min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(res)
        score = max_val if method in (cv2.TM_CCOEFF_NORMED, cv2.TM_CCORR_NORMED) else -min_val
        loc = max_loc
        if score > best["score"]:
            best = {"score": float(score), "scale": float(s), "w": tw, "h": th, "x": int(loc[0]), "y": int(loc[1])}
        s += step
    return best

def main():
    if len(sys.argv) < 3:
        print("Usage: template_match.py <template.png> <image.png> [--thresh 0.70] [--debug out_debug.png]")
        return 2
    tpl_path = Path(sys.argv[1])
    img_path = Path(sys.argv[2])
    thresh = 0.70
    debug_out = None
    args = sys.argv[3:]
    i = 0
    while i < len(args):
        if args[i] == "--thresh":
            i += 1; thresh = float(args[i])
        elif args[i] == "--debug":
            i += 1; debug_out = args[i]
        i += 1

    large = load_gray(img_path)
    templ = load_gray(tpl_path)

    large_e = edge_image(large)
    templ_e = edge_image(templ)

    best = multi_scale_template_search(large_e, templ_e, scales=(0.4,1.6,0.05))

    out = {"found": False, "best": best, "threshold": thresh}
    if best["score"] >= thresh:
        out["found"] = True
        out["match_box"] = {"x": best["x"], "y": best["y"], "w": best["w"], "h": best["h"]}

        if debug_out:
            color = cv2.cvtColor(large, cv2.COLOR_GRAY2BGR)
            cv2.rectangle(color, (best["x"], best["y"]), (best["x"]+best["w"], best["y"]+best["h"]), (0,255,0), 2)
            ext = Path(debug_out).suffix or ".png"
            _, buf = cv2.imencode(ext, color)
            buf.tofile(str(debug_out))

        print(json.dumps(out, ensure_ascii=False))
        sys.exit(0)
    else:
        print(json.dumps(out, ensure_ascii=False))
        sys.exit(1)

if __name__ == "__main__":
    main()