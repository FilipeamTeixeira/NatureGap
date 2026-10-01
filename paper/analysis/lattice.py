import gzip, json, glob, os
import numpy as np
CELLS_OF_INTEREST={'amsterdam':['amsterdam-61262','amsterdam-59934','amsterdam-60365','amsterdam-61674'],
                   'gent':['gent-226024'],'porto':['porto-84470'],'yokohama':['yokohama-124476']}
summary={}
for city in ['porto','amsterdam','yokohama','gent']:
    d=sorted([b for b in glob.glob(f'/Users/Fil/naturegap-freshclone/pipeline-export/{city}/*/') if os.path.isdir(b)])[-1]
    fs=sorted(glob.glob(d+'cell_attributes.geojson.gz')) or sorted(glob.glob(d+'cell_attributes-part-*.geojson.gz'))
    lon=[];lat=[];nob=[];rich=[]
    detail={}
    for f in fs:
        with gzip.open(f,'rt') as fh:
            for line in fh:
                line=line.strip().rstrip(',')
                if not line.startswith('{ "type": "Feature"'): continue
                try: ft=json.loads(line)
                except Exception: continue
                p=ft['properties']; n=p.get('n_obs') or 0
                if n==0: continue
                a=np.array(ft['geometry']['coordinates'][0][:-1])
                x=a[:,0].mean(); y=a[:,1].mean()
                lon.append(x);lat.append(y);nob.append(n);rich.append(p.get('species_richness_raw') or 0)
                if p.get('cell_id') in CELLS_OF_INTEREST.get(city,[]):
                    detail[p['cell_id']]={k:p.get(k) for k in ['n_obs','species_richness_raw','observed_richness','expected_richness','ecological_residual','nature_gap_score','is_unsampled','habitat_quality_index','survey_effort_units','path_local_m','intervention_rank','n_survey_dates']}
                    detail[p['cell_id']]['lon']=round(float(x),5); detail[p['cell_id']]['lat']=round(float(y),5)
    lon=np.array(lon);lat=np.array(lat);nob=np.array(nob,dtype=float);rich=np.array(rich,dtype=float)
    tot=nob.sum()
    print('='*16,city,f'  records={tot:.0f}  cells_with_records={len(nob)}')
    for step in [0.1,0.05,0.01,0.001]:
        dx=np.abs(lon/step-np.round(lon/step))*step*111320*np.cos(np.radians(lat))
        dy=np.abs(lat/step-np.round(lat/step))*step*110540
        near=np.sqrt(dx**2+dy**2)<15
        print(f'   within 15 m of a {step}deg lattice node: cells={near.sum():6d}  records={100*nob[near].sum()/tot:6.2f}%  richness_sum={rich[near].sum():.0f}')
    for cid,v in detail.items(): print('   >>',cid,json.dumps(v))
    summary[city]={'total':float(tot),'detail':detail}
json.dump(summary,open('lattice.json','w'),indent=1)
