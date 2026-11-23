# User-facing S3 job specification, job handle, lifecycle API & autopilot

new_slurmpilot_job <- function(
  job_id,
  job_name,
  backend,
  resources,
  local_dir,
  remote_dir = NULL,
  scheduler_ids = character(),
  spec = NULL,
  meta = list()
) {
  structure(
    list(
      job_id = job_id,
      job_name = job_name,
      backend = backend,
      resources = resources,
      local_dir = local_dir,
      remote_dir = remote_dir,
      scheduler_ids = scheduler_ids,
      spec = spec,
      submitted_at = sp_timestamp(),
      meta = meta
    ),
    class = "slurmpilot_job"
  )
}

#' Construct a SLURM Array Job Specification
#'
#' Bundles a worker function, argument list, resource plan, packages, globals,
#' and optional Apptainer/module metadata into a validated `slurmpilot_job_spec`
#' ready for [slurm_submit()].
#'
#' @param fun Function accepting a single element of `args_list` (`fun(arg)`).
#' @param args_list Non-empty list (or vector coercible to list) of task inputs.
#' @param resources Optional `slurmpilot_resources` object from
#'   [estimate_resources()] or [resource_spec()]. If `NULL`, creates a sensible
#'   default `resource_spec(n_tasks = length(args_list))`.
#' @param name Optional job name (sanitized for SLURM `--job-name`).
#' @param packages Character vector of packages to load on workers.
#' @param globals Named list of helper objects/functions bound to `fun`.
#' @param seed Optional integer base seed (task `i` uses `seed + i`).
#' @param continue_on_error Logical; if `TRUE`, writes partial chunk checkpoints
#'   even if individual tasks error. Default `FALSE`.
#' @param container_sif Optional path to Apptainer `.sif` image.
#' @param modules Optional character vector of HPC modules to load.
#' @param env_vars Optional named list/vector of extra environment variables.
#'
#' @return An S3 object of class `"slurmpilot_job_spec"`.
#' @seealso [slurm_submit()], [estimate_resources()]
#' @export
#' @examples
#' spec <- slurm_job_spec(
#'   fun = function(x) x^2,
#'   args_list = as.list(1:10),
#'   resources = resource_spec(n_tasks = 10, chunk_size = 5),
#'   name = "squares"
#' )
#' print(spec)
slurm_job_spec <- function(
  fun,
  args_list,
  resources = NULL,
  name = NULL,
  packages = character(),
  globals = list(),
  seed = NULL,
  continue_on_error = FALSE,
  container_sif = NULL,
  modules = character(),
  env_vars = list()
) {
  checkmate::assert_function(fun)
  if (!is.list(args_list)) {
    args_list <- as.list(args_list)
  }
  checkmate::assert_list(args_list, min.len = 1L)
  n_tasks <- length(args_list)

  if (is.null(resources)) {
    resources <- resource_spec(n_tasks = n_tasks, chunk_size = 1L)
  }
  checkmate::assert_class(resources, "slurmpilot_resources")
  if (resources$n_tasks != n_tasks) {
    cli::cli_abort(
      "{.arg resources$n_tasks} ({resources$n_tasks}) must match {.code length(args_list)} ({n_tasks})."
    )
  }

  if (!is.null(name)) {
    checkmate::assert_string(name, min.chars = 1L)
    sp_assert_no_control_chars(name, arg = "name")
    if (sp_has_shell_metachars(name)) {
      cli::cli_abort("Unsafe shell metacharacter in job {.arg name}: {.val {name}}.")
    }
  }
  checkmate::assert_character(packages, any.missing = FALSE)
  if (length(packages) > 0L) sp_assert_safe_r_package(packages, arg = "packages")
  checkmate::assert_list(globals)
  if (length(globals) > 0L) checkmate::assert_named(globals, type = "unique")
  if (!is.null(seed)) checkmate::assert_int(seed)
  checkmate::assert_flag(continue_on_error)
  if (!is.null(container_sif)) {
    sp_assert_safe_path(container_sif, arg = "container_sif", allow_tilde = FALSE, allow_relative = FALSE)
  }
  sp_assert_safe_module_name(modules, arg = "modules")
  if (length(env_vars) > 0L) {
    ev_names <- names(env_vars)
    if (is.null(ev_names) || any(!nzchar(ev_names))) {
      cli::cli_abort("All entries in {.arg env_vars} must be named.")
    }
    sp_assert_safe_env_name(ev_names, arg = "env_vars")
    for (i in seq_along(env_vars)) {
      sp_assert_no_control_chars(as.character(env_vars[[i]]), arg = paste0("env_vars$", ev_names[[i]]))
    }
  }

  structure(
    list(
      name = sp_sanitize_name(name, default = "slurmpilot_job"),
      fun = fun,
      args_list = args_list,
      resources = resources,
      packages = packages,
      globals = globals,
      seed = seed,
      continue_on_error = continue_on_error,
      container_sif = container_sif,
      modules = modules,
      env_vars = env_vars
    ),
    class = "slurmpilot_job_spec"
  )
}

