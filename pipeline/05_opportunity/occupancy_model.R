# NatureGap sensitivity — shared single-season occupancy model.
#
# Used by prototype_occupancy_gap.R and prototype_opportunity_gap.R. Functions
# and constants only: sourcing this runs nothing.
#
# Per species, per site s and visit v:
#
#   occupied_s ~ Bernoulli(psi_s),  logit psi_s = X_s · beta  (site covariates)
#   recorded_sv | occupied ~ Bernoulli(p_v),
#                logit p_v = Z_v · alpha  (log list length + season)
#
# A visit is one observer on one date at one site; its list is the species of
# one taxon group recorded on it. List length as the detection covariate is the
# standard treatment of opportunistic records that are not complete lists
# (van Strien et al. 2013, J. Appl. Ecol. 50:1450; MacKenzie et al. 2002).

# Seen overhead, these say nothing about the site below: swifts, swallows and
# martins, gulls, cormorant, grey heron.
AERIAL_BIRDS <- "^(Apus|Tachymarptis|Hirundo|Cecropis|Delichon|Ptyonoprogne|Riparia|Larus|Chroicocephalus|Ichthyaetus)( |$)|^(Phalacrocorax carbo|Ardea cinerea)$"

# Observations joined to cells (cell_id, taxon_name, iconic_taxon_name,
# observed_on, observer_id) -> the records the model reads. `classify` is the
# pipeline's classify_taxon_group(); records it leaves unclassified (molluscs,
# algae, ...) are kept as "other".
prepare_records <- function(obs, period_start, classify) {
  obs |>
    dplyr::transmute(
      cell_id, taxon_name,
      group = dplyr::coalesce(classify(iconic_taxon_name), "other"),
      date = as.Date(observed_on),
      observer_id = dplyr::if_else(is.na(observer_id) | !nzchar(observer_id), NA_character_, observer_id),
      # A record with no observer cannot be grouped into anyone's list, so it is
      # a visit of its own.
      observer_key = dplyr::coalesce(observer_id, paste0("record-", dplyr::row_number()))
    ) |>
    # Species only: a genus-level name would overlap the species under it.
    dplyr::filter(!is.na(taxon_name), grepl(" ", taxon_name), !is.na(date), date >= period_start) |>
    dplyr::filter(!(group == "bird" & grepl(AERIAL_BIRDS, taxon_name)))
}

# Visits and detections, with `site_lookup` a named vector cell_id -> site.
build_site_visits <- function(records, site_lookup) {
  r <- records |>
    dplyr::mutate(site = unname(site_lookup[cell_id])) |>
    dplyr::filter(!is.na(site)) |>
    dplyr::distinct(group, site, observer_key, date, taxon_name)
  visits <- r |>
    dplyr::group_by(group, site, observer_key, date) |>
    dplyr::summarise(list_length = dplyr::n(), .groups = "drop") |>
    dplyr::mutate(visit_id = dplyr::row_number(),
                  doy = as.integer(format(date, "%j")))
  det <- r |>
    dplyr::inner_join(visits |> dplyr::select(group, site, observer_key, date, visit_id),
                      by = c("group", "site", "observer_key", "date")) |>
    dplyr::select(group, site, taxon_name, visit_id)
  list(visits = visits, det = det)
}

softplus <- function(z) pmax(z, 0) + log1p(exp(-abs(z)))
logsumexp2 <- function(a, b) { m <- pmax(a, b); m + log1p(exp(-abs(a - b))) }

# Negative penalised log-likelihood and its gradient. With w_s the posterior
# probability that site s is occupied (1 where the species was recorded), the
# gradients reduce to X'(w - psi) for occupancy and Z'(y - p w) for detection.
occ_fn <- function(par, X, Z, site, y, detected, prior_sd) {
  kb <- ncol(X)
  eta <- drop(X %*% par[seq_len(kb)])
  zeta <- drop(Z %*% par[-seq_len(kb)])
  log_q <- -softplus(zeta)                       # log(1 - p)
  ll_visit <- ifelse(y == 1, -softplus(-zeta), log_q)
  S <- rowsum(ll_visit, site, reorder = TRUE)[, 1]
  log_psi <- -softplus(-eta)
  log_1m_psi <- -softplus(eta)
  ll_absent <- logsumexp2(log_psi + S, log_1m_psi)
  ll <- ifelse(detected, log_psi + S, ll_absent)
  w <- ifelse(detected, 1, exp(log_psi + S - ll_absent))
  psi <- exp(log_psi)
  p <- exp(-softplus(-zeta))
  g <- c(crossprod(X, w - psi), crossprod(Z, y - p * w[site]))
  list(value = -sum(ll) + sum(par^2 / (2 * prior_sd^2)),
       gradient = -g + par / prior_sd^2)
}

# Weakly informative normal penalties on the logit scale (covariates are
# standardised). They only keep sparse species from running to a boundary.
fit_occupancy <- function(X, Z, site, y, detected,
                          prior_sd_intercept = 5, prior_sd_slope = 2.5) {
  prior_sd <- c(prior_sd_intercept, rep(prior_sd_slope, ncol(X) - 1L),
                prior_sd_intercept, rep(prior_sd_slope, ncol(Z) - 1L))
  start <- c(qlogis(min(0.95, max(0.05, mean(detected)))), rep(0, ncol(X) - 1L),
             qlogis(min(0.5, max(1e-3, mean(y)))), rep(0, ncol(Z) - 1L))
  # Value and gradient come from one pass; reuse it when optim asks for both
  # at the same parameters.
  last_par <- NULL
  last <- NULL
  at <- function(par) {
    if (!identical(par, last_par)) {
      last <<- occ_fn(par, X, Z, site, y, detected, prior_sd)
      last_par <<- par
    }
    last
  }
  o <- optim(start, function(p) at(p)$value, function(p) at(p)$gradient,
             method = "BFGS", control = list(maxit = 500))
  list(par = o$par, converged = o$convergence == 0L, kb = ncol(X))
}

# Expected occupancy, posterior occupancy, and P(recorded at least once | present)
# at held-out sites, from a fit that did not see them.
predict_sites <- function(fit, X, Z, site, y) {
  kb <- fit$kb
  eta <- drop(X %*% fit$par[seq_len(kb)])
  zeta <- drop(Z %*% fit$par[-seq_len(kb)])
  log_q <- -softplus(zeta)
  A <- rowsum(log_q, site, reorder = TRUE)[, 1]
  detected <- rowsum(y, site, reorder = TRUE)[, 1] > 0
  log_psi <- -softplus(-eta)
  post <- ifelse(detected, 1, exp(log_psi + A - logsumexp2(log_psi + A, -softplus(eta))))
  data.frame(psi = exp(log_psi), post = post, detected = detected, pstar = 1 - exp(A))
}

detection_design <- function(v) {
  cbind(1, log(v$list_length), sin(2 * pi * v$doy / 365.25), cos(2 * pi * v$doy / 365.25))
}

assign_folds <- function(sites, k, seed) {
  set.seed(seed)
  setNames(sample(rep(seq_len(k), length.out = length(sites))), sites)
}
