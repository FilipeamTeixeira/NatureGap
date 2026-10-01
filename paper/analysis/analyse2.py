import numpy as np, json
from scipy import stats as st
CITIES=['porto','amsterdam','yokohama','gent']
out={}
for c in CITIES:
    z=np.load(f'{c}.npz')
    nobs=np.nan_to_num(z['n_obs'],nan=0); sr=np.nan_to_num(z['species_richness_raw'],nan=0)
    eff=z['survey_effort_units']; S=~np.isnan(eff); U=~S
    resid=z['ecological_residual']; obs=z['observed_richness']; exp=z['expected_richness']
    path=z['path_local_m']
    d={}
    tot=nobs.sum()
    d['n_obs_total']=float(tot)
    d['obs_in_unsampled']=float(nobs[U].sum()); d['pct_obs_lost_to_effort_filter']=100*float(nobs[U].sum())/tot
    d['cells_unsampled_with_obs']=int(np.sum((nobs>0)&U))
    # concentration
    o=np.sort(nobs)[::-1]
    d['max_n_obs_single_cell']=float(o[0]); d['top10_cells_share_of_obs']=100*float(o[:10].sum())/tot
    d['top100_cells_share_of_obs']=100*float(o[:100].sum())/tot
    nz=nobs[nobs>0]
    d['cells_with_obs']=int(nz.size)
    d['gini_obs']= float(1 - 2*np.sum(np.cumsum(np.sort(nobs))/nobs.sum())/nobs.size + 1/nobs.size)
    s=np.sort(sr)[::-1]
    d['max_species_richness_cell']=float(s[0]); d['top10_species_richness']=[float(x) for x in s[:10]]
    d['cells_richness_gt_50']=int(np.sum(sr>50)); d['cells_richness_gt_100']=int(np.sum(sr>100))
    # residual = -observed check
    fin=S&np.isfinite(resid)&np.isfinite(obs)
    d['spearman_resid_vs_negobs']=float(st.spearmanr(resid[fin],-obs[fin])[0])
    d['spearman_resid_vs_expected']=float(st.spearmanr(resid[fin],exp[fin])[0])
    # share of residual rank explained: R2 of resid on expected alone (linear)
    A=np.vstack([exp[fin],np.ones(fin.sum())]).T
    b=np.linalg.lstsq(A,resid[fin],rcond=None)[0]
    pred=A@b; d['r2_resid_from_expected']=float(1-np.var(resid[fin]-pred)/np.var(resid[fin]))
    A2=np.vstack([obs[fin],np.ones(fin.sum())]).T
    b2=np.linalg.lstsq(A2,resid[fin],rcond=None)[0]; pred2=A2@b2
    d['r2_resid_from_observed']=float(1-np.var(resid[fin]-pred2)/np.var(resid[fin]))
    # zero cells dominate top residuals?
    thr=np.percentile(resid[fin],99)
    top=fin&(resid>=thr)
    d['top1pct_resid_pct_zero_records']=100*float(np.sum(sr[top]==0))/int(top.sum())
    d['top1pct_resid_mean_habitat']=float(np.nanmean(z['habitat_quality_index'][top]))
    # expected richness driven by path?
    pf=S&np.isfinite(exp)&(path>0)
    d['r2_expected_from_logpath']=float(np.corrcoef(np.log1p(path[pf]),np.log(exp[pf]))[0,1]**2)
    out[c]=d
    print('='*16,c)
    for k,v in d.items(): print('  ',k,':',v if not isinstance(v,float) else round(v,4))
json.dump(out,open('summary2.json','w'),indent=1)
