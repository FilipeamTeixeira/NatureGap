apply_pipeline_migrations <- function() {
  script_path <- local({
    cmd <- commandArgs(trailingOnly = FALSE)
    file_arg <- grep("^--file=", cmd, value = TRUE)
    if (length(file_arg)) {
      return(normalizePath(sub("^--file=", "", file_arg[[1L]]), mustWork = TRUE))
    }
    for (i in rev(seq_len(sys.nframe()))) {
      call <- sys.call(i)
      if (identical(call[[1L]], quote(source)) && length(call) >= 2L) {
        return(normalizePath(as.character(call[[2L]]), mustWork = TRUE))
      }
    }
    stop(
      "Cannot locate this script. Run:\n  Rscript scripts/apply-pipeline-migrations.R",
      call. = FALSE
    )
  })

  repo_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
  if (!exists("CONFIG_LOADED")) {
    source(file.path(repo_root, "pipeline", "config.R"), local = FALSE)
  }

  if (!requireNamespace("DBI", quietly = TRUE) || !requireNamespace("RPostgres", quietly = TRUE)) {
    stop("Install DBI and RPostgres before running pipeline migrations.", call. = FALSE)
  }

  if (!nzchar(database_url())) {
    stop("DATABASE_URL is not set. Add it to .env.local in the repo root.", call. = FALSE)
  }

  cell_columns <- "
  alter table public.cell_attributes
  add column if not exists disturbance_index numeric,
  add column if not exists fragmentation_index numeric,
  add column if not exists intervention_score numeric,
  add column if not exists node_importance numeric,
  add column if not exists impact_score integer,
  add column if not exists nature_gap_score numeric,
  add column if not exists habitat_quality numeric,
  add column if not exists habitat_quality_index numeric,
  add column if not exists species_richness_raw integer,
  add column if not exists observed_richness numeric,
  add column if not exists ecological_residual_normalized numeric,
  add column if not exists max_expected_richness integer,
  add column if not exists is_unsampled boolean,
  add column if not exists temporal_bias_flag boolean,
  add column if not exists path_km numeric,
  add column if not exists n_obs integer,
  add column if not exists n_survey_dates integer,
  add column if not exists habitat_potential text,
  add column if not exists observer_effort_score numeric,
  add column if not exists taxonomic_diversity numeric,
  add column if not exists species jsonb default '[]'::jsonb,
  add column if not exists pressures jsonb default '[]'::jsonb,
  add column if not exists interventions jsonb default '[]'::jsonb,
  add column if not exists tree_cover numeric,
  add column if not exists land_use_green numeric
  "

  pipeline_columns <- "
  alter table public.pipeline_cell_attributes
  add column if not exists disturbance_index numeric,
  add column if not exists fragmentation_index numeric,
  add column if not exists intervention_score numeric,
  add column if not exists node_importance numeric,
  add column if not exists impact_score integer,
  add column if not exists nature_gap_score numeric,
  add column if not exists habitat_quality numeric,
  add column if not exists habitat_quality_index numeric,
  add column if not exists species_richness_raw integer,
  add column if not exists observed_richness numeric,
  add column if not exists ecological_residual_normalized numeric,
  add column if not exists max_expected_richness integer,
  add column if not exists is_unsampled boolean,
  add column if not exists temporal_bias_flag boolean,
  add column if not exists path_km numeric,
  add column if not exists n_obs integer,
  add column if not exists n_survey_dates integer,
  add column if not exists habitat_potential text,
  add column if not exists observer_effort_score numeric,
  add column if not exists taxonomic_diversity numeric,
  add column if not exists species jsonb default '[]'::jsonb,
  add column if not exists pressures jsonb default '[]'::jsonb,
  add column if not exists interventions jsonb default '[]'::jsonb,
  add column if not exists tree_cover numeric,
  add column if not exists land_use_green numeric
  "

  green_columns <- "
  alter table public.green_spaces
  add column if not exists habitat_quality_index numeric,
  add column if not exists effort_corrected_richness numeric,
  add column if not exists expected_richness numeric,
  add column if not exists ecological_residual numeric,
  add column if not exists ecological_residual_normalized numeric,
  add column if not exists nature_gap_score numeric,
  add column if not exists corridor_importance numeric,
  add column if not exists intervention_rank numeric
  "

  pipeline_green_columns <- "
  alter table public.pipeline_green_spaces
  add column if not exists habitat_quality_index numeric,
  add column if not exists effort_corrected_richness numeric,
  add column if not exists expected_richness numeric,
  add column if not exists ecological_residual numeric,
  add column if not exists ecological_residual_normalized numeric,
  add column if not exists nature_gap_score numeric,
  add column if not exists corridor_importance numeric,
  add column if not exists intervention_rank numeric
  "

  con <- NULL
  tryCatch({
    con <- connect_database()
    DBI::dbExecute(con, cell_columns)
    DBI::dbExecute(con, pipeline_columns)
    DBI::dbExecute(con, green_columns)
    DBI::dbExecute(con, pipeline_green_columns)
    cat("Added missing pipeline schema columns.\n")
  }, finally = {
    if (!is.null(con) && DBI::dbIsValid(con)) {
      DBI::dbDisconnect(con)
    }
  })

  invisible(TRUE)
}

apply_pipeline_migrations()
