import numpy as np, json
CITIES=['porto','amsterdam','yokohama','gent']
print(f"{'city':<10} {'lambda':>9} {'rho':>7} {'corr(R,-O) pred':>16} {'measured':>10}")
res={}
for c in CITIES:
    z=np.load(f'{c}.npz')
    eff=z['survey_effort_units']; S=np.isfinite(eff)&(eff>0)
    E=z['expected_richness']; O=z['observed_richness']
    S=S&np.isfinite(E)&np.isfinite(O)
    E=E[S]; O=O[S]; R=E-O
    lam=np.var(E)/np.var(O); rho=np.corrcoef(E,O)[0,1]
    pred=(1-rho*np.sqrt(lam))/np.sqrt(1+lam-2*rho*np.sqrt(lam))
    meas=np.corrcoef(R,-O)[0,1]
    print(f"{c:<10} {lam:9.5f} {rho:7.3f} {pred:16.4f} {meas:10.4f}")
    res[c]=dict(lam=float(lam),rho=float(rho),pred=float(pred),meas=float(meas),
                var_E=float(np.var(E)),var_O=float(np.var(O)),var_R=float(np.var(R)))
print()
print("lambda needed for corr(R,-O)^2 <= 0.5 at rho=0 :", round(float(1/1),4), "-> lam=1")
for target in [0.9,0.7,0.5]:
    # solve for rho=0: corr = 1/sqrt(1+lam) -> lam = 1/corr^2 - 1
    print(f"  corr(R,-O)={target}: lambda = {1/target**2-1:.3f} (at rho=0)")
json.dump(res,open('theory.json','w'),indent=1)

# locate the extreme cells
import gzip, glob, os
for city in ['amsterdam','gent','porto','yokohama']:
    d=sorted([b for b in glob.glob(f'/Users/Fil/naturegap-freshclone/pipeline-export/{city}/*/') if os.path.isdir(b)])[-1]
    fs=sorted(glob.glob(d+'cell_attributes.geojson.gz')) or sorted(glob.glob(d+'cell_attributes-part-*.geojson.gz'))
    best=[]
    for f in fs:
        with gzip.open(f,'rt') as fh:
            for line in fh:
                line=line.strip().rstrip(',')
                if not line.startswith('{ "type": "Feature"'): continue
                try: ft=json.loads(line)
                except Exception: continue
                p=ft['properties']; n=p.get('n_obs') or 0
                if n>500:
                    ring=ft['geometry']['coordinates'][0]; a=np.array(ring[:-1])
                    best.append((n,p.get('species_richness_raw'),round(a[:,0].mean(),5),round(a[:,1].mean(),5),p.get('cell_id'),p.get('park_name')))
    best.sort(reverse=True)
    print(f"\n{city}: cells with >500 records = {len(best)}")
    for b in best[:5]: print('   n_obs=%-7d richness=%-5s lon=%s lat=%s %s' % b[:5])