#' Submit a Job to a `slurmpilot` Scheduler Backend
#'
#' Submits either a pre-built [slurm_job_spec()] or a `fun` + `args_list`
#' workload to any [SlurmBackend] (such as [MockSlurmBackend] or
#' [SlurmSshBackend]).
#'
#' @param backend A [SlurmBackend] R6 object.
#' @param fun Either a `slurmpilot_job_spec` object OR a worker function
#'   `fun(arg)`.
#' @param args_list List of per-task arguments (required when `fun` is a
#'   function).
#' @param resources Optional `slurmpilot_resources` object.
#' @param name Optional job name.
#' @param packages Character vector of worker packages.
#' @param globals Named list of worker globals.
#' @param seed Optional integer base seed.
#' @param ... Additional backend-specific arguments forwarded to
#'   `backend$submit()` (e.g. `fault_injection` for [MockSlurmBackend]).
#'
#' @return A `slurmpilot_job` handle.
#' @seealso [slurm_status()], [slurm_wait()], [slurm_retry()], [slurm_collect()]
#' @export
slurm_submit <- function(
  backend,
  fun,
  args_list = NULL,
  resources = NULL,
  name = NULL,
  packages = character(),
  globals = list(),
  seed = NULL,
  ...
) {
  checkmate::assert_class(backend, "SlurmBackend")
  job_spec <- if (inherits(fun, "slurmpilot_job_spec")) {
    fun
  } else {
    slurm_job_spec(
      fun = fun,
      args_list = args_list,
      resources = resources,
      name = name,
      packages = packages,
      globals = globals,
      seed = seed
    )
  }
  backend$submit(job_spec, ...)
}

#' Poll Current Status of a Submitted Job
#'
#' @param job A `slurmpilot_job` handle returned by [slurm_submit()].
#' @return A `slurmpilot_status` object with aggregate job state and a per-chunk
#'   telemetry tibble (`$chunks`).
#' @export
slurm_status <- function(job) {
  checkmate::assert_class(job, "slurmpilot_job")
  job$backend$status(job)
}

#' Surgically Retry Failed, OOM, Timed-Out, or Cancelled Chunks
#'
#' Resubmits only unsuccessful array chunks while preserving already-completed
#' chunk checkpoints on disk. Optionally scales `--mem` and/or `--time` via
#' [scale_resources()] before resubmitting.
#'
#' @param job A `slurmpilot_job` handle.
#' @param chunks Optional integer vector of chunk IDs to retry. Defaults to all
#'   chunks currently in `FAILED`, `OUT_OF_MEMORY`, `TIMEOUT`, or `CANCELLED`.
#' @param mem_multiplier Optional numeric multiplier to bump `--mem` on retry
#'   (e.g., `1.5` after an `OUT_OF_MEMORY` failure).
#' @param time_multiplier Optional numeric multiplier to bump `--time` on retry
#'   (e.g., `1.5` after a `TIMEOUT`).
#' @param resources Optional explicit replacement `slurmpilot_resources` object
#'   (takes precedence over multipliers).
#'
#' @return Updated `slurmpilot_job` handle.
#' @export
slurm_retry <- function(
  job,
  chunks = NULL,
  mem_multiplier = NULL,
  time_multiplier = NULL,
  resources = NULL
) {
  checkmate::assert_class(job, "slurmpilot_job")
  if (is.null(resources) && (!is.null(mem_multiplier) || !is.null(time_multiplier))) {
    resources <- scale_resources(
      job$resources,
      mem_multiplier = mem_multiplier %||% 1,
      time_multiplier = time_multiplier %||% 1
    )
  }
  job$backend$retry(job, chunks = chunks, resources = resources)
}

#' Cancel Active Chunks of a Submitted Job
#'
#' @param job A `slurmpilot_job` handle.
#' @param chunks Optional integer vector of chunk IDs to cancel (defaults to all
#'   pending/running chunks).
#' @return Latest `slurmpilot_status` invisibly.
#' @export
slurm_cancel <- function(job, chunks = NULL) {
  checkmate::assert_class(job, "slurmpilot_job")
  job$backend$cancel(job, chunks = chunks)
}

