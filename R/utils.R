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
#' Parses SLURM elapsed/limit time strings such as `"MM"`, `"MM:SS"`,
#' `"HH:MM:SS"`, `"D-HH"`, `"D-HH:MM"`, or `"D-HH:MM:SS"` (with optional
#' fractional seconds) into numeric seconds.
#'
#' @param x Character vector of SLURM time strings.
#'
#' @return Numeric vector of durations in seconds (`NA_real_` for unparseable,
#'   `"UNLIMITED"`, `"INVALID"`, or missing inputs).
#' @export
#' @examples
#' parse_slurm_time(c("05:30", "01:15:00", "2-03:00:10", "00:02:15.500"))
parse_slurm_time <- function(x) {
  if (is.null(x) || length(x) == 0L) {
    return(numeric(0L))
  }
  vapply(as.character(x), function(s) {
    s <- trimws(s)
    if (is.na(s) || !nzchar(s) ||
        toupper(s) %in% c("INVALID", "UNLIMITED", "NOT_SET", "NA", "PARTITION_LIMIT")) {
      return(NA_real_)
    }
    days <- 0
    has_days <- grepl("-", s, fixed = TRUE)
    if (has_days) {
      parts <- strsplit(s, "-", fixed = TRUE)[[1L]]
      if (length(parts) != 2L) return(NA_real_)
      days <- suppressWarnings(as.numeric(parts[[1L]]))
      s <- parts[[2L]]
    }
    hms <- suppressWarnings(as.numeric(strsplit(s, ":", fixed = TRUE)[[1L]]))
    if (length(hms) == 0L || any(is.na(hms)) || is.na(days) || any(hms < 0) || days < 0) {
      return(NA_real_)
    }
    if (length(hms) == 3L) {
      days * 86400 + hms[[1L]] * 3600 + hms[[2L]] * 60 + hms[[3L]]
    } else if (length(hms) == 2L) {
      if (has_days) {
        days * 86400 + hms[[1L]] * 3600 + hms[[2L]] * 60
      } else {
        hms[[1L]] * 60 + hms[[2L]]
      }
    } else if (length(hms) == 1L) {
      if (has_days) {
        days * 86400 + hms[[1L]] * 3600
      } else {
        hms[[1L]] * 60
      }
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
#' Parses SLURM `MaxRSS`, `ReqMem`, or `--mem` values — including standard
#' units (`"512K"`, `"2048M"`, `"4G"`, `"0.5T"`), IEC units (`"2GiB"`), and
#' SLURM per-CPU / per-node `ReqMem` suffixes (`"100Mc"`, `"200Mn"`, `"4Gc"`)
#' — into numeric megabytes (MiB).
#'
#' @param x Character vector of SLURM memory strings.
#'
#' @return Numeric vector in megabytes (`NA_real_` for empty/invalid values).
#' @export
#' @examples
#' parse_slurm_mem(c("1024K", "2.5G", "0.5T", "100Mc", "200Mn"))
parse_slurm_mem <- function(x) {
  if (is.null(x) || length(x) == 0L) {
    return(numeric(0L))
  }
  vapply(as.character(x), function(s) {
    s <- trimws(s)
    if (is.na(s) || !nzchar(s) || toupper(s) %in% c("NA", "N/A")) {
      return(NA_real_)
    }
    # Handle optional SLURM per-CPU ('c') or per-node ('n') ReqMem suffix and IEC 'iB'/'B'
    m <- regexec("^([0-9]+(?:\\.[0-9]+)?)\\s*([KkMmGgTtBb]?)(?:[Ii]?[Bb])?([CcNn]?)$", s)
    parts <- regmatches(s, m)[[1L]]
    if (length(parts) != 4L) {
      return(NA_real_)
    }
    val <- suppressWarnings(as.numeric(parts[[2L]]))
    unit <- toupper(parts[[3L]])
    if (is.na(val)) return(NA_real_)
    if (val == 0) return(0)
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

#' Parse a SLURM Array Expression into Expanded Integer Indices
#'
#' Expands SLURM array expressions such as `"1-100:2"`, `"1,3,5-9%4"`, or
#' bracketed `squeue` expressions `"[1-4,6%2]"` into a vector of integer task
#' indices.
#'
#' @param expr Character scalar SLURM array expression.
#' @param max_indices Positive integer upper bound on the total number of
#'   expanded array indices (guards against unbounded range expansion). Default
#'   `100000L`.
#'
#' @return Integer vector of expanded array indices (`integer(0L)` for empty
#'   strings).
#' @export
#' @examples
#' parse_slurm_array_spec("1-10:2")
#' parse_slurm_array_spec("1,3,5-9%4")
parse_slurm_array_spec <- function(expr, max_indices = 100000L) {
  sp_expand_slurm_array_expr(expr, max_indices = max_indices)
}

sp_expand_slurm_array_expr <- function(expr, max_indices = 100000L) {
  checkmate::assert_int(max_indices, lower = 1L)
  if (is.null(expr) || length(expr) == 0L || is.na(expr[[1L]])) {
    return(integer(0L))
  }
  expr_orig <- trimws(as.character(expr[[1L]]))
  expr <- expr_orig
  # Strip surrounding brackets if present (from squeue e.g. [1-4,6%2])
  expr <- gsub("^\\[|\\]$", "", expr)
  # Strip optional concurrency throttle %N
  expr <- sub("%[0-9]+$", "", expr)
  if (!nzchar(expr)) {
    return(integer(0L))
  }
  parts <- strsplit(expr, ",", fixed = TRUE)[[1L]]
  chunks_out <- vector("list", length(parts))
  total_len <- 0
  for (i in seq_along(parts)) {
    p <- trimws(parts[[i]])
    if (!nzchar(p)) next
    step <- 1L
    if (grepl(":", p, fixed = TRUE)) {
      sp <- strsplit(p, ":", fixed = TRUE)[[1L]]
      if (length(sp) != 2L) next
      p <- trimws(sp[[1L]])
      step <- suppressWarnings(as.integer(sp[[2L]]))
      if (is.na(step) || step < 1L) next
    }
    if (grepl("-", p, fixed = TRUE)) {
      bounds <- suppressWarnings(as.numeric(strsplit(p, "-", fixed = TRUE)[[1L]]))
      if (length(bounds) == 2L && all(is.finite(bounds)) &&
          all(bounds == floor(bounds)) && bounds[[1L]] <= bounds[[2L]]) {
        range_len <- floor((bounds[[2L]] - bounds[[1L]]) / step) + 1
        if (total_len + range_len > max_indices) {
          cli::cli_abort(
            "SLURM array expression {.val {expr_orig}} exceeds {.arg max_indices} ({max_indices})."
          )
        }
        if (bounds[[2L]] > .Machine$integer.max || bounds[[1L]] < -.Machine$integer.max) {
          cli::cli_abort(
            "SLURM array expression {.val {expr_orig}} contains out-of-range integer bounds."
          )
        }
        chunks_out[[i]] <- seq.int(as.integer(bounds[[1L]]), as.integer(bounds[[2L]]), by = step)
        total_len <- total_len + range_len
      }
    } else {
      val <- suppressWarnings(as.integer(p))
      if (!is.na(val)) {
        if (total_len + 1 > max_indices) {
          cli::cli_abort(
            "SLURM array expression {.val {expr_orig}} exceeds {.arg max_indices} ({max_indices})."
          )
        }
        chunks_out[[i]] <- val
        total_len <- total_len + 1
      }
    }
  }
  out <- unlist(chunks_out, use.names = FALSE)
  if (is.null(out)) integer(0L) else unique(as.integer(out))
}

#' Plan Load-Balanced SLURM Array Chunk Assignments
#'
#' Partitions `n_tasks` tasks across `ceiling(n_tasks / chunk_size)` SLURM
#' array chunks using one of three strategies:
#' - `"contiguous"`: sequential contiguous slices (default).
#' - `"round_robin"`: interleaved modulo assignment, useful when tasks are
#'   ordered monotonically by problem size.
#' - `"lpt"`: Longest Processing Time first greedy load balancing using
#'   `task_weights` to minimize maximum chunk runtime (makespan) when tasks
#'   exhibit strong heterogeneity.
#'
#' @param n_tasks Positive integer total number of tasks.
#' @param chunk_size Positive integer target tasks per chunk (sets total chunk
#'   count `n_chunks = ceiling(n_tasks / chunk_size)`).
#' @param strategy Chunking strategy: `"contiguous"`, `"round_robin"`, or
#'   `"lpt"`.
#' @param task_weights Optional positive numeric vector of length `n_tasks`
#'   representing relative per-task cost or runtime (required for `"lpt"`).
#'
#' @return A [tibble::tibble()] with one row per chunk containing `chunk_id`,
#'   `start_task`, `end_task`, `n_tasks`, `task_indices` (list-column), and
#'   `estimated_weight`.
#' @export
#' @examples
#' weights <- c(100, 90, 80, 10, 10, 10, 5, 5)
#' plan_chunks(8L, chunk_size = 2L, strategy = "lpt", task_weights = weights)
plan_chunks <- function(
  n_tasks,
  chunk_size,
  strategy = c("contiguous", "round_robin", "lpt"),
  task_weights = NULL
) {
  sp_partition_tasks(
    n_tasks = n_tasks,
    chunk_size = chunk_size,
    strategy = strategy,
    task_weights = task_weights
  )
}

sp_partition_tasks <- function(
  n_tasks,
  chunk_size,
  strategy = c("contiguous", "round_robin", "lpt"),
  task_weights = NULL
) {
  checkmate::assert_int(n_tasks, lower = 1L)
  checkmate::assert_int(chunk_size, lower = 1L)
  strategy <- match.arg(strategy)

  if (!is.null(task_weights)) {
    checkmate::assert_numeric(task_weights, len = n_tasks, lower = 0, finite = TRUE, any.missing = FALSE)
    weights <- pmax(as.numeric(task_weights), 1e-9)
  } else {
    if (strategy == "lpt") {
      cli::cli_abort("{.arg task_weights} (length {n_tasks}) must be supplied when {.code strategy = 'lpt'}.")
    }
    weights <- rep(1, n_tasks)
  }

  chunk_size <- min(as.integer(chunk_size), as.integer(n_tasks))
  n_chunks <- as.integer(ceiling(n_tasks / chunk_size))
  chunk_ids <- seq_len(n_chunks)

  if (strategy == "contiguous") {
    starts <- (chunk_ids - 1L) * chunk_size + 1L
    ends <- pmin(chunk_ids * chunk_size, n_tasks)
    task_lists <- Map(seq.int, starts, ends)
    chunk_w <- vapply(task_lists, function(idx) sum(weights[idx]), numeric(1L))
  } else if (strategy == "round_robin") {
    tids <- seq_len(n_tasks)
    assign_b <- ((tids - 1L) %% n_chunks) + 1L
    fac_b <- factor(assign_b, levels = chunk_ids)
    task_lists <- unname(split(tids, fac_b))
    starts <- vapply(task_lists, function(x) x[[1L]], integer(1L))
    ends <- vapply(task_lists, function(x) x[[length(x)]], integer(1L))
    chunk_w <- as.numeric(tapply(weights, fac_b, sum))
  } else {
    # LPT (Longest Processing Time first) greedy makespan minimization
    ord <- order(weights, decreasing = TRUE)
    chunk_assign <- integer(n_tasks)
    loads <- numeric(n_chunks)

    if (n_chunks == 1L) {
      chunk_assign[] <- 1L
      loads[[1L]] <- sum(weights)
    } else if (n_chunks <= 2048L) {
      # Fast C-level which.min() scan for typical SLURM array sizes
      for (i in seq_len(n_tasks)) {
        tid <- ord[[i]]
        best <- which.min(loads)
        chunk_assign[[tid]] <- best
        loads[[best]] <- loads[[best]] + weights[[tid]]
      }
    } else {
      # Binary min-heap O(N log M) for very large chunk counts
      h_load <- numeric(n_chunks)
      h_id <- chunk_ids
      for (i in seq_len(n_tasks)) {
        tid <- ord[[i]]
        best <- h_id[[1L]]
        chunk_assign[[tid]] <- best
        new_load <- h_load[[1L]] + weights[[tid]]
        h_load[[1L]] <- new_load
        pos <- 1L
        repeat {
          left <- 2L * pos
          if (left > n_chunks) break
          right <- left + 1L
          sm <- left
          if (right <= n_chunks) {
            rl <- h_load[[right]]
            ll <- h_load[[left]]
            if (rl < ll || (rl == ll && h_id[[right]] < h_id[[left]])) {
              sm <- right
            }
          }
          sl <- h_load[[sm]]
          if (sl < new_load || (sl == new_load && h_id[[sm]] < best)) {
            h_load[[pos]] <- sl
            h_id[[pos]] <- h_id[[sm]]
            h_load[[sm]] <- new_load
            h_id[[sm]] <- best
            pos <- sm
          } else {
            break
          }
        }
      }
      loads[h_id] <- h_load
    }

    task_lists <- unname(split(seq_len(n_tasks), factor(chunk_assign, levels = chunk_ids)))
    starts <- vapply(task_lists, function(x) x[[1L]], integer(1L))
    ends <- vapply(task_lists, function(x) x[[length(x)]], integer(1L))
    chunk_w <- loads
  }

  tibble::tibble(
    chunk_id = chunk_ids,
    start_task = as.integer(starts),
    end_task = as.integer(ends),
    n_tasks = as.integer(lengths(task_lists)),
    task_indices = task_lists,
    estimated_weight = as.numeric(chunk_w)
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
    "DL" = "TIMEOUT",
    "DEADLINE" = "TIMEOUT",
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
