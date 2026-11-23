# Internal utility helpers for slurmpilot

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

sp_timestamp <- function(time = Sys.time()) {
  format(time, "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
}

sp_id_counter_env <- new.env(parent = emptyenv())
sp_id_counter_env$n <- 0L

sp_next_counter <- function() {
  sp_id_counter_env$n <- sp_id_counter_env$n + 1L
  sp_id_counter_env$n
}

sp_generate_id <- function(prefix = "sp") {
  ts <- format(Sys.time(), "%Y%m%d_%H%M%S", tz = "UTC")
  # RNG-free entropy so calling slurmpilot never mutates .Random.seed
  cnt <- sp_next_counter()
  rand <- substr(
    digest::digest(list(Sys.time(), proc.time(), Sys.getpid(), cnt), algo = "sha256"),
    1L, 8L
  )
  paste0(prefix, "_", ts, "_", rand)
}

sp_sanitize_name <- function(name, default = "slurmpilot_job") {
  if (is.null(name) || length(name) == 0L || is.na(name[[1L]]) || !nzchar(trimws(as.character(name[[1L]])))) {
    return(default)
  }
  s <- as.character(name[[1L]])
  # Strip control characters and replace anything outside [A-Za-z0-9_.-]
  s <- gsub("[\r\n\t[:cntrl:]]", "_", s, perl = TRUE)
  clean <- gsub("[^A-Za-z0-9_.-]+", "_", trimws(s))
  # Prevent leading dash/dot (CLI flag injection / hidden dotfile / '..')
  clean <- gsub("^[._-]+|[._-]+$", "", clean)
  clean <- gsub("\\.\\.+", "_", clean)
  if (!nzchar(clean)) {
    return(default)
  }
  substr(clean, 1L, 120L)
}

#' Format Duration in Seconds as a SLURM Time String
#'
#' Converts a positive duration in seconds into SLURM's canonical `HH:MM:SS` or
#' `D-HH:MM:SS` walltime format.
#'
#' @param seconds Numeric scalar duration in seconds (rounded up to whole
#'   seconds).
#'
#' @return A length-1 character string formatted for SLURM `--time`.
#' @export
#' @examples
#' format_slurm_time(3665)
#' format_slurm_time(90000)
format_slurm_time <- function(seconds) {
  checkmate::assert_number(seconds, lower = 0, finite = TRUE)
  total_sec <- as.integer(ceiling(seconds))
  days <- total_sec %/% 86400L
  rem <- total_sec %% 86400L
  hours <- rem %/% 3600L
  rem <- rem %% 3600L
  mins <- rem %/% 60L
  secs <- rem %% 60L

  if (days > 0L) {
    sprintf("%d-%02d:%02d:%02d", days, hours, mins, secs)
  } else {
    sprintf("%02d:%02d:%02d", hours, mins, secs)
  }
}

#' Parse a SLURM Time String to Seconds
#'
#' Parses SLURM elapsed/limit time strings such as `"MM:SS"`, `"HH:MM:SS"`, or
#' `"D-HH:MM:SS"` into numeric seconds.
#'
#' @param x Character vector of SLURM time strings.
#'
#' @return Numeric vector of durations in seconds (`NA_real_` for unparseable
#'   or missing inputs).
#' @export
#' @examples
#' parse_slurm_time(c("05:30", "01:15:00", "2-03:00:00"))
parse_slurm_time <- function(x) {
  if (length(x) == 0L) {
    return(numeric(0L))
  }
  vapply(as.character(x), function(s) {
    s <- trimws(s)
    if (is.na(s) || !nzchar(s) || s %in% c("INVALID", "UNLIMITED", "NOT_SET", "NA")) {
      return(NA_real_)
    }
    days <- 0
    if (grepl("-", s, fixed = TRUE)) {
      parts <- strsplit(s, "-", fixed = TRUE)[[1L]]
      if (length(parts) != 2L) return(NA_real_)
      days <- suppressWarnings(as.numeric(parts[[1L]]))
      s <- parts[[2L]]
    }
    hms <- suppressWarnings(as.numeric(strsplit(s, ":", fixed = TRUE)[[1L]]))
    if (any(is.na(hms)) || is.na(days)) {
      return(NA_real_)
    }
    if (length(hms) == 3L) {
      days * 86400 + hms[[1L]] * 3600 + hms[[2L]] * 60 + hms[[3L]]
    } else if (length(hms) == 2L) {
      if (days > 0) {
        days * 86400 + hms[[1L]] * 3600 + hms[[2L]] * 60
      } else {
        hms[[1L]] * 60 + hms[[2L]]
      }
    } else if (length(hms) == 1L) {
      days * 86400 + hms[[1L]] * 60
    } else {
      NA_real_
    }
  }, numeric(1L), USE.NAMES = FALSE)
}

#' Format Memory in Megabytes as a SLURM `--mem` String
#'
#' Formats an integer megabyte value cleanly as either `"<N>G"` (when an exact
#' multiple of 1024 MB) or `"<N>M"`.
#'
#' @param mem_mb Numeric scalar memory size in megabytes.
#'
#' @return Character scalar formatted for SLURM `--mem`.
#' @export
#' @examples
#' format_slurm_mem(512)
#' format_slurm_mem(4096)
format_slurm_mem <- function(mem_mb) {
  checkmate::assert_number(mem_mb, lower = 1, finite = TRUE)
  mb <- as.integer(ceiling(mem_mb))
  if (mb >= 1024L && (mb %% 1024L == 0L)) {
    paste0(mb %/% 1024L, "G")
  } else {
    paste0(mb, "M")
  }
}

#' Parse a SLURM Memory String to Megabytes
#'
#' Parses SLURM `MaxRSS` or `--mem` values (e.g., `"512K"`, `"2048M"`, `"4G"`,
#' `"1.5T"`, or raw byte strings) into numeric megabytes (MiB).
#'
#' @param x Character vector of SLURM memory strings.
#'
#' @return Numeric vector in megabytes (`NA_real_` for empty/invalid values).
#' @export
#' @examples
#' parse_slurm_mem(c("524288K", "1024M", "2G"))
parse_slurm_mem <- function(x) {
  if (length(x) == 0L) {
    return(numeric(0L))
  }
  vapply(as.character(x), function(s) {
    s <- trimws(s)
    if (is.na(s) || !nzchar(s) || s %in% c("0", "NA")) {
      return(if (identical(s, "0")) 0 else NA_real_)
    }
    m <- regexec("^([0-9]+(?:\\.[0-9]+)?)([KkMmGgTtBb]?)$", s)
    parts <- regmatches(s, m)[[1L]]
    if (length(parts) != 3L) {
      return(NA_real_)
    }
    val <- suppressWarnings(as.numeric(parts[[2L]]))
    unit <- toupper(parts[[3L]])
    if (is.na(val)) return(NA_real_)
    if (!nzchar(unit)) return(val / (1024^2))
    switch(
      unit,
      "B" = val / (1024^2),
      "K" = val / 1024,
      "M" = val,
      "G" = val * 1024,
      "T" = val * 1024 * 1024,
      NA_real_
    )
  }, numeric(1L), USE.NAMES = FALSE)
}

#' Format Integer Array Indices into Compact SLURM `--array` Notation
#'
#' Compresses a set of positive integer task indices into contiguous ranges
#' suitable for SLURM `--array`, with optional concurrency throttling (`%limit`).
#'
#' @param indices Integer vector of 1-based SLURM array task indices.
#' @param max_concurrent Optional positive integer limiting concurrent array
#'   tasks (`%max_concurrent`).
#'
#' @return Character scalar SLURM array specification, e.g. `"1-4,7,9-10%2"`.
#' @export
#' @examples
#' format_slurm_array_indices(c(1, 2, 3, 5, 8, 9))
#' format_slurm_array_indices(1:20, max_concurrent = 4)
format_slurm_array_indices <- function(indices, max_concurrent = NULL) {
  checkmate::assert_integerish(indices, lower = 1L, min.len = 1L, any.missing = FALSE)
  if (!is.null(max_concurrent)) {
    checkmate::assert_int(max_concurrent, lower = 1L)
  }
  idx <- sort(unique(as.integer(indices)))
  breaks <- c(0L, which(diff(idx) > 1L), length(idx))
  ranges <- character(length(breaks) - 1L)
  for (i in seq_along(ranges)) {
    start_val <- idx[[breaks[[i]] + 1L]]
    end_val <- idx[[breaks[[i + 1L]]]]
    ranges[[i]] <- if (start_val == end_val) {
      as.character(start_val)
    } else {
      paste0(start_val, "-", end_val)
    }
  }
  spec <- paste(ranges, collapse = ",")
  if (!is.null(max_concurrent)) {
    spec <- paste0(spec, "%", as.integer(max_concurrent))
  }
  spec
}

sp_expand_slurm_array_expr <- function(expr) {
  expr <- trimws(as.character(expr))
  # Strip surrounding brackets if present (from squeue e.g. [1-4,6%2])
  expr <- gsub("^\\[|\\]$", "", expr)
  # Strip optional concurrency throttle %N
  expr <- sub("%[0-9]+$", "", expr)
  if (!nzchar(expr)) {
    return(integer(0L))
  }
  parts <- strsplit(expr, ",", fixed = TRUE)[[1L]]
  out <- integer(0L)
  for (p in parts) {
    p <- trimws(p)
    step <- 1L
    if (grepl(":", p, fixed = TRUE)) {
      sp <- strsplit(p, ":", fixed = TRUE)[[1L]]
      p <- sp[[1L]]
      step <- as.integer(sp[[2L]])
    }
    if (grepl("-", p, fixed = TRUE)) {
      bounds <- as.integer(strsplit(p, "-", fixed = TRUE)[[1L]])
      if (length(bounds) == 2L && !any(is.na(bounds))) {
        out <- c(out, seq.int(bounds[[1L]], bounds[[2L]], by = step))
      }
    } else {
      val <- suppressWarnings(as.integer(p))
      if (!is.na(val)) {
        out <- c(out, val)
      }
    }
  }
  unique(out)
}

sp_partition_tasks <- function(n_tasks, chunk_size) {
  checkmate::assert_int(n_tasks, lower = 1L)
  checkmate::assert_int(chunk_size, lower = 1L)
  n_chunks <- as.integer(ceiling(n_tasks / chunk_size))
  chunk_ids <- seq_len(n_chunks)
  starts <- (chunk_ids - 1L) * chunk_size + 1L
  ends <- pmin(chunk_ids * chunk_size, n_tasks)
  task_lists <- Map(seq.int, starts, ends)
  tibble::tibble(
    chunk_id = chunk_ids,
    start_task = as.integer(starts),
    end_task = as.integer(ends),
    n_tasks = as.integer(ends - starts + 1L),
    task_indices = task_lists
  )
}

sp_atomic_tmp_path <- function(path) {
  dir_path <- dirname(path)
  if (!dir.exists(dir_path)) {
    dir.create(dir_path, recursive = TRUE, showWarnings = FALSE)
  }
  file.path(
    dir_path,
    sprintf(".%s.tmp.%d.%d", basename(path), Sys.getpid(), sp_next_counter())
  )
}

sp_write_rds_atomic <- function(object, path) {
  tmp <- sp_atomic_tmp_path(path)
  on.exit(if (file.exists(tmp)) unlink(tmp, force = TRUE), add = TRUE)
  saveRDS(object, file = tmp)
  ok <- file.rename(tmp, path)
  if (!ok) {
    file.copy(tmp, path, overwrite = TRUE)
    unlink(tmp, force = TRUE)
  }
  invisible(path)
}

sp_write_json_atomic <- function(object, path) {
  tmp <- sp_atomic_tmp_path(path)
  on.exit(if (file.exists(tmp)) unlink(tmp, force = TRUE), add = TRUE)
  jsonlite::write_json(object, path = tmp, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null")
  ok <- file.rename(tmp, path)
  if (!ok) {
    file.copy(tmp, path, overwrite = TRUE)
    unlink(tmp, force = TRUE)
  }
  invisible(path)
}

sp_write_lines_atomic <- function(lines, path) {
  tmp <- sp_atomic_tmp_path(path)
  on.exit(if (file.exists(tmp)) unlink(tmp, force = TRUE), add = TRUE)
  writeLines(lines, con = tmp, useBytes = TRUE)
  ok <- file.rename(tmp, path)
  if (!ok) {
    file.copy(tmp, path, overwrite = TRUE)
    unlink(tmp, force = TRUE)
  }
  invisible(path)
}

sp_sh_quote <- function(x) {
  vapply(as.character(x), function(s) {
    paste0("'", gsub("'", "'\"'\"'", s, fixed = TRUE), "'")
  }, character(1L), USE.NAMES = FALSE)
}

sp_ceil_to <- function(x, step) {
  if (step <= 0) return(x)
  ceiling(x / step) * step
}

sp_process_tree_rss_mb <- function(pid) {
  tryCatch({
    h <- ps::ps_handle(as.integer(pid))
    handles <- c(list(h), ps::ps_children(h, recursive = TRUE))
    rss_bytes <- sum(vapply(handles, function(proc) {
      tryCatch(
        as.numeric(ps::ps_memory_info(proc)[["rss"]]),
        error = function(e) 0
      )
    }, numeric(1L)), na.rm = TRUE)
    rss_bytes / (1024^2)
  }, error = function(e) NA_real_)
}

sp_kill_and_reap <- function(proc, wait_ms = 1000L) {
  if (is.null(proc)) return(invisible(FALSE))
  try(proc$kill_tree(), silent = TRUE)
  if (isTRUE(tryCatch(proc$is_alive(), error = function(e) FALSE))) {
    try(proc$kill(), silent = TRUE)
  }
  try(proc$wait(timeout = as.integer(wait_ms)), silent = TRUE)
  invisible(!isTRUE(tryCatch(proc$is_alive(), error = function(e) FALSE)))
}

#' Derive an Independent `L'Ecuyer-CMRG` Parallel RNG Stream
#'
#' Computes the deterministic 7-integer `L'Ecuyer-CMRG` `.Random.seed` vector
#' for a given `(seed, chunk_id, task_pos)` tuple using base
#' [parallel::nextRNGStream()] (spacing chunks \eqn{2^{127}} draws apart) and
#' [parallel::nextRNGSubStream()] (spacing tasks within a chunk \eqn{2^{76}}
#' draws apart). Restores the caller's `.Random.seed` and `RNGkind()` on exit
#' so calling this function has zero global RNG side effects.
#'
#' @param seed Integer master seed.
#' @param chunk_id Positive integer array chunk index. Default `1L`.
#' @param task_pos Positive integer 1-based task position within the chunk.
#'   Default `1L`.
#'
#' @return An integer vector of length 7 representing a valid `L'Ecuyer-CMRG`
#'   `.Random.seed` state.
#' @export
#' @examples
#' s1 <- slurmpilot_rng_stream(42L, chunk_id = 1L, task_pos = 1L)
#' s2 <- slurmpilot_rng_stream(42L, chunk_id = 2L, task_pos = 1L)
#' !identical(s1, s2)
slurmpilot_rng_stream <- function(seed, chunk_id = 1L, task_pos = 1L) {
  checkmate::assert_int(seed)
  checkmate::assert_int(chunk_id, lower = 1L)
  checkmate::assert_int(task_pos, lower = 1L)

  old_kind <- RNGkind()
  has_seed <- exists(".Random.seed", envir = globalenv(), inherits = FALSE)
  old_seed <- if (has_seed) get(".Random.seed", envir = globalenv(), inherits = FALSE) else NULL
  on.exit({
    suppressWarnings(RNGkind(kind = old_kind[[1L]], normal.kind = old_kind[[2L]], sample.kind = old_kind[[3L]]))
    if (has_seed) {
      assign(".Random.seed", old_seed, envir = globalenv())
    } else if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
      rm(".Random.seed", envir = globalenv())
    }
  }, add = TRUE)

  RNGkind("L'Ecuyer-CMRG")
  set.seed(as.integer(seed))
  s <- get(".Random.seed", envir = globalenv(), inherits = FALSE)
  for (step in seq_len(as.integer(chunk_id))) {
    s <- parallel::nextRNGStream(s)
  }
  if (task_pos > 1L) {
    for (step in seq_len(as.integer(task_pos - 1L))) {
      s <- parallel::nextRNGSubStream(s)
    }
  }
  s
}

sp_normalize_slurm_state <- function(state) {
  s <- toupper(trimws(as.character(state)))
  s <- sub("\\+$", "", s)
  # Handle "CANCELLED by 1234"
  s <- sub("^CANCELLED\\b.*$", "CANCELLED", s)
  dplyr_like <- switch(
    s,
    "PD" = "PENDING",
    "PENDING" = "PENDING",
    "CF" = "PENDING",
    "CONFIGURING" = "PENDING",
    "R" = "RUNNING",
    "RUNNING" = "RUNNING",
    "CG" = "RUNNING",
    "COMPLETING" = "RUNNING",
    "CD" = "COMPLETED",
    "COMPLETED" = "COMPLETED",
    "F" = "FAILED",
    "FAILED" = "FAILED",
    "NF" = "FAILED",
    "NODE_FAIL" = "FAILED",
    "BF" = "FAILED",
    "BOOT_FAIL" = "FAILED",
    "OOM" = "OUT_OF_MEMORY",
    "OUT_OF_MEMORY" = "OUT_OF_MEMORY",
    "TO" = "TIMEOUT",
    "TIMEOUT" = "TIMEOUT",
    "CA" = "CANCELLED",
    "CANCELLED" = "CANCELLED",
    "PR" = "FAILED",
    "PREEMPTED" = "FAILED",
    if (nzchar(s)) s else "UNKNOWN"
  )
  dplyr_like
}

sp_terminal_states <- function() {
  c("COMPLETED", "FAILED", "OUT_OF_MEMORY", "TIMEOUT", "CANCELLED")
}

sp_retryable_states <- function() {
  c("FAILED", "OUT_OF_MEMORY", "TIMEOUT", "CANCELLED")
}

sp_aggregate_job_state <- function(chunk_states) {
  if (length(chunk_states) == 0L) {
    return("PENDING")
  }
  if (any(chunk_states == "RUNNING")) {
    return("RUNNING")
  }
  if (any(chunk_states == "PENDING")) {
    return("PENDING")
  }
  if (all(chunk_states == "COMPLETED")) {
    return("COMPLETED")
  }
  if (all(chunk_states == "CANCELLED")) {
    return("CANCELLED")
  }
  if (any(chunk_states == "COMPLETED") && any(chunk_states %in% sp_retryable_states())) {
    return("PARTIAL_FAILURE")
  }
  "FAILED"
}
