# NatureGap — Prune stale pipeline-export Storage objects after promotion
#
# Lists objects under pipeline-export/<city_id>/ in Supabase Storage and deletes
# every object whose path does not belong to the active dataset's storage_prefix
# (plus the city's current.json pointer).

PIPELINE_EXPORT_BUCKET <- "pipeline-export"

supabase_project_url <- function() {
  trimws(Sys.getenv("NEXT_PUBLIC_SUPABASE_URL", unset = ""))
}

supabase_service_role_key <- function() {
  value <- Sys.getenv("SUPABASE_SERVICE_ROLE_KEY", unset = "")
  if (!nzchar(value)) value <- Sys.getenv("SUPABASE_SERVICE_KEY", unset = "")
  trimws(value)
}

storage_prefix_to_object_prefix <- function(storage_prefix, bucket = PIPELINE_EXPORT_BUCKET) {
  prefix <- trimws(storage_prefix)
  if (!nzchar(prefix)) {
    stop("storage_prefix is blank.", call. = FALSE)
  }

  bucket_prefix <- paste0(bucket, "/")
  if (startsWith(prefix, bucket_prefix)) {
    prefix <- substring(prefix, nchar(bucket_prefix) + 1L)
  }
  if (!endsWith(prefix, "/")) prefix <- paste0(prefix, "/")
  prefix
}

fetch_active_storage_prefix <- function(con, city_id) {
  row <- DBI::dbGetQuery(
    con,
    "
    select dataset_id, storage_prefix
    from public.pipeline_datasets
    where city_id = $1::text
      and is_active = true
    order by generated_at desc
    limit 1
    ",
    params = list(city_id)
  )
  if (nrow(row) == 0L) {
    stop(sprintf("No active pipeline_datasets row found for city_id=%s.", city_id), call. = FALSE)
  }
  list(
    dataset_id = as.character(row$dataset_id[[1L]]),
    storage_prefix = as.character(row$storage_prefix[[1L]])
  )
}

storage_api_perform <- function(method, path, body = NULL, key = supabase_service_role_key()) {
  if (!requireNamespace("httr2", quietly = TRUE)) {
    stop("Package 'httr2' is required for Supabase Storage pruning.", call. = FALSE)
  }

  base_url <- sub("/$", "", supabase_project_url())
  if (!nzchar(base_url)) {
    stop("NEXT_PUBLIC_SUPABASE_URL is not set.", call. = FALSE)
  }
  if (!nzchar(key)) {
    stop("SUPABASE_SERVICE_ROLE_KEY is not set.", call. = FALSE)
  }

  req <- httr2::request(paste0(base_url, path)) |>
    httr2::req_method(method) |>
    httr2::req_headers(
      Authorization = paste("Bearer", key),
      apikey = key
    )

  if (!is.null(body)) {
    req <- req |> httr2::req_body_json(body)
  }

  resp <- httr2::req_perform(req)
  status <- httr2::resp_status(resp)
  if (status >= 400L) {
    stop(sprintf(
      "Supabase Storage %s %s failed: HTTP %s %s",
      method,
      path,
      status,
      httr2::resp_status_desc(resp)
    ), call. = FALSE)
  }
  resp
}

list_storage_page <- function(prefix, limit = 1000L, offset = 0L) {
  resp <- storage_api_perform(
    "POST",
    sprintf("/storage/v1/object/list/%s", PIPELINE_EXPORT_BUCKET),
    body = list(
      prefix = prefix,
      limit = as.integer(limit),
      offset = as.integer(offset),
      sortBy = list(column = "name", order = "asc")
    )
  )
  httr2::resp_body_json(resp)
}

list_all_storage_objects <- function(prefix) {
  if (!endsWith(prefix, "/")) prefix <- paste0(prefix, "/")

  paths <- character(0)
  offset <- 0L
  limit <- 1000L

  repeat {
    items <- list_storage_page(prefix, limit = limit, offset = offset)
    if (length(items) == 0L) break

    for (item in items) {
      item_name <- as.character(item$name %||% "")
      if (!nzchar(item_name)) next
      item_path <- paste0(prefix, item_name)
      if (is.null(item$id)) {
        paths <- c(paths, list_all_storage_objects(paste0(item_path, "/")))
      } else {
        paths <- c(paths, item_path)
      }
    }

    if (length(items) < limit) break
    offset <- offset + limit
  }

  unique(paths)
}

