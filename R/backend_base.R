# Abstract R6 SlurmBackend base class and shared staging/checkpoint helpers

sp_stage_job_bundle <- function(
  local_job_dir,
  job_spec,
  sbatch_work_dir = local_job_dir,
  container_sif = NULL,
  container_binds = character(),
  modules = character()
) {
  dir.create(file.path(local_job_dir, "logs"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(local_job_dir, "results"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(local_job_dir, "status"), recursive = TRUE, showWarnings = FALSE)

  payload <- list(
    fun = job_spec$fun,
    args_list = job_spec$args_list,
    packages = job_spec$packages,
    globals = job_spec$globals,
    seed = job_spec$seed,
    continue_on_error = job_spec$continue_on_error
  )
  payload_path <- file.path(local_job_dir, "payload.rds")
  sp_write_rds_atomic(payload, payload_path)

  chunks_tbl <- job_spec$resources$chunks
  chunks_rds_path <- file.path(local_job_dir, "chunks.rds")
  sp_write_rds_atomic(chunks_tbl, chunks_rds_path)

  chunks_json_list <- lapply(seq_len(nrow(chunks_tbl)), function(i) {
    list(
      chunk_id = chunks_tbl$chunk_id[[i]],
      start_task = chunks_tbl$start_task[[i]],
      end_task = chunks_tbl$end_task[[i]],
      n_tasks = chunks_tbl$n_tasks[[i]],
      task_indices = as.list(chunks_tbl$task_indices[[i]])
    )
  })
  chunks_json_path <- file.path(local_job_dir, "chunks.json")
  sp_write_json_atomic(chunks_json_list, chunks_json_path)

  worker_path <- file.path(local_job_dir, "worker.R")
  render_worker_script(output_path = worker_path)

  effective_sif <- job_spec$container_sif %||% container_sif
  effective_binds <- unique(c(container_binds, job_spec$container_binds %||% character()))
  effective_modules <- unique(c(modules, job_spec$modules))
  sbatch_path <- file.path(local_job_dir, "submit.sbatch")
  sbatch_obj <- render_sbatch_script(
    job_name = job_spec$name,
    resources = job_spec$resources,
    work_dir = sbatch_work_dir,
    worker_script = "worker.R",
    attempt = 1L,
    container_sif = effective_sif,
    container_binds = effective_binds,
    modules = effective_modules,
    env_vars = job_spec$env_vars,
    dependency = job_spec$dependency,
    output_path = sbatch_path
  )

  list(
    job_dir = local_job_dir,
    payload_path = payload_path,
    chunks_rds_path = chunks_rds_path,
    chunks_json_path = chunks_json_path,
    worker_path = worker_path,
    sbatch_path = sbatch_path,
    sbatch = sbatch_obj
  )
}

sp_build_status <- function(job_id, job_name, backend_name, chunks_tbl, extra = list()) {
  states <- chunks_tbl$state
  agg_state <- sp_aggregate_job_state(states)
  n_chunks <- nrow(chunks_tbl)
  n_pending <- sum(states == "PENDING")
  n_running <- sum(states == "RUNNING")
  n_completed <- sum(states == "COMPLETED")
  n_failed <- sum(states == "FAILED")
  n_oom <- sum(states == "OUT_OF_MEMORY")
  n_timeout <- sum(states == "TIMEOUT")
  n_cancelled <- sum(states == "CANCELLED")
  n_terminal_chunks <- sum(states %in% sp_terminal_states())
  progress <- if (n_chunks > 0L) n_completed / n_chunks else 0

  rss_vals <- chunks_tbl$peak_rss_mb
  peak_rss_max <- if (any(!is.na(rss_vals))) max(rss_vals, na.rm = TRUE) else NA_real_
  wall_vals <- chunks_tbl$wall_sec
  total_wall <- if (any(!is.na(wall_vals))) sum(wall_vals, na.rm = TRUE) else 0

  structure(
    list(
      job_id = job_id,
      job_name = job_name,
      backend = backend_name,
      state = agg_state,
      is_terminal = !(agg_state %in% c("PENDING", "RUNNING")),
      n_chunks = as.integer(n_chunks),
      n_pending = as.integer(n_pending),
      n_running = as.integer(n_running),
      n_completed = as.integer(n_completed),
      n_failed = as.integer(n_failed),
      n_oom = as.integer(n_oom),
      n_timeout = as.integer(n_timeout),
      n_cancelled = as.integer(n_cancelled),
      n_retryable = as.integer(n_failed + n_oom + n_timeout + n_cancelled),
      n_terminal_chunks = as.integer(n_terminal_chunks),
      progress = progress,
      peak_rss_max_mb = peak_rss_max,
      total_wall_sec = total_wall,
      checked_at = sp_timestamp(),
      chunks = chunks_tbl,
      extra = extra
    ),
    class = "slurmpilot_status"
  )
}

sp_simplify_results <- function(values) {
  if (length(values) == 0L) {
    return(values)
  }
  non_null <- Filter(Negate(is.null), values)
  if (length(non_null) == 0L) {
    return(values)
  }
  if (all(vapply(non_null, is.data.frame, logical(1L))) && length(non_null) == length(values)) {
    col_sets <- lapply(values, names)
    same_cols <- all(vapply(col_sets, function(cn) identical(cn, col_sets[[1L]]), logical(1L)))
    if (same_cols) {
      bound <- tryCatch(do.call(rbind, values), error = function(e) NULL)
      if (!is.null(bound)) {
        return(tibble::as_tibble(bound))
      }
    } else {
      all_cols <- unique(unlist(col_sets, use.names = FALSE))
      aligned <- lapply(values, function(df) {
        missing_cols <- setdiff(all_cols, names(df))
        for (mc in missing_cols) {
          df[[mc]] <- rep(NA, nrow(df))
        }
        df[, all_cols, drop = FALSE]
      })
      bound <- tryCatch(do.call(rbind, aligned), error = function(e) NULL)
      if (!is.null(bound)) {
        return(tibble::as_tibble(bound))
      }
    }
    return(values)
  }
  is_scalar_atomic <- vapply(
    values,
    function(v) is.atomic(v) && length(v) == 1L && !is.null(v),
    logical(1L)
  )
  if (all(is_scalar_atomic)) {
    return(unlist(values, use.names = FALSE))
  }
  values
}

sp_collect_checkpoints <- function(
  work_dir,
  resources,
  simplify = FALSE,
  allow_partial = FALSE,
  verify_checksum = TRUE
) {
  n_tasks <- resources$n_tasks
  n_chunks <- resources$n_chunks
  out <- vector("list", n_tasks)
  missing_chunks <- integer(0L)
  corrupt_chunks <- character(0L)
  failed_tasks <- integer(0L)

  results_dir <- file.path(work_dir, "results")
  status_dir <- file.path(work_dir, "status")

  for (cid in seq_len(n_chunks)) {
    res_path <- file.path(results_dir, sprintf("chunk_%04d.rds", cid))
    sp_assert_path_confined(res_path, work_dir, arg = "checkpoint_path")

    if (!file.exists(res_path)) {
      missing_chunks <- c(missing_chunks, cid)
      next
    }

    expected_sha <- NULL
    st_path <- file.path(status_dir, sprintf("chunk_%04d.json", cid))
    if (isTRUE(verify_checksum) && file.exists(st_path)) {
      sp_assert_path_confined(st_path, work_dir, arg = "status_path")
      st_json <- tryCatch(jsonlite::fromJSON(st_path, simplifyVector = TRUE), error = function(e) NULL)
      if (!is.null(st_json) && !is.null(st_json$checkpoint_sha256) &&
          !is.na(st_json$checkpoint_sha256) && nzchar(st_json$checkpoint_sha256)) {
        expected_sha <- as.character(st_json$checkpoint_sha256)
      }
    }

    check <- verify_checkpoint(
      result_path = res_path,
      expected_sha256 = if (isTRUE(verify_checksum)) expected_sha else NULL,
      require_sidecar = FALSE
    )

    if (!isTRUE(check$ok)) {
      corrupt_chunks <- c(corrupt_chunks, sprintf("chunk %d (%s)", cid, check$reason))
      next
    }

    chunk_obj <- check$object
    if (!is.list(chunk_obj) || is.null(chunk_obj$results)) {
      corrupt_chunks <- c(corrupt_chunks, sprintf("chunk %d (malformed checkpoint structure)", cid))
      next
    }

    for (item in chunk_obj$results) {
      tid <- as.integer(item$task_index)
      if (is.na(tid) || tid < 1L || tid > n_tasks) {
        corrupt_chunks <- c(corrupt_chunks, sprintf("chunk %d (out-of-range task index %s)", cid, as.character(tid)))
        next
      }
      if (isTRUE(item$ok)) {
        out[[tid]] <- item$value
      } else {
        failed_tasks <- c(failed_tasks, tid)
        out[[tid]] <- if (isTRUE(allow_partial)) {
          structure(list(error = item$error, task_index = tid), class = "slurmpilot_task_error")
        } else {
          NULL
        }
      }
    }
  }

  if (length(corrupt_chunks) > 0L) {
    if (!isTRUE(allow_partial)) {
      cli::cli_abort(c(
        "Checkpoint integrity check failed for {length(corrupt_chunks)} chunk{?s}:",
        "x" = "{paste(corrupt_chunks, collapse = '; ')}",
        "i" = "Run {.code slurm_retry(job)} to recompute corrupted chunks cleanly."
      ))
    } else {
      cli::cli_warn(
        "Skipping {length(corrupt_chunks)} corrupted chunk checkpoint{?s}: {paste(corrupt_chunks, collapse = '; ')}."
      )
    }
  }

  if (!isTRUE(allow_partial) && length(missing_chunks) > 0L) {
    cli::cli_abort(c(
      "Cannot collect complete results: {length(missing_chunks)} chunk checkpoint{?s} missing ({paste(missing_chunks, collapse = ', ')}).",
      "i" = "Run {.code slurm_retry(job)} to recover failed chunks, or pass {.code allow_partial = TRUE}."
    ))
  }

  if (!isTRUE(allow_partial) && length(failed_tasks) > 0L) {
    cli::cli_abort(c(
      "Cannot collect complete results: {length(failed_tasks)} task{?s} failed ({paste(head(failed_tasks, 10L), collapse = ', ')}).",
      "i" = "Inspect logs with {.code slurm_logs(job)} or pass {.code allow_partial = TRUE}."
    ))
  }

  if (isTRUE(simplify)) {
    out <- sp_simplify_results(out)
  }
  out
}

#' Abstract Base Class for `slurmpilot` Scheduler Backends
#'
#' Defines the pluggable R6 interface implemented by [MockSlurmBackend] and
#' [SlurmSshBackend]. Custom HPC scheduler adapters (e.g., PBS/Torque, LSF, or
#' cloud batch APIs) can subclass `SlurmBackend` and override `submit()`,
#' `status()`, `retry()`, `cancel()`, `logs()`, and `collect()`.
#'
#' @export
#' @examples
#' be <- SlurmBackend$new()
#' print(be)
SlurmBackend <- R6::R6Class(
  classname = "SlurmBackend",
  public = list(
    #' @field name Character identifier of the backend implementation.
    name = "abstract",

    #' @description Initialize the backend.
    initialize = function() {
      invisible(self)
    },

    #' @description Submit a `slurmpilot_job_spec` to the scheduler.
    #' @param job_spec A `slurmpilot_job_spec` object.
    #' @param ... Backend-specific submission options.
    #' @return A `slurmpilot_job` handle.
    submit = function(job_spec, ...) {
      cli::cli_abort("Method {.fn submit} must be implemented by a {.cls SlurmBackend} subclass.")
    },

    #' @description Poll current job and per-chunk status.
    #' @param job A `slurmpilot_job` handle.
    #' @return A `slurmpilot_status` object.
    status = function(job) {
      cli::cli_abort("Method {.fn status} must be implemented by a {.cls SlurmBackend} subclass.")
    },

    #' @description Surgically retry failed/cancelled chunks without rerunning completed ones.
    #' @param job A `slurmpilot_job` handle.
    #' @param chunks Optional integer vector of chunk IDs to retry (defaults to all retryable chunks).
    #' @param resources Optional updated `slurmpilot_resources` spec (e.g. bumped `--mem` or `--time`).
    #' @return Updated `slurmpilot_job` handle.
    retry = function(job, chunks = NULL, resources = NULL) {
      cli::cli_abort("Method {.fn retry} must be implemented by a {.cls SlurmBackend} subclass.")
    },

    #' @description Cancel active chunks for a job.
    #' @param job A `slurmpilot_job` handle.
    #' @param chunks Optional integer vector of chunk IDs to cancel (default: all active chunks).
    #' @return Latest `slurmpilot_status` invisibly.
    cancel = function(job, chunks = NULL) {
      cli::cli_abort("Method {.fn cancel} must be implemented by a {.cls SlurmBackend} subclass.")
    },

    #' @description Retrieve stdout/stderr logs for one or all chunks.
    #' @param job A `slurmpilot_job` handle.
    #' @param chunk_id Optional integer chunk ID.
    #' @return Named list of log records (`stdout`, `stderr`) per chunk.
    logs = function(job, chunk_id = NULL) {
      cli::cli_abort("Method {.fn logs} must be implemented by a {.cls SlurmBackend} subclass.")
    },

    #' @description Collect ordered task results from completed chunk checkpoints.
    #' @param job A `slurmpilot_job` handle.
    #' @param simplify Logical; simplify homogeneous scalar or data-frame outputs.
    #' @param allow_partial Logical; allow collecting incomplete results.
    #' @return Ordered list (or simplified vector/tibble) of task results.
    collect = function(job, simplify = FALSE, allow_partial = FALSE) {
      cli::cli_abort("Method {.fn collect} must be implemented by a {.cls SlurmBackend} subclass.")
    },

    #' @description Block until a job reaches a terminal state or timeout elapses.
    #' @param job A `slurmpilot_job` handle.
    #' @param timeout Maximum wait time in seconds. Default `Inf`.
    #' @param poll_interval Polling cadence in seconds. Default `0.2`.
    #' @param progress Logical; emit periodic progress updates. Default `FALSE`.
    #' @return Terminal (or latest on timeout) `slurmpilot_status` object.
    wait = function(job, timeout = Inf, poll_interval = 0.2, progress = FALSE) {
      checkmate::assert_class(job, "slurmpilot_job")
      checkmate::assert_number(timeout, lower = 0)
      checkmate::assert_number(poll_interval, lower = 0.01, finite = TRUE)
      checkmate::assert_flag(progress)

      t0 <- proc.time()[["elapsed"]]
      last_done <- -1L
      repeat {
        st <- self$status(job)
        if (progress && st$n_completed != last_done) {
          cli::cli_inform(
            "Job {st$job_name} [{st$state}]: {st$n_completed}/{st$n_chunks} chunks completed (running={st$n_running}, pending={st$n_pending}, retryable={st$n_retryable})"
          )
          last_done <- st$n_completed
        }
        if (isTRUE(st$is_terminal)) {
          return(st)
        }
        if ((proc.time()[["elapsed"]] - t0) >= timeout) {
          cli::cli_warn("Timed out waiting for job {st$job_id} after {round(timeout, 1)}s (state={st$state}).")
          return(st)
        }
        Sys.sleep(poll_interval)
      }
    },

    #' @description Clean up local staging files for a job.
    #' @param job A `slurmpilot_job` handle.
    cleanup = function(job) {
      checkmate::assert_class(job, "slurmpilot_job")
      if (!is.null(job$local_dir) && dir.exists(job$local_dir)) {
        unlink(job$local_dir, recursive = TRUE, force = TRUE)
      }
      invisible(TRUE)
    },

    #' @description Print a concise summary of the backend.
    print = function() {
      cli::cli_inform("<{.cls {class(self)[[1L]]}}> (backend: {self$name})")
      invisible(self)
    }
  )
)
