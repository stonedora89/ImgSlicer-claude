import cv2, numpy as np, sys, os, importlib.util
spec=importlib.util.spec_from_file_location("det","Sources/ImgSlicer/Resources/detectors/opencv_detector.py")
det=importlib.util.module_from_spec(spec); det.np=np; spec.loader.exec_module(det)

def colcurve(x):
    x=x.astype(np.float32); return x
def norm01(c):
    lo,hi=np.percentile(c,2),np.percentile(c,98)
    return np.clip((c-lo)/max(hi-lo,1e-6),0,1)

def run(path, frac=1.0):
    img=cv2.imdecode(np.fromfile(path,dtype=np.uint8),cv2.IMREAD_COLOR)
    H,W=img.shape[:2]; scale=min(1.0,1400.0/max(W,H))
    work=cv2.resize(img,(int(W*scale),int(H*scale)),interpolation=cv2.INTER_AREA)
    gray=cv2.cvtColor(work,cv2.COLOR_BGR2GRAY); gray=cv2.GaussianBlur(gray,(5,5),0)
    h,w=gray.shape
    g=gray.astype(np.float32)

    # (a) raw column brightness
    bright=g.mean(axis=0)

    # (b) raw local_std grain (per column mean)
    k=7
    m=cv2.blur(g,(k,k)); ms=cv2.blur(g*g,(k,k))
    ls=np.sqrt(np.maximum(ms-m*m,0)); grain_raw=ls.mean(axis=0)

    # (c) CLAHE local-contrast normalize, THEN local_std -> reveals dark-frame grain
    clahe=cv2.createCLAHE(clipLimit=3.0,tileGridSize=(8,8))
    gn=clahe.apply(gray).astype(np.float32)
    mn=cv2.blur(gn,(k,k)); msn=cv2.blur(gn*gn,(k,k))
    lsn=np.sqrt(np.maximum(msn-mn*mn,0)); grain_clahe=lsn.mean(axis=0)

    # (d) "structure presence": fraction of rows in this column that are NOT locally flat
    structured=(lsn>8).mean(axis=0)   # after CLAHE, flat film base stays ~0

    # (e) current separator profile
    prof=det.moving_average(det.separator_profile(gray,"x"),max(3,w//180))
    thr=max(0.22,min(0.80,float(det.np_median(prof)+det.np_std(prof)*1.2)))
    segs=det.merge_segments(det.segments(prof,thr,max(2,w//420),True),max(2,w//260))
    cuts=[(a+b)//2 for a,b in segs]

    panelH=110; curves=[("brightness",bright),("grain_raw",grain_raw),
        ("grain_CLAHE",grain_clahe),("structure% (low=film-base)",structured),
        ("separator_profile",prof)]
    canvas=np.full((h+panelH*len(curves)+20,w,3),20,np.uint8); canvas[:h]=work
    for c in cuts: cv2.line(canvas,(c,0),(c,h),(0,0,255),2)
    cols=[(0,255,255),(0,180,255),(0,255,120),(255,160,0),(0,255,0)]
    for i,(lab,cur) in enumerate(curves):
        y0=h+i*panelH; n=norm01(cur)
        cv2.putText(canvas,lab,(5,y0+14),cv2.FONT_HERSHEY_SIMPLEX,0.45,(255,255,255),1)
        pts=[(x,y0+panelH-2-int(n[x]*(panelH-22))) for x in range(w)]
        for j in range(1,w): cv2.line(canvas,pts[j-1],pts[j],cols[i],1)
        for c in cuts: cv2.line(canvas,(c,y0),(c,y0+panelH),(60,60,120),1)
    out=f"debug-overlays/g2-{os.path.splitext(os.path.basename(path))[0]}.png"
    cv2.imwrite(out,canvas); print("wrote",out,"cuts",cuts)

for p in sys.argv[1:]: run(p)
