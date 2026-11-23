# Local parallel Mock SLURM Scheduler backend using processx + ps

sp_merge_env <- function(overrides) {
  base_env <- Sys.getenv()
  if (length(overrides) == 0L) {
    return(base_env)
  }
  for (nm in names(overrides)) {
    base_env[[nm]] <- as.character(overrides[[nm]])
  }
  base_env
}

#' Local Parallel Mock SLURM Scheduler Backend
#'
#' Full-featured local SLURM array simulator that executes the exact generated
#' `worker.R` script in isolated background R processes via `processx`,
#' throttled by a configurable concurrency queue (`max_workers`). Supports live
#' OS RSS polling via `ps`, disk-based atomic chunk checkpoints, real or
#' simulated `FAILED` / `OUT_OF_MEMORY` / `TIMEOUT` / `CANCELLED` states,
#' surgical retry of failed chunks, cancellation, log inspection, and ordered
#' result collection — enabling 100% offline development and testing on a laptop.
#'
#' @export
#' @examples
#' be <- MockSlurmBackend$new(max_workers = 2L)
#' print(be)
#' unlink(be$root_dir, recursive = TRUE)
MockSlurmBackend <- R6::R6Class(
  classname = "MockSlurmBackend",
  inherit = SlurmBackend,
  public = list(
    #' @field name Backend identifier (`"mock_slurm"`).
    name = "mock_slurm",
    #' @field root_dir Root directory storing simulated job workspaces.
    root_dir = NULL,
    #' @field max_workers Maximum concurrent background R worker processes.
    max_workers = 2L,
    #' @field queue_delay Optional simulated queue wait delay in seconds before dispatching pending chunks.
    queue_delay = 0,
    #' @field mem_limit_mb Optional enforced RSS limit in MB (exceeding triggers `OUT_OF_MEMORY`).
    mem_limit_mb = NULL,
    #' @field time_limit_sec Optional enforced walltime limit in seconds (exceeding triggers `TIMEOUT`).
    time_limit_sec = NULL,
    #' @field fault_injection Default fault injection specification (`fail_chunks`, `oom_chunks`, `timeout_chunks`, `fail_once`).
    fault_injection = list(),
    #' @field rscript_bin Path to the `Rscript` executable used for worker processes.
    rscript_bin = NULL,

    #' @description Create a new `MockSlurmBackend`.
    #' @param root_dir Optional directory path for job staging and checkpoints.
    #'   Defaults to a unique temporary directory.
    #' @param max_workers Positive integer maximum concurrent worker slots. Default `2L`.
    #' @param queue_delay Non-negative numeric queue delay in seconds before starting
    #'   pending chunks. Default `0`.
    #' @param mem_limit_mb Optional positive numeric RSS ceiling in MB to actively
    #'   enforce against background worker processes.
    #' @param time_limit_sec Optional positive numeric walltime ceiling in seconds to
    #'   actively enforce against background worker processes.
    #' @param fault_injection Optional named list with any of `fail_chunks`,
    #'   `oom_chunks`, `timeout_chunks` (integer vectors) and `fail_once` (logical,
    #'   default `TRUE`).
    #' @param rscript_bin Optional explicit path to `Rscript`. Defaults to the active
    #'   R installation's `Rscript`.
    initialize = function(
      root_dir = NULL,
      max_workers = 2L,
      queue_delay = 0,
      mem_limit_mb = NULL,
      time_limit_sec = NULL,
      fault_injection = list(),
      rscript_bin = NULL
    ) {
      checkmate::assert_int(max_workers, lower = 1L)
      checkmate::assert_number(queue_delay, lower = 0, finite = TRUE)
      if (!is.null(mem_limit_mb)) checkmate::assert_number(mem_limit_mb, lower = 1, finite = TRUE)
      if (!is.null(time_limit_sec)) checkmate::assert_number(time_limit_sec, lower = 0.05, finite = TRUE)
      checkmate::assert_list(fault_injection)

      if (is.null(root_dir)) {
        root_dir <- tempfile("slurmpilot_mock_")
      }
      dir.create(root_dir, recursive = TRUE, showWarnings = FALSE)
      self$root_dir <- normalizePath(root_dir, winslash = "/", mustWork = FALSE)
      self$max_workers <- as.integer(max_workers)
      self$queue_delay <- queue_delay
      self$mem_limit_mb <- mem_limit_mb
      self$time_limit_sec <- time_limit_sec
      self$fault_injection <- fault_injection
      self$rscript_bin <- rscript_bin %||% file.path(R.home("bin"), "Rscript")
      invisible(self)
    },

    #' @description Update default fault injection rules for future submissions.
    #' @param fail_chunks Integer vector of chunk IDs to fail.
    #' @param oom_chunks Integer vector of chunk IDs to OOM-kill.
    #' @param timeout_chunks Integer vector of chunk IDs to timeout-kill.
    #' @param fail_once Logical; if `TRUE` (default), faults trigger only on attempt 1.
    set_fault_injection = function(
      fail_chunks = integer(),
      oom_chunks = integer(),
      timeout_chunks = integer(),
      fail_once = TRUE
    ) {
      self$fault_injection <- list(
        fail_chunks = as.integer(fail_chunks),
        oom_chunks = as.integer(oom_chunks),
        timeout_chunks = as.integer(timeout_chunks),
        fail_once = isTRUE(fail_once)
      )
      invisible(self)
    },

    #' @description Submit a `slurmpilot_job_spec` to the local mock scheduler.
    #' @param job_spec A `slurmpilot_job_spec` object.
    #' @param fault_injection Optional per-job fault injection override.
    #' @param ... Unused.
    #' @return A `slurmpilot_job` handle.
    submit = function(job_spec, fault_injection = NULL, ...) {
      checkmate::assert_class(job_spec, "slurmpilot_job_spec")
      job_id <- sp_generate_id("mock")
      job_dir <- file.path(self$root_dir, job_id)
      staged <- sp_stage_job_bundle(local_job_dir = job_dir, job_spec = job_spec)

      n_chunks <- job_spec$resources$n_chunks
      now <- Sys.time()
      eligible <- now + self$queue_delay
      fi <- fault_injection %||% self$fault_injection

      chunk_records <- lapply(seq_len(n_chunks), function(cid) {
        list(
          chunk_id = as.integer(cid),
          n_tasks = job_spec$resources$chunks$n_tasks[[cid]],
          state = "PENDING",
          attempt = 1L,
          worker_id = NA_character_,
          started_at = NA_character_,
          finished_at = NA_character_,
          started_mono = NA_real_,
          eligible_at = eligible,
          wall_sec = NA_real_,
          peak_rss_mb = NA_real_,
          exit_code = NA_integer_,
          error_message = NA_character_,
          checkpoint_exists = FALSE
        )
      })
      names(chunk_records) <- as.character(seq_len(n_chunks))

      private$jobs[[job_id]] <- list(
        job_id = job_id,
        job_name = job_spec$name,
        job_dir = job_dir,
        resources = job_spec$resources,
        staged = staged,
        fault_injection = fi,
        chunks = chunk_records,
        procs = list(),
        created_at = sp_timestamp(now)
      )

      private$tick_all()

      job <- new_slurmpilot_job(
        job_id = job_id,
        job_name = job_spec$name,
        backend = self,
        resources = job_spec$resources,
        local_dir = job_dir,
        remote_dir = NULL,
        scheduler_ids = job_id,
        spec = job_spec
      )
      job
    },

    #' @description Advance the local scheduler queue and return current job status.
    #' @param job A `slurmpilot_job` handle.
    #' @return A `slurmpilot_status` object.
    status = function(job) {
      checkmate::assert_class(job, "slurmpilot_job")
      rec <- private$get_job_record(job$job_id)
      private$tick_all()
      rec <- private$get_job_record(job$job_id)

      rows <- lapply(rec$chunks, function(ch) {
        tibble::tibble(
          chunk_id = as.integer(ch$chunk_id),
          n_tasks = as.integer(ch$n_tasks),
          state = as.character(ch$state),
          attempt = as.integer(ch$attempt),
          worker_id = as.character(ch$worker_id),
          started_at = as.character(ch$started_at),
          finished_at = as.character(ch$finished_at),
          wall_sec = as.numeric(ch$wall_sec),
          peak_rss_mb = as.numeric(ch$peak_rss_mb),
          exit_code = as.integer(ch$exit_code),
          error_message = as.character(ch$error_message),
          checkpoint_exists = isTRUE(ch$checkpoint_exists)
        )
      })
      chunks_tbl <- do.call(rbind, rows)
      chunks_tbl <- chunks_tbl[order(chunks_tbl$chunk_id), , drop = FALSE]

      sp_build_status(
        job_id = rec$job_id,
        job_name = rec$job_name,
        backend_name = self$name,
        chunks_tbl = chunks_tbl
      )
    },

    #' @description Surgically retry failed/OOM/timed-out/cancelled chunks.
    #' @param job A `slurmpilot_job` handle.
    #' @param chunks Optional integer vector of chunk IDs to retry.
    #' @param resources Optional updated `slurmpilot_resources` spec.
    #' @return Updated `slurmpilot_job` handle.
    retry = function(job, chunks = NULL, resources = NULL) {
      checkmate::assert_class(job, "slurmpilot_job")
      private$tick_all()
      rec <- private$get_job_record(job$job_id)

      if (!is.null(resources)) {
        checkmate::assert_class(resources, "slurmpilot_resources")
        rec$resources <- resources
        job$resources <- resources
      }

      if (is.null(chunks)) {
        chunks <- vapply(
          Filter(function(ch) ch$state %in% sp_retryable_states(), rec$chunks),
          function(ch) ch$chunk_id,
          integer(1L)
        )
      } else {
        checkmate::assert_integerish(chunks, lower = 1L, upper = rec$resources$n_chunks, min.len = 1L)
        chunks <- sort(unique(as.integer(chunks)))
      }

      if (length(chunks) == 0L) {
        cli::cli_inform("Job {job$job_id}: no retryable chunks found.")
        return(job)
      }

      now <- Sys.time()
      max_attempt <- 1L
      for (cid in chunks) {
        key <- as.character(cid)
        ch <- rec$chunks[[key]]
        # Kill and reap if still running
        if (!is.null(rec$procs[[key]])) {
          sp_kill_and_reap(rec$procs[[key]])
          rec$procs[[key]] <- NULL
        }
        ch$attempt <- as.integer(ch$attempt + 1L)
        max_attempt <- max(max_attempt, ch$attempt)
        ch$state <- "PENDING"
        ch$worker_id <- NA_character_
        ch$started_at <- NA_character_
        ch$finished_at <- NA_character_
        ch$started_mono <- NA_real_
        ch$eligible_at <- now + self$queue_delay
        ch$wall_sec <- NA_real_
        ch$exit_code <- NA_integer_
        ch$error_message <- NA_character_
        ch$checkpoint_exists <- FALSE
        rec$chunks[[key]] <- ch

        # Remove stale status, partial checkpoint, and checksum sidecar for ONLY the retried chunk
        res_f <- file.path(rec$job_dir, "results", sprintf("chunk_%04d.rds", cid))
        unlink(file.path(rec$job_dir, "status", sprintf("chunk_%04d.json", cid)), force = TRUE)
        unlink(res_f, force = TRUE)
        unlink(paste0(res_f, ".sha256"), force = TRUE)
      }

      # Emit retry sbatch script for parity with SLURM workflow
      render_sbatch_script(
        job_name = rec$job_name,
        resources = rec$resources,
        work_dir = rec$job_dir,
        array_indices = chunks,
        attempt = max_attempt,
        output_path = file.path(rec$job_dir, sprintf("retry_%d.sbatch", max_attempt))
      )

      private$jobs[[job$job_id]] <- rec
      private$tick_all()
      job
    },

    #' @description Cancel active chunks (PENDING or RUNNING) for a job.
    #' @param job A `slurmpilot_job` handle.
    #' @param chunks Optional integer vector of chunk IDs to cancel.
    #' @return Updated `slurmpilot_status` invisibly.
    cancel = function(job, chunks = NULL) {
      checkmate::assert_class(job, "slurmpilot_job")
      rec <- private$get_job_record(job$job_id)

      target_ids <- if (is.null(chunks)) {
        seq_len(rec$resources$n_chunks)
      } else {
        checkmate::assert_integerish(chunks, lower = 1L, upper = rec$resources$n_chunks, min.len = 1L)
        sort(unique(as.integer(chunks)))
      }

      for (cid in target_ids) {
        key <- as.character(cid)
        ch <- rec$chunks[[key]]
        if (ch$state %in% c("PENDING", "RUNNING")) {
          if (!is.null(rec$procs[[key]])) {
            sp_kill_and_reap(rec$procs[[key]])
            rec$procs[[key]] <- NULL
          }
          ch$state <- "CANCELLED"
          ch$finished_at <- sp_timestamp()
          ch$error_message <- "Cancelled by user"
          if (!is.na(ch$started_mono)) {
            ch$wall_sec <- max(0, proc.time()[["elapsed"]] - ch$started_mono)
          }
          rec$chunks[[key]] <- ch
        }
      }

      private$jobs[[job$job_id]] <- rec
      private$persist_job_state(rec)
      invisible(self$status(job))
    },

    #' @description Read stdout and stderr logs for one or all chunks.
    #' @param job A `slurmpilot_job` handle.
    #' @param chunk_id Optional integer chunk ID.
    #' @return Named list of `list(stdout = ..., stderr = ...)` entries.
    logs = function(job, chunk_id = NULL) {
      checkmate::assert_class(job, "slurmpilot_job")
      rec <- private$get_job_record(job$job_id)
      cids <- if (is.null(chunk_id)) {
        seq_len(rec$resources$n_chunks)
      } else {
        checkmate::assert_int(chunk_id, lower = 1L, upper = rec$resources$n_chunks)
        as.integer(chunk_id)
      }

      out <- lapply(cids, function(cid) {
        out_path <- file.path(rec$job_dir, "logs", sprintf("chunk_%d.out", cid))
        err_path <- file.path(rec$job_dir, "logs", sprintf("chunk_%d.err", cid))
        list(
          chunk_id = cid,
          stdout = if (file.exists(out_path)) paste(readLines(out_path, warn = FALSE), collapse = "\n") else "",
          stderr = if (file.exists(err_path)) paste(readLines(err_path, warn = FALSE), collapse = "\n") else ""
        )
      })
      names(out) <- paste0("chunk_", cids)
      out
    },

    #' @description Collect ordered results from completed chunk checkpoints on disk.
    #' @param job A `slurmpilot_job` handle.
    #' @param simplify Logical; simplify homogeneous scalar or data-frame results.
    #' @param allow_partial Logical; allow returning partial results if some chunks failed.
    #' @return Ordered list (or simplified vector/tibble) of task results.
    collect = function(job, simplify = FALSE, allow_partial = FALSE) {
      checkmate::assert_class(job, "slurmpilot_job")
      rec <- private$get_job_record(job$job_id)
      private$tick_all()
      sp_collect_checkpoints(
        work_dir = rec$job_dir,
        resources = rec$resources,
        simplify = simplify,
        allow_partial = allow_partial
      )
    },

    #' @description Terminate and reap all active background worker processes cleanly.
    #' @return Integer count of reaped worker processes (invisibly).
    shutdown = function() {
      reaped <- 0L
      for (jid in names(private$jobs)) {
        rec <- private$jobs[[jid]]
        for (key in names(rec$procs)) {
          sp_kill_and_reap(rec$procs[[key]])
          rec$procs[[key]] <- NULL
          reaped <- reaped + 1L
        }
        private$jobs[[jid]] <- rec
      }
      invisible(reaped)
    },

    #' @description Print summary of the local mock backend.
    print = function() {
      n_jobs <- length(private$jobs)
      n_active <- private$count_active_workers()
      cli::cli_inform(
        "<{.cls MockSlurmBackend}> root={.path {self$root_dir}}, max_workers={self$max_workers}, jobs={n_jobs}, active_workers={n_active}"
      )
      invisible(self)
    }
  ),
  private = list(
    jobs = list(),

    finalize = function() {
      self$shutdown()
    },

    get_job_record = function(job_id) {
      sp_assert_safe_id(job_id, arg = "job_id")
      rec <- private$jobs[[job_id]]
      if (is.null(rec)) {
        cli::cli_abort("Unknown mock SLURM job ID: {.val {job_id}}.")
      }
      sp_assert_path_confined(rec$job_dir, self$root_dir, arg = "job_dir")
      rec
    },

    count_active_workers = function() {
      total <- 0L
      for (jid in names(private$jobs)) {
        total <- total + length(private$jobs[[jid]]$procs)
      }
      total
    },

    resolve_chunk_fault = function(fi, cid, attempt) {
      if (length(fi) == 0L) return("")
      fail_once <- if (is.null(fi$fail_once)) TRUE else isTRUE(fi$fail_once)
      if (fail_once && attempt > 1L) return("")
      if (cid %in% (fi$oom_chunks %||% integer())) return("OOM")
      if (cid %in% (fi$timeout_chunks %||% integer())) return("TIMEOUT")
      if (cid %in% (fi$fail_chunks %||% integer())) return("FAIL")
      ""
    },

    persist_job_state = function(rec) {
      state_payload <- list(
        job_id = rec$job_id,
        job_name = rec$job_name,
        created_at = rec$created_at,
        updated_at = sp_timestamp(),
        chunks = unname(lapply(rec$chunks, function(ch) {
          list(
            chunk_id = ch$chunk_id,
            state = ch$state,
            attempt = ch$attempt,
            worker_id = ch$worker_id,
            wall_sec = ch$wall_sec,
            peak_rss_mb = ch$peak_rss_mb,
            exit_code = ch$exit_code,
            error_message = ch$error_message,
            checkpoint_exists = ch$checkpoint_exists
          )
        }))
      )
      try(sp_write_json_atomic(state_payload, file.path(rec$job_dir, "state.json")), silent = TRUE)
    },

    tick_all = function() {
      now <- Sys.time()
      now_mono <- proc.time()[["elapsed"]]

      # Phase 1: Reap finished / poll live RSS / enforce limits
      for (jid in names(private$jobs)) {
        rec <- private$jobs[[jid]]
        changed <- FALSE
        for (key in names(rec$procs)) {
          proc <- rec$procs[[key]]
          ch <- rec$chunks[[key]]
          cid <- ch$chunk_id

          if (proc$is_alive()) {
            rss <- sp_process_tree_rss_mb(proc$get_pid())
            if (!is.na(rss)) {
              ch$peak_rss_mb <- if (is.na(ch$peak_rss_mb)) rss else max(ch$peak_rss_mb, rss)
            }
            elapsed <- max(0, now_mono - ch$started_mono)
            ch$wall_sec <- elapsed

            # Check active RSS limit
            if (!is.null(self$mem_limit_mb) && !is.na(ch$peak_rss_mb) && ch$peak_rss_mb > self$mem_limit_mb) {
              sp_kill_and_reap(proc)
              rec$procs[[key]] <- NULL
              ch$state <- "OUT_OF_MEMORY"
              ch$finished_at <- sp_timestamp(now)
              ch$exit_code <- 137L
              ch$error_message <- sprintf(
                "Peak RSS %.1f MB exceeded simulated limit %.1f MB",
                ch$peak_rss_mb, self$mem_limit_mb
              )
              ch$checkpoint_exists <- FALSE
              changed <- TRUE
            } else if (!is.null(self$time_limit_sec) && elapsed > self$time_limit_sec) {
              sp_kill_and_reap(proc)
              rec$procs[[key]] <- NULL
              ch$state <- "TIMEOUT"
              ch$finished_at <- sp_timestamp(now)
              ch$exit_code <- 124L
              ch$error_message <- sprintf(
                "Elapsed %.2fs exceeded simulated walltime limit %.2fs",
                elapsed, self$time_limit_sec
              )
              ch$checkpoint_exists <- FALSE
              changed <- TRUE
            }
            rec$chunks[[key]] <- ch
          } else {
            # Process finished: wait briefly so OS flushes streams/files before reading
            try(proc$wait(timeout = 500L), silent = TRUE)
            exit_code <- tryCatch(as.integer(proc$get_exit_status()), error = function(e) 1L)
            rec$procs[[key]] <- NULL
            # Protect terminal CANCELLED chunks against stale transition overwrite
            if (identical(ch$state, "CANCELLED")) {
              rec$chunks[[key]] <- ch
              next
            }
            elapsed <- max(0, now_mono - ch$started_mono)
            status_path <- file.path(rec$job_dir, "status", sprintf("chunk_%04d.json", cid))
            result_path <- file.path(rec$job_dir, "results", sprintf("chunk_%04d.rds", cid))

            st_json <- if (file.exists(status_path)) {
              tryCatch(
                jsonlite::fromJSON(status_path, simplifyVector = TRUE),
                error = function(e) NULL
              )
            } else {
              NULL
            }

            if (!is.null(st_json)) {
              ch$state <- sp_normalize_slurm_state(st_json$state %||% "FAILED")
              ch$finished_at <- as.character(st_json$finished_at %||% sp_timestamp(now))
              ch$wall_sec <- as.numeric(st_json$wall_sec %||% elapsed)
              if (!is.null(st_json$peak_rss_mb) && !is.na(st_json$peak_rss_mb)) {
                ch$peak_rss_mb <- if (is.na(ch$peak_rss_mb)) {
                  as.numeric(st_json$peak_rss_mb)
                } else {
                  max(ch$peak_rss_mb, as.numeric(st_json$peak_rss_mb))
                }
              }
              ch$exit_code <- as.integer(st_json$exit_code %||% exit_code)
              ch$error_message <- if (is.null(st_json$error_message)) NA_character_ else as.character(st_json$error_message)
              ch$checkpoint_exists <- file.exists(result_path) && isTRUE(verify_checkpoint(result_path)$ok)
            } else {
              ch$finished_at <- sp_timestamp(now)
              ch$wall_sec <- elapsed
              ch$exit_code <- exit_code
              ch$state <- if (identical(exit_code, 0L)) {
                "COMPLETED"
              } else if (identical(exit_code, 137L)) {
                "OUT_OF_MEMORY"
              } else if (identical(exit_code, 124L)) {
                "TIMEOUT"
              } else {
                "FAILED"
              }
              err_log <- file.path(rec$job_dir, "logs", sprintf("chunk_%d.err", cid))
              if (ch$state != "COMPLETED" && file.exists(err_log)) {
                err_lines <- readLines(err_log, warn = FALSE)
                ch$error_message <- paste(utils::tail(err_lines, 5L), collapse = "\n")
              }
              ch$checkpoint_exists <- file.exists(result_path) && isTRUE(verify_checkpoint(result_path)$ok)
            }

            rec$chunks[[key]] <- ch
            changed <- TRUE
          }
        }
        private$jobs[[jid]] <- rec
        if (changed) {
          private$persist_job_state(rec)
        }
      }

      # Phase 2: Dispatch eligible PENDING chunks up to max_workers
      active_now <- private$count_active_workers()
      if (active_now >= self$max_workers) {
        return(invisible(NULL))
      }

      for (jid in names(private$jobs)) {
        if (active_now >= self$max_workers) break
        rec <- private$jobs[[jid]]
        dispatched <- FALSE

        for (cid in seq_len(rec$resources$n_chunks)) {
          if (active_now >= self$max_workers) break
          key <- as.character(cid)
          ch <- rec$chunks[[key]]
          if (ch$state == "PENDING" && now >= ch$eligible_at) {
            out_log <- file.path(rec$job_dir, "logs", sprintf("chunk_%d.out", cid))
            err_log <- file.path(rec$job_dir, "logs", sprintf("chunk_%d.err", cid))
            fault <- private$resolve_chunk_fault(rec$fault_injection, cid, ch$attempt)

            env_overrides <- list(
              SLURMPILOT_WORK_DIR = rec$job_dir,
              SLURMPILOT_CHUNK_ID = as.character(cid),
              SLURM_ARRAY_TASK_ID = as.character(cid),
              SLURM_CPUS_PER_TASK = as.character(rec$resources$cpus_per_task),
              SLURMPILOT_ATTEMPT = as.character(ch$attempt),
              SLURMPILOT_MOCK_FAULT = fault
            )

            proc <- processx::process$new(
              command = self$rscript_bin,
              args = c(
                file.path(rec$job_dir, "worker.R"),
                "--work-dir", rec$job_dir,
                "--chunk-id", as.character(cid),
                "--attempt", as.character(ch$attempt)
              ),
              stdout = out_log,
              stderr = err_log,
              env = sp_merge_env(env_overrides),
              supervise = FALSE
            )

            rec$procs[[key]] <- proc
            ch$state <- "RUNNING"
            ch$worker_id <- paste0("mock-", proc$get_pid())
            ch$started_at <- sp_timestamp(now)
            ch$started_mono <- proc.time()[["elapsed"]]
            ch$peak_rss_mb <- sp_process_tree_rss_mb(proc$get_pid())
            rec$chunks[[key]] <- ch
            active_now <- active_now + 1L
            dispatched <- TRUE
          }
        }

        private$jobs[[jid]] <- rec
        if (dispatched) {
          private$persist_job_state(rec)
        }
      }
      invisible(NULL)
    }
  )
)

