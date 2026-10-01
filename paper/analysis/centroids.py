import gzip, json, glob, os
import numpy as np
for city in ['porto','amsterdam','yokohama','gent']:
    d=sorted([b for b in glob.glob(f'/Users/Fil/naturegap-freshclone/pipeline-export/{city}/*/') if os.path.isdir(b)])[-1]
    fs=sorted(glob.glob(d+'cell_attributes.geojson.gz')) or sorted(glob.glob(d+'cell_attributes-part-*.geojson.gz'))
    xs=[];ys=[]
    for f in fs:
        with gzip.open(f,'rt') as fh:
            for line in fh:
                line=line.strip().rstrip(',')
                if not line.startswith('{ "type": "Feature"'): continue
                try: ft=json.loads(line)
                except Exception: continue
                ring=ft['geometry']['coordinates'][0]
                a=np.array(ring[:-1] if len(ring)>1 else ring)
                xs.append(a[:,0].mean()); ys.append(a[:,1].mean())
    np.savez_compressed(f'{city}_xy.npz', x=np.array(xs), y=np.array(ys))
    print(city, len(xs), flush=True)
