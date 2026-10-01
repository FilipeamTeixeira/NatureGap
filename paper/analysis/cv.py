import numpy as np, json, warnings
import statsmodels.api as sm
warnings.filterwarnings('ignore')
CITIES=['porto','amsterdam','yokohama','gent']
PUB={'porto':dict(coef=[-8.3269,3.5434,0.0231,6.2684],dev=0.1405,disp=16.697,n=30947),
     'amsterdam':dict(coef=[-4.6264,0.6616,0.5800,3.1435],dev=0.0298,disp=246.2843,n=67147),
     'yokohama':dict(coef=[-4.0306,0.7587,1.3133,0.1380],dev=0.0211,disp=301.5546,n=52014),
     'gent':dict(coef=[-2.9138,-0.1525,0.2817,2.5200],dev=0.0088,disp=102.7324,n=64875)}

def pois_dev(y,mu):
    mu=np.clip(mu,1e-12,None)
    t=np.where(y>0, y*np.log(y/mu), 0.0)
    return 2*np.sum(t-(y-mu))

out={}
for c in CITIES:
    z=np.load(f'{c}.npz'); xy=np.load(f'{c}_xy.npz')
    eff=z['survey_effort_units']; S=np.isfinite(eff)&(eff>0)
    y=z['species_richness_raw']; hab=z['habitat_quality_index']; ci=z['corridor_importance']
    path=z['path_local_m']
    S=S&np.isfinite(y)&np.isfinite(hab)&np.isfinite(path)
    acc=np.log1p(path)/np.log1p(np.nanmax(path[S]))
    acc=np.clip(np.nan_to_num(acc,nan=0.0),0,1)
    conn=np.clip(np.nan_to_num(ci,nan=0.0),0,1)
    X=np.column_stack([np.ones(S.sum()),hab[S],conn[S],acc[S]])
    Y=y[S]; off=np.log(eff[S])
    m=sm.GLM(Y,X,family=sm.families.Poisson(),offset=off).fit()
    mu=m.fittedvalues
    d_res=pois_dev(Y,mu); d_null=pois_dev(Y,np.exp(off)*np.sum(Y)/np.sum(np.exp(off)))
    devexp=1-d_res/d_null
    pearson=np.sum((Y-mu)**2/np.clip(mu,1e-12,None))/(len(Y)-X.shape[1])
    rec={'n':int(S.sum()),'coef_refit':[round(float(v),4) for v in m.params],
         'coef_published':PUB[c]['coef'],'dev_explained_insample':round(float(devexp),4),
         'dev_published':PUB[c]['dev'],'dispersion_refit':round(float(pearson),3),
         'dispersion_published':PUB[c]['disp'],'n_published':PUB[c]['n']}
    # spatially blocked 5-fold CV: tile centroids into a coarse lattice, assign blocks to folds
    X_=xy['x'][S]; Y_=xy['y'][S]
    nb=25
    bx=np.floor((X_-X_.min())/((X_.max()-X_.min())/nb+1e-12)).astype(int)
    by=np.floor((Y_-Y_.min())/((Y_.max()-Y_.min())/nb+1e-12)).astype(int)
    blk=bx*1000+by
    ub=np.unique(blk); rng=np.random.default_rng(42); rng.shuffle(ub)
    fold_of_blk={b:i%5 for i,b in enumerate(ub)}
    fold=np.array([fold_of_blk[b] for b in blk])
    devs=[]; varratios=[]; corrs=[]
    for f in range(5):
        tr=fold!=f; te=fold==f
        if te.sum()<50 or tr.sum()<200: continue
        mf=sm.GLM(Y[tr],X[tr],family=sm.families.Poisson(),offset=off[tr]).fit()
        mu_te=np.exp(X[te]@mf.params+off[te])
        dnull_te=pois_dev(Y[te], np.exp(off[te])*np.sum(Y[tr])/np.sum(np.exp(off[tr])))
        devs.append(1-pois_dev(Y[te],mu_te)/dnull_te)
        rate_te=np.exp(X[te]@mf.params)            # expected richness (per effort unit)
        obs_te=Y[te]/eff[S][te]                    # observed effort-corrected richness
        resid=rate_te-obs_te
        varratios.append(np.var(rate_te)/np.var(obs_te))
        corrs.append(np.corrcoef(resid,-obs_te)[0,1])
    rec['cv_dev_explained_folds']=[round(float(v),4) for v in devs]
    rec['cv_dev_explained_mean']=round(float(np.mean(devs)),4)
    rec['cv_var_ratio_expected_over_observed']=round(float(np.mean(varratios)),5)
    rec['cv_corr_residual_vs_neg_observed']=round(float(np.mean(corrs)),4)
    # in-sample variance ratio
    rate=np.exp(X@m.params); obs=Y/eff[S]
    rec['insample_var_ratio']=round(float(np.var(rate)/np.var(obs)),5)
    rec['insample_corr_resid_negobs']=round(float(np.corrcoef(rate-obs,-obs)[0,1]),4)
    out[c]=rec
    print('='*14,c)
    for k,v in rec.items(): print('  ',k,':',v)
json.dump(out,open('cv.json','w'),indent=1)