delete_storage_objects <- function(paths) {
  if (length(paths) == 0L) return(0L)

  deleted <- 0L
  chunk_size <- 100L
  for (start in seq(1L, length(paths), by = chunk_size)) {
    chunk <- paths[start:min(start + chunk_size - 1L, length(paths))]
    storage_api_perform(
      "DELETE",
      sprintf("/storage/v1/object/%s", PIPELINE_EXPORT_BUCKET),
      body = list(prefixes = chunk)
    )
    deleted <- deleted + length(chunk)
  }
  deleted
}

summarize_removed_dataset_versions <- function(removed_paths, city_id) {
  pattern <- sprintf("^%s/([^/]+)/", city_id)
  matches <- regmatches(removed_paths, regexec(pattern, removed_paths))
  versions <- unique(vapply(matches, function(parts) {
    if (length(parts) >= 2L) parts[[2L]] else NA_character_
  }, character(1)))
  versions <- sort(versions[nzchar(versions)])
  if (length(versions) == 0L) "none" else paste(versions, collapse = ", ")
}

should_keep_storage_object <- function(object_path, active_object_prefix, city_id) {
  current_pointer <- paste0(city_id, "/current.json")
  identical(object_path, current_pointer) || startsWith(object_path, active_object_prefix)
}

prune_stale_pipeline_storage <- function(city_id, con) {
  `%||%` <- function(a, b) {
    if (is.null(a) || length(a) == 0L) return(b)
    if (is.character(a) && length(a) == 1L && !nzchar(a)) return(b)
    a
  }

  active <- fetch_active_storage_prefix(con, city_id)
  active_object_prefix <- storage_prefix_to_object_prefix(active$storage_prefix)

  cat(sprintf(
    "\nPruning stale Supabase Storage objects for %s (keeping active prefix %s)…\n",
    city_id,
    active_object_prefix
  ))

  city_prefix <- paste0(city_id, "/")
  all_paths <- list_all_storage_objects(city_prefix)
  if (length(all_paths) == 0L) {
    cat(sprintf(
      "Storage prune complete for %s: 0 objects deleted (no objects found under %s).\n",
      city_id,
      city_prefix
    ))
    return(invisible(list(deleted = 0L, kept_prefix = active_object_prefix)))
  }

  stale_paths <- all_paths[!vapply(
    all_paths,
    should_keep_storage_object,
    logical(1),
    active_object_prefix = active_object_prefix,
    city_id = city_id
  )]

  if (length(stale_paths) == 0L) {
    cat(sprintf(
      "Storage prune complete for %s: 0 objects deleted (all %d object(s) belong to the active dataset or current.json).\n",
      city_id,
      length(all_paths)
    ))
    return(invisible(list(deleted = 0L, kept_prefix = active_object_prefix)))
  }

  deleted <- delete_storage_objects(stale_paths)
  removed_versions <- summarize_removed_dataset_versions(stale_paths, city_id)
  cat(sprintf(
    "Storage prune complete for %s: deleted %d object(s); removed dataset version folder(s): %s; kept active prefix %s.\n",
    city_id,
    deleted,
    removed_versions,
    active_object_prefix
  ))

  invisible(list(
    deleted = deleted,
    kept_prefix = active_object_prefix,
    removed_versions = removed_versions
  ))
}

run_storage_prune_after_promotion <- function(city_id, con) {
  required <- identical(Sys.getenv("PIPELINE_STORAGE_PRUNE_REQUIRED", unset = "0"), "1")
  skip <- function(msg) {
    if (required) stop(msg, call. = FALSE)
    message(msg)
    invisible(NULL)
  }

  if (!nzchar(supabase_project_url())) {
    skip("Skipping Storage prune: NEXT_PUBLIC_SUPABASE_URL is not set.")
    return(invisible(NULL))
  }
  if (!nzchar(supabase_service_role_key())) {
    skip("Skipping Storage prune: SUPABASE_SERVICE_ROLE_KEY is not set.")
    return(invisible(NULL))
  }

  tryCatch(
    prune_stale_pipeline_storage(city_id, con),
    error = function(err) {
      skip(sprintf(
        "Storage prune failed for %s after successful promotion; stale objects were left in place. Error: %s",
        city_id,
        conditionMessage(err)
      ))
    }
  )
}
