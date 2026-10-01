import numpy as np, json
from scipy import stats as st
CITIES=['porto','amsterdam','yokohama','gent']
def q(a,p): 
    a=a[np.isfinite(a)]
    return float(np.percentile(a,p)) if a.size else float('nan')
res={}
for c in CITIES:
    z=np.load(f'{c}.npz'); m=json.load(open(f'{c}_meta.json'))
    sampled = ~np.isnan(z['survey_effort_units'])
    n=m['total']; ns=int(sampled.sum())
    sr = z['species_richness_raw']; obs=z['observed_richness']; exp=z['expected_richness']
    resid=z['ecological_residual']; ci=z['corridor_importance']; hq=z['habitat_quality_index']
    ngs=z['nature_gap_score']; iscore=z['intervention_score']; rstab=z['rank_stability']
    nobs=z['n_obs']; path=z['path_local_m']; eff=z['survey_effort_units']
    S=sampled
    fin = S & np.isfinite(resid) & np.isfinite(exp)
    d={}
    d['cells_total']=n; d['cells_sampled']=ns; d['pct_sampled']=100*ns/n
    d['n_obs_total']=float(np.nansum(nobs))
    d['cells_with_obs']=int(np.nansum(nobs>0))
    d['pct_cells_with_obs']=100*float(np.nansum(nobs>0))/n
    d['sampled_zero_richness_pct']=100*float(np.sum((sr[S]==0)))/ns
    d['sampled_richness_mean']=float(np.nanmean(sr[S]))
    d['sampled_richness_max']=float(np.nanmax(sr[S]))
    d['sampled_richness_p99']=q(sr[S],99)
    d['obs_richness_mean']=float(np.nanmean(obs[S]))
    d['obs_richness_median']=q(obs[S],50)
    d['exp_richness_mean']=float(np.nanmean(exp[S]))
    d['exp_richness_median']=q(exp[S],50)
    d['resid_mean']=float(np.nanmean(resid[fin])); d['resid_sd']=float(np.nanstd(resid[fin]))
    d['resid_median']=q(resid[fin],50)
    d['resid_pct_positive']=100*float(np.sum(resid[fin]>0))/int(fin.sum())
    # correlation residual vs expected
    d['corr_resid_expected']=float(np.corrcoef(resid[fin],exp[fin])[0,1])
    d['corr_resid_observed']=float(np.corrcoef(resid[fin],obs[fin])[0,1])
    # variance decomposition: var(resid) explained by expected vs observed
    d['var_resid']=float(np.var(resid[fin])); d['var_exp']=float(np.var(exp[fin])); d['var_obs']=float(np.var(obs[fin]))
    d['obs_share_resid_var']=100*float(np.var(obs[fin]))/float(np.var(resid[fin]))
    # effort entanglement
    pf = S & np.isfinite(path) & np.isfinite(exp) & (path>0)
    d['corr_expected_logpath']=float(st.spearmanr(np.log1p(path[pf]),exp[pf])[0])
    d['corr_resid_logpath']=float(st.spearmanr(np.log1p(path[pf]),resid[pf])[0])
    d['corr_obsrich_logpath']=float(st.spearmanr(np.log1p(path[pf]),obs[pf])[0])
    d['corr_rawrich_logpath']=float(st.spearmanr(np.log1p(path[pf]),sr[pf])[0])
    ngf = np.isfinite(ngs)
    d['corr_ngs_logpath']=float(st.spearmanr(np.log1p(path[ngf&pf]),ngs[ngf&pf])[0])
    # corridor importance
    cif = np.isfinite(ci)
    d['ci_cells_finite']=int(cif.sum())
    d['ci_pct_zero_of_sampled']=100*float(np.sum(np.nan_to_num(ci[S],nan=0.0)==0))/ns
    d['ci_median_nonzero']=q(ci[cif&(ci>0)],50)
    # habitat
    for p in [5,25,50,75,95]:
        d[f'hq_p{p}']=q(hq[np.isfinite(hq)],p)
    d['hq_iqr']=d['hq_p75']-d['hq_p25']
    # nature gap score bands
    v=ngs[ngf]
    bands=[('much-better',-1e18,-15),('better',-15,-5),('as-expected',-5,10),('worse',10,20),('much-worse',20,1e18)]
    d['ngs_bands']={nm:100*float(np.sum((v>=lo)&(v<hi)))/v.size for nm,lo,hi in bands}
    d['ngs_n']=int(v.size)
    for p in [5,50,95]: d[f'ngs_p{p}']=q(v,p)
    # interventions
    d['intervention_positive']=int(np.sum(np.nan_to_num(iscore,nan=0)>0))
    rs=rstab[np.isfinite(rstab)]
    d['rank_stability_mean_of_positive']=float(np.mean(rstab[np.nan_to_num(iscore,nan=0)>0])) if d['intervention_positive'] else float('nan')
    # top-20 by intervention score
    order=np.argsort(-np.nan_to_num(iscore,nan=-1))
    t20=order[:20]
    d['top20_mean_rank_stability']=float(np.nanmean(rstab[t20]))
    d['top20_n_fully_stable']=int(np.sum(rstab[t20]>=0.999))
    d['top20_mean_species_richness']=float(np.nanmean(sr[t20]))
    d['top20_mean_habitat']=float(np.nanmean(hq[t20]))
    # effort
    d['path_local_m_median_sampled']=q(path[S],50)
    d['effort_units_median']=q(eff[S],50)
    d['taxa']=m['taxa']; d['taxa_cells']=m['taxa_cells']
    res[c]=d
json.dump(res,open('summary.json','w'),indent=1)
for c in CITIES:
    print('='*20,c)
    for k,v in res[c].items():
        if isinstance(v,float): print(f'  {k}: {v:.4g}')
        else: print(f'  {k}: {v}')
