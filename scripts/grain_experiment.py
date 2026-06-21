import cv2, numpy as np, sys, os
sys.path.insert(0, 'Sources/ImgSlicer/Resources/detectors')
import importlib.util
spec = importlib.util.spec_from_file_location("det", "Sources/ImgSlicer/Resources/detectors/opencv_detector.py")
det = importlib.util.module_from_spec(spec)
det.np = np
spec.loader.exec_module(det)

def local_std(g, k=7):
    g=g.astype(np.float32)
    m=cv2.blur(g,(k,k)); ms=cv2.blur(g*g,(k,k))
    return np.sqrt(np.maximum(ms-m*m,0.0))

def run(path):
    img = cv2.imdecode(np.fromfile(path,dtype=np.uint8), cv2.IMREAD_COLOR)
    H,W = img.shape[:2]
    scale = min(1.0, 1400.0/max(W,H))
    work = cv2.resize(img,(int(W*scale),int(H*scale)),interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(work, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray,(5,5),0)
    h,w = gray.shape

    # current separator profile along x (vertical gutters)
    prof = det.moving_average(det.separator_profile(gray,"x"), max(3,w//180))
    thr  = max(0.22,min(0.80,float(det.np_median(prof)+det.np_std(prof)*1.2)))
    segs = det.merge_segments(det.segments(prof,thr,max(2,w//420),True), max(2,w//260))
    cuts = [(a+b)//2 for a,b in segs]

    # grain signal (per column): local_std normalized against strip's flat floor
    ls = local_std(gray,7)                       # HxW
    col_std = ls.mean(axis=0)                     # per column
    floor = np.percentile(ls, 30)                 # below this ~ film base / flat
    grain = np.clip((col_std - floor)/(floor+1e-6), 0, 1.5)
    grain = grain/ max(grain.max(),1e-6)          # 0..1 per column

    # also brightness per column for reference
    colL = gray.mean(axis=0)/255.0

    # ---- render diagnostic ----
    panelH = 120
    canvas = np.full((h + panelH*3 + 30, w, 3), 20, np.uint8)
    canvas[:h] = work
    for c in cuts:
        cv2.line(canvas,(c,0),(c,h),(0,0,255),2)
    def plot(curve, y0, color, label):
        cv2.putText(canvas,label,(5,y0+14),cv2.FONT_HERSHEY_SIMPLEX,0.45,(255,255,255),1)
        pts=[(x, y0+panelH-2-int(np.clip(curve[x],0,1)*(panelH-20))) for x in range(w)]
        for i in range(1,w):
            cv2.line(canvas,pts[i-1],pts[i],color,1)
        for c in cuts:
            cv2.line(canvas,(c,y0),(c,y0+panelH),(0,0,120),1)
    y=h+10
    # normalize prof to 0..1 for plotting
    pn = np.clip(prof/max(prof.max(),1e-6),0,1)
    plot(pn,           y,            (0,255,0),  "separator_profile (green)")
    plot(grain,        y+panelH,     (0,180,255),"grain energy (orange)")
    plot(colL,         y+panelH*2,   (200,200,0),"column brightness (cyan)")
    out=f"debug-overlays/grain-{os.path.splitext(os.path.basename(path))[0]}.png"
    cv2.imwrite(out, canvas)
    print("wrote", out, "cuts@", cuts, "thr", round(thr,3))

for p in sys.argv[1:]:
    run(p)