#' Retrieve Stdout and Stderr Logs for a Submitted Job
#'
#' @param job A `slurmpilot_job` handle.
#' @param chunk_id Optional integer chunk ID (default `NULL` retrieves all
#'   chunks).
#' @return Named list of chunk log records (`chunk_id`, `stdout`, `stderr`).
#' @export
slurm_logs <- function(job, chunk_id = NULL) {
  checkmate::assert_class(job, "slurmpilot_job")
  job$backend$logs(job, chunk_id = chunk_id)
}

#' Collect Ordered Task Results from a Completed Job
#'
#' @param job A `slurmpilot_job` handle.
#' @param simplify Logical; if `TRUE`, binds homogeneous data-frame results into
#'   a tibble or unlists homogeneous scalar atomic results. Default `FALSE`.
#' @param allow_partial Logical; if `TRUE`, returns available results even when
#'   some chunks are incomplete. Default `FALSE`.
#' @return Ordered list (or simplified vector/tibble) of task results.
#' @export
slurm_collect <- function(job, simplify = FALSE, allow_partial = FALSE) {
  checkmate::assert_class(job, "slurmpilot_job")
  job$backend$collect(job, simplify = simplify, allow_partial = allow_partial)
}

#' Wait for a Job to Reach a Terminal State
#'
#' @param job A `slurmpilot_job` handle.
#' @param timeout Maximum wait time in seconds. Default `Inf`.
#' @param poll_interval Polling interval in seconds. Default `0.2`.
#' @param progress Logical; print progress updates when chunks complete.
#'   Default `FALSE`.
#' @return A `slurmpilot_status` object.
#' @export
slurm_wait <- function(job, timeout = Inf, poll_interval = 0.2, progress = FALSE) {
  checkmate::assert_class(job, "slurmpilot_job")
  job$backend$wait(job, timeout = timeout, poll_interval = poll_interval, progress = progress)
}

#' End-to-End Micro-Pilot to Cluster Autopilot
#'
#' Executes the complete `slurmpilot` lifecycle in one call:
#' 1. Runs [pilot_run()] on a controlled sample slice to empirically measure
#'    startup overhead, task runtime distribution, and OS peak RSS.
#' 2. Calls [estimate_resources()] to size SLURM array chunking, `--mem`, and
#'    `--time`.
#' 3. Submits the full workload via [slurm_submit()] on `backend`.
#' 4. Optionally waits for completion, performs automatic surgical retries on
#'    failed chunks (auto-scaling `--mem` on OOM and `--time` on TIMEOUT), and
#'    collects ordered results.
#'
#' @inheritParams pilot_run
#' @inheritParams estimate_resources
#' @param backend A [SlurmBackend] object (e.g. [mock_slurm_backend()] or
#'   [slurm_ssh_backend()]).
#' @param name Optional job name.
#' @param wait Logical; wait for completion and collect results. Default `TRUE`.
#' @param auto_retry Non-negative integer maximum automatic surgical retry
#'   rounds when chunks fail. Default `0L`.
#' @param retry_mem_multiplier Memory scale factor applied when automatically
#'   retrying `OUT_OF_MEMORY` chunks. Default `1.5`.
#' @param retry_time_multiplier Walltime scale factor applied when automatically
#'   retrying `TIMEOUT` chunks. Default `1.5`.
#' @param simplify Logical passed to [slurm_collect()]. Default `FALSE`.
#' @param poll_interval Polling interval in seconds passed to [slurm_wait()].
#'   Default `0.15`.
#' @param ... Additional arguments passed to [slurm_submit()].
#'
#' @return An S3 object of class `"slurmpilot_autopilot"` containing `pilot`,
#'   `resources`, `job`, `status`, and `results` (when `wait = TRUE`).
#' @export
#' @examples
#' backend <- mock_slurm_backend(max_workers = 2L)
#' run <- slurm_autopilot(
#'   fun = function(x) x$a + x$b,
#'   args_list = lapply(1:6, function(i) list(a = i, b = 10)),
#'   backend = backend,
#'   n_pilot = 2L,
#'   max_chunk_size = 3L,
#'   simplify = TRUE
#' )
#' run$results
slurm_autopilot <- function(
  fun,
  args_list,
  backend,
  n_pilot = NULL,
  sample_method = c("head", "stratified", "random"),
  target_chunk_minutes = 15,
  max_array_size = 1000L,
  min_chunk_size = 1L,
  max_chunk_size = NULL,
  mem_safety = 1.35,
  time_safety = 1.50,
  cpus_per_task = 1L,
  name = NULL,
  packages = character(),
  globals = list(),
  seed = NULL,
  isolate = TRUE,
  wait = TRUE,
  auto_retry = 0L,
  retry_mem_multiplier = 1.5,
  retry_time_multiplier = 1.5,
  simplify = FALSE,
  poll_interval = 0.15,
  progress = FALSE,
  ...
) {
  checkmate::assert_class(backend, "SlurmBackend")
  checkmate::assert_int(auto_retry, lower = 0L)
  sample_method <- match.arg(sample_method)

  pilot <- pilot_run(
    fun = fun,
    args_list = args_list,
    n_pilot = n_pilot,
    sample_method = sample_method,
    cpus_per_task = cpus_per_task,
    seed = seed,
    packages = packages,
    globals = globals,
    isolate = isolate,
    progress = progress
  )

  resources <- estimate_resources(
    pilot = pilot,
    n_tasks = length(args_list),
    target_chunk_minutes = target_chunk_minutes,
    max_array_size = max_array_size,
    min_chunk_size = min_chunk_size,
    max_chunk_size = max_chunk_size,
    mem_safety = mem_safety,
    time_safety = time_safety,
    cpus_per_task = cpus_per_task
  )

  job <- slurm_submit(
    backend = backend,
    fun = fun,
    args_list = args_list,
    resources = resources,
    name = name %||% "autopilot_job",
    packages = packages,
    globals = globals,
    seed = seed,
    ...
  )

  st <- slurm_status(job)
  results <- NULL

  if (isTRUE(wait)) {
    st <- slurm_wait(job, poll_interval = poll_interval, progress = progress)
    retries_left <- auto_retry

    while (retries_left > 0L && st$state %in% c("PARTIAL_FAILURE", "FAILED") && st$n_retryable > 0L) {
      mem_mult <- if (st$n_oom > 0L) retry_mem_multiplier else 1
      time_mult <- if (st$n_timeout > 0L) retry_time_multiplier else 1
      if (progress) {
        cli::cli_inform(
          "Auto-retrying {st$n_retryable} failed chunk{?s} (mem x{mem_mult}, time x{time_mult})..."
        )
      }
      job <- slurm_retry(job, mem_multiplier = mem_mult, time_multiplier = time_mult)
      st <- slurm_wait(job, poll_interval = poll_interval, progress = progress)
      retries_left <- retries_left - 1L
    }

    if (st$state == "COMPLETED") {
      results <- slurm_collect(job, simplify = simplify)
    }
  }

  structure(
    list(
      pilot = pilot,
      resources = resources,
      job = job,
      status = st,
      results = results
    ),
    class = "slurmpilot_autopilot"
  )
}

