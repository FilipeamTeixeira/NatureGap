import gzip, json, glob, os, sys, math
import numpy as np

CITIES = ['porto','amsterdam','yokohama','gent']
NUM = ['expected_richness','effort_corrected_richness','survey_effort_units','ecological_residual',
       'corridor_importance','betweenness_centrality','intervention_score','rank_stability',
       'habitat_quality_index','species_richness_raw','observed_richness','n_obs','path_local_m',
       'nature_gap_score','veg_fraction','tree_cover','heat_exposure','noise','disturbance_index',
       'traffic_exposure','water_proximity','light_pollution','n_survey_dates','ndvi_texture','land_use_green']

def files_for(city):
    base = glob.glob(f'pipeline-export/{city}/*/')
    base = [b for b in base if os.path.isdir(b)]
    base.sort()
    d = base[-1]
    fs = sorted(glob.glob(d+'cell_attributes.geojson.gz')) or sorted(glob.glob(d+'cell_attributes-part-*.geojson.gz'))
    return d, fs

out = {}
for city in CITIES:
    d, fs = files_for(city)
    cols = {k: [] for k in NUM}
    unsampled = 0; total = 0
    taxa = {'plant':0,'bird':0,'insect':0,'mammal':0,'fungi':0}
    taxa_cells = {'plant':0,'bird':0,'insect':0,'mammal':0,'fungi':0}
    for f in fs:
        with gzip.open(f,'rt') as fh:
            for line in fh:
                line = line.strip().rstrip(',')
                if not line.startswith('{ "type": "Feature"'): continue
                try: feat = json.loads(line)
                except Exception: continue
                p = feat['properties']
                total += 1
                if p.get('is_unsampled'): unsampled += 1
                for k in NUM:
                    v = p.get(k)
                    cols[k].append(np.nan if v is None else float(v))
                for s in (p.get('species') or []):
                    t = s.get('type'); c = s.get('count') or 0
                    if t in taxa:
                        taxa[t] += c
                        if c > 0: taxa_cells[t] += 1
    arr = {k: np.array(v, dtype=float) for k,v in cols.items()}
    out[city] = dict(dir=d, total=total, unsampled=unsampled, taxa=taxa, taxa_cells=taxa_cells,
                     arrays={k: v for k,v in arr.items()})
    np.savez_compressed(f'/private/tmp/claude-501/-Users-Fil-naturegap-freshclone/e6fca359-c6e8-4097-8d25-cbd1604ad874/scratchpad/{city}.npz', **arr)
    print(f'{city}: total={total} unsampled={unsampled} taxa={taxa}', flush=True)
    json.dump(dict(dir=d,total=total,unsampled=unsampled,taxa=taxa,taxa_cells=taxa_cells),
              open(f'/private/tmp/claude-501/-Users-Fil-naturegap-freshclone/e6fca359-c6e8-4097-8d25-cbd1604ad874/scratchpad/{city}_meta.json','w'), indent=1)