#' Create a Local Parallel Mock SLURM Backend
#'
#' Convenience constructor wrapping [MockSlurmBackend]`$new(...)`.
#'
#' @param root_dir Optional directory path for job staging and checkpoints.
#'   Defaults to a unique temporary directory.
#' @param max_workers Positive integer maximum concurrent worker slots. Default `2L`.
#' @param queue_delay Non-negative numeric queue delay in seconds before starting
#'   pending chunks. Default `0`.
#' @param mem_limit_mb Optional positive numeric RSS ceiling in MB to actively
#'   enforce against background worker processes.
#' @param time_limit_sec Optional positive numeric walltime ceiling in seconds to
#'   actively enforce against background worker processes.
#' @param fault_injection Optional named list with any of `fail_chunks`,
#'   `oom_chunks`, `timeout_chunks` (integer vectors) and `fail_once` (logical,
#'   default `TRUE`).
#' @param rscript_bin Optional explicit path to `Rscript`. Defaults to the active
#'   R installation's `Rscript`.
#' @return A [MockSlurmBackend] R6 object.
#' @export
#' @examples
#' backend <- mock_slurm_backend(max_workers = 2L)
#' print(backend)
#' unlink(backend$root_dir, recursive = TRUE)
mock_slurm_backend <- function(
  root_dir = NULL,
  max_workers = 2L,
  queue_delay = 0,
  mem_limit_mb = NULL,
  time_limit_sec = NULL,
  fault_injection = list(),
  rscript_bin = NULL
) {
  MockSlurmBackend$new(
    root_dir = root_dir,
    max_workers = max_workers,
    queue_delay = queue_delay,
    mem_limit_mb = mem_limit_mb,
    time_limit_sec = time_limit_sec,
    fault_injection = fault_injection,
    rscript_bin = rscript_bin
  )
}