#' @export
print.slurmpilot_job_spec <- function(x, ...) {
  cli::cli_h3("slurmpilot Job Specification ({x$name})")
  cli::cli_bullets(c(
    "*" = "Tasks: {length(x$args_list)} across {x$resources$n_chunks} chunks ({x$resources$chunk_size} tasks/chunk)",
    "*" = "Resources: {paste(x$resources$slurm_flags, collapse = ' ')}",
    "*" = "Packages: {if (length(x$packages) > 0L) paste(x$packages, collapse = ', ') else 'none'}"
  ))
  invisible(x)
}

#' @export
print.slurmpilot_job <- function(x, ...) {
  cli::cli_h3("slurmpilot Job Handle")
  cli::cli_bullets(c(
    "*" = "Job: {x$job_name} (id={x$job_id}, backend={x$backend$name})",
    "*" = "Chunks: {x$resources$n_chunks} ({x$resources$n_tasks} tasks, {x$resources$mem_slurm}, {x$resources$time_slurm})",
    "*" = "Workspace: {.path {x$local_dir}}"
  ))
  invisible(x)
}

#' @export
print.slurmpilot_status <- function(x, ...) {
  cli::cli_h3("slurmpilot Job Status: {x$job_name} [{x$state}]")
  rss_str <- if (is.na(x$peak_rss_max_mb)) "n/a" else sprintf("%.1f MB", x$peak_rss_max_mb)
  cli::cli_bullets(c(
    "*" = "Progress: {x$n_completed}/{x$n_chunks} chunks ({sprintf('%.0f%%', 100 * x$progress)}) | running={x$n_running}, pending={x$n_pending}, failed={x$n_failed}, oom={x$n_oom}, timeout={x$n_timeout}, cancelled={x$n_cancelled}",
    "*" = "Peak RSS max: {rss_str} | Cumulative walltime: {sprintf('%.2fs', x$total_wall_sec)}"
  ))
  invisible(x)
}

#' @export
print.slurmpilot_autopilot <- function(x, ...) {
  cli::cli_h3("slurmpilot Autopilot Run")
  cli::cli_bullets(c(
    "*" = "Job: {x$job$job_name} [{x$status$state}] ({x$status$n_completed}/{x$status$n_chunks} chunks)",
    "*" = "Recommended SLURM flags: {paste(x$resources$slurm_flags, collapse = ' ')}",
    "*" = "Results collected: {!is.null(x$results)}"
  ))
  invisible(x)
}
