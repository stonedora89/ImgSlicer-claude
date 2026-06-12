# ImgSlicer Algorithm Comparison

- Folder: `/Users/air/Documents/ImgSlicer/imgs`
- Business profile: `胶片扫描`
- Images: 4
- Python runner: `/Users/air/Documents/ImgSlicer/.venv/bin/python3`
- Python override: set `IMGSLICER_PYTHON=/path/to/python` when running the command
- Count match: 0 / 0
- Average matched IoU: 0.000
- Swift total: 2.75s
- Python total: 0.27s

| Image | Swift | Python | Avg IoU | Swift Time | Python Time | Notes |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 微信图片_20260607181336_5_9.jpg | 11 | 0 | 0.000 | 0.20s | 0.07s | Python error: Traceback (most recent call last):<br>  File "/Users/air/Documents/ImgSlicer/app.py", line 15, in <module><br>    import numpy as np<br>ModuleNotFoundError: No module named 'numpy' |
| 微信图片_20260607181337_6_9.jpg | 3 | 0 | 0.000 | 0.89s | 0.07s | Python error: Traceback (most recent call last):<br>  File "/Users/air/Documents/ImgSlicer/app.py", line 15, in <module><br>    import numpy as np<br>ModuleNotFoundError: No module named 'numpy' |
| 微信图片_20260607181338_7_9.jpg | 3 | 0 | 0.000 | 1.54s | 0.07s | Python error: Traceback (most recent call last):<br>  File "/Users/air/Documents/ImgSlicer/app.py", line 15, in <module><br>    import numpy as np<br>ModuleNotFoundError: No module named 'numpy' |
| 微信图片_20260607181340_8_9.jpg | 12 | 0 | 0.000 | 0.11s | 0.07s | Python error: Traceback (most recent call last):<br>  File "/Users/air/Documents/ImgSlicer/app.py", line 15, in <module><br>    import numpy as np<br>ModuleNotFoundError: No module named 'numpy' |

## Box Details

### 微信图片_20260607181336_5_9.jpg
Python error: `Traceback (most recent call last):
  File "/Users/air/Documents/ImgSlicer/app.py", line 15, in <module>
    import numpy as np
ModuleNotFoundError: No module named 'numpy'`
- Swift: [3, 1, 58, 40], [56, 1, 115, 40], [173, 1, 230, 40], [230, 1, 287, 40], [290, 1, 345, 40], [3, 53, 61, 93], [62, 53, 119, 93], [121, 53, 177, 93], [178, 53, 227, 93], [235, 53, 292, 93], [292, 53, 349, 93]
- Python: 

### 微信图片_20260607181337_6_9.jpg
Python error: `Traceback (most recent call last):
  File "/Users/air/Documents/ImgSlicer/app.py", line 15, in <module>
    import numpy as np
ModuleNotFoundError: No module named 'numpy'`
- Swift: [40, 0, 917, 921], [40, 991, 917, 1858], [40, 1920, 917, 2789]
- Python: 

### 微信图片_20260607181338_7_9.jpg
Python error: `Traceback (most recent call last):
  File "/Users/air/Documents/ImgSlicer/app.py", line 15, in <module>
    import numpy as np
ModuleNotFoundError: No module named 'numpy'`
- Swift: [37, 63, 919, 927], [34, 1030, 916, 1894], [31, 1991, 959, 2850]
- Python: 

### 微信图片_20260607181340_8_9.jpg
Python error: `Traceback (most recent call last):
  File "/Users/air/Documents/ImgSlicer/app.py", line 15, in <module>
    import numpy as np
ModuleNotFoundError: No module named 'numpy'`
- Swift: [2, 3, 59, 43], [62, 3, 116, 43], [117, 3, 173, 43], [176, 3, 231, 43], [243, 3, 288, 43], [289, 3, 346, 43], [2, 55, 60, 95], [62, 55, 117, 95], [117, 55, 175, 95], [175, 55, 231, 95], [235, 55, 286, 95], [290, 55, 347, 95]
- Python: 