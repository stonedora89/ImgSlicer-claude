import cv2, numpy as np, sys, os, importlib.util
def fresh_module():
    spec=importlib.util.spec_from_file_location("det","Sources/ImgSlicer/Resources/detectors/opencv_detector.py")
    m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
def boxes_for(path):
    res={}
    for tag,val in (("ON","0"),("OFF","1")):
        os.environ["IMGSLICER_NO_GRAIN"]=val
        m=fresh_module()
        res[tag]=m.detect_boxes(path)   # boxes in original-resolution coords
    return res
def draw(path):
    img=cv2.imdecode(np.fromfile(path,dtype=np.uint8),cv2.IMREAD_COLOR)
    H,W=img.shape[:2]; s=min(1.0,1400.0/max(W,H))
    base=cv2.resize(img,(int(W*s),int(H*s)),interpolation=cv2.INTER_AREA)
    r=boxes_for(path)
    panels=[]
    for tag,color in (("OFF",(0,0,255)),("ON",(0,220,0))):
        p=base.copy()
        for b in r[tag]:
            x0,y0,x1,y1=[int(round(v*s)) for v in (b["left"],b["top"],b["right"],b["bottom"])]
            cv2.rectangle(p,(x0,y0),(x1,y1),color,2)
        cv2.putText(p,f"{tag}  n={len(r[tag])}",(6,22),cv2.FONT_HERSHEY_SIMPLEX,0.7,color,2)
        panels.append(p)
    out=f"debug-overlays/ab-{os.path.splitext(os.path.basename(path))[0]}.png"
    cv2.imwrite(out,np.vstack(panels))
    print(f"{os.path.basename(path):32s} OFF={len(r['OFF'])} ON={len(r['ON'])}  -> {out}")
for p in sys.argv[1:]: draw(p)
