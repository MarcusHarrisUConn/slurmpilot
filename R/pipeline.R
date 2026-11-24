# Multi-stage dependent HPC Job DAGs (fan-in, diamond DAGs, SLURM --dependency)

#' Define a Stage in a Multi-Stage SLURM Pipeline DAG
#'
#' Declares one executable node of a dependent HPC workflow assembled with
#' [slurm_pipeline()] and executed with [slurm_pipeline_run()]. Upstream stage
#' outputs are passed into downstream stages either via `args_from_upstream`
#' (a function mapping the named list of upstream results to a new `args_list`)
#' or automatically as a single fan-in task `fun(upstream_results)` when both
#' `args_list` and `args_from_upstream` are `NULL`.
#'
#' @param name Unique stage identifier (letters, digits, `_`, `-`).
#' @param fun Worker function `fun(arg)` executed for each task in this stage.
#' @param args_list Optional list (or vector coercible to list) of task inputs
#'   for this stage. Required for root stages (stages with empty `depends_on`).
#' @param args_from_upstream Optional function `function(upstream_results)`
#'   returning an `args_list` built dynamically from collected upstream stage
#'   outputs (named by upstream stage name).
#' @param depends_on Character vector of upstream stage names that must finish
#'   before this stage runs. Default `character()`.
#' @param resources Optional `slurmpilot_resources` object (from
#'   [resource_spec()] or [estimate_resources()]). If `NULL`, a sensible default
#'   spec is constructed automatically at runtime from `length(stage_args)`.
#' @param packages Character vector of worker packages to attach.
#' @param globals Named list of helper objects/functions bound to `fun`.
#' @param seed Optional integer base seed for independent `L'Ecuyer-CMRG`
#'   parallel RNG streams.
#' @param container_sif Optional path to Apptainer `.sif` image.
#' @param container_binds Optional character vector of Apptainer `--bind` mounts.
#' @param modules Optional character vector of HPC modules to load.
#' @param env_vars Optional named list/vector of extra environment variables.
#' @param dependency_type SLURM dependency condition: `"afterok"` (default),
#'   `"afterany"`, or `"afternotok"`.
#' @param simplify_upstream Logical; passed to [slurm_collect()] when collecting
#'   upstream stage results for this stage. Default `TRUE`.
#'
#' @return An S3 object of class `"slurmpilot_stage"`.
#' @seealso [slurm_pipeline()], [slurm_pipeline_run()], [slurm_pipeline_status()],
#'   [slurm_pipeline_collect()]
#' @export
#' @examples
#' s1 <- slurm_stage("simulate", fun = function(x) x^2, args_list = as.list(1:4))
#' s2 <- slurm_stage("summarize", fun = function(up) sum(up$simulate), depends_on = "simulate")
#' print(s1)
slurm_stage <- function(
  name,
  fun,
  args_list = NULL,
  args_from_upstream = NULL,
  depends_on = character(),
  resources = NULL,
  packages = character(),
  globals = list(),
  seed = NULL,
  container_sif = NULL,
  container_binds = character(),
  modules = character(),
  env_vars = list(),
  dependency_type = c("afterok", "afterany", "afternotok"),
  simplify_upstream = TRUE
) {
  sp_assert_safe_id(name, arg = "name")
  checkmate::assert_function(fun)
  if (!is.null(args_list) && !is.list(args_list)) {
    args_list <- as.list(args_list)
  }
  if (!is.null(args_list)) {
    checkmate::assert_list(args_list, min.len = 1L)
  }
  if (!is.null(args_from_upstream)) {
    checkmate::assert_function(args_from_upstream)
  }
  checkmate::assert_character(depends_on, any.missing = FALSE)
  depends_on <- unique(depends_on)
  for (dep in depends_on) {
    sp_assert_safe_id(dep, arg = "depends_on")
  }
  if (length(depends_on) == 0L && is.null(args_list)) {
    cli::cli_abort("Root stage {.val {name}} (no {.arg depends_on}) must supply {.arg args_list}.")
  }
  if (!is.null(resources)) {
    checkmate::assert_class(resources, "slurmpilot_resources")
  }
  checkmate::assert_character(packages, any.missing = FALSE)
  if (length(packages) > 0L) sp_assert_safe_r_package(packages, arg = "packages")
  checkmate::assert_list(globals)
  if (length(globals) > 0L) checkmate::assert_named(globals, type = "unique")
  if (!is.null(seed)) checkmate::assert_int(seed)
  if (!is.null(container_sif)) {
    sp_assert_safe_path(container_sif, arg = "container_sif", allow_tilde = FALSE, allow_relative = FALSE)
  }
  sp_assert_safe_apptainer_bind(container_binds, arg = "container_binds")
  sp_assert_safe_module_name(modules, arg = "modules")
  dependency_type <- match.arg(dependency_type)
  checkmate::assert_flag(simplify_upstream)

  structure(
    list(
      name = name,
      fun = fun,
      args_list = args_list,
      args_from_upstream = args_from_upstream,
      depends_on = depends_on,
      resources = resources,
      packages = packages,
      globals = globals,
      seed = seed,
      container_sif = container_sif,
      container_binds = container_binds,
      modules = modules,
      env_vars = env_vars,
      dependency_type = dependency_type,
      simplify_upstream = simplify_upstream
    ),
    class = "slurmpilot_stage"
  )
}

#' @export
print.slurmpilot_stage <- function(x, ...) {
  deps <- if (length(x$depends_on) > 0L) {
    paste0(x$dependency_type, ":", paste(x$depends_on, collapse = ","))
  } else {
    "none (root)"
  }
  tasks_str <- if (!is.null(x$args_list)) {
    as.character(length(x$args_list))
  } else if (!is.null(x$args_from_upstream)) {
    "dynamic (from upstream)"
  } else {
    "1 (fan-in aggregation)"
  }
  cli::cli_inform(
    "<{.cls slurmpilot_stage}> {.val {x$name}} | tasks={tasks_str} | deps={deps}"
  )
  invisible(x)
}

sp_topo_sort_stages <- function(stage_list) {
  stage_names <- names(stage_list)
  n <- length(stage_names)

  # Build in-degree and outgoing adjacency list
  in_deg <- stats::setNames(integer(n), stage_names)
  outgoing <- stats::setNames(vector("list", n), stage_names)

  for (nm in stage_names) {
    deps <- stage_list[[nm]]$depends_on
    in_deg[[nm]] <- length(deps)
    for (d in deps) {
      outgoing[[d]] <- c(outgoing[[d]], nm)
    }
  }

  # Kahn's topological sort with deterministic level assignment
  ready <- stage_names[in_deg == 0L]
  order_vec <- character(0L)
  levels <- stats::setNames(rep(1L, n), stage_names)

  while (length(ready) > 0L) {
    cur <- ready[[1L]]
    ready <- ready[-1L]
    order_vec <- c(order_vec, cur)
    for (nxt in outgoing[[cur]]) {
      levels[[nxt]] <- max(levels[[nxt]], levels[[cur]] + 1L)
      in_deg[[nxt]] <- in_deg[[nxt]] - 1L
      if (in_deg[[nxt]] == 0L) {
        ready <- c(ready, nxt)
      }
    }
  }

  if (length(order_vec) != n) {
    cyc_nodes <- setdiff(stage_names, order_vec)
    cli::cli_abort(c(
      "Cycle detected in SLURM pipeline DAG.",
      "x" = "Cyclic or mutually dependent stages: {paste(cyc_nodes, collapse = ', ')}."
    ))
  }

  sinks <- stage_names[vapply(outgoing, length, integer(1L)) == 0L]
  roots <- stage_names[vapply(stage_list, function(s) length(s$depends_on) == 0L, logical(1L))]

  list(
    order = order_vec,
    levels = levels[order_vec],
    roots = roots,
    sinks = sinks,
    outgoing = outgoing
  )
}

#' Construct a Validated Multi-Stage SLURM Pipeline DAG
#'
#' Assembles two or more (or single) [slurm_stage()] definitions into a directed
#' acyclic graph (DAG), verifying unique stage names, valid upstream references,
#' and acyclicity via Kahn's topological sort. Supports linear chains, fan-out,
#' fan-in, and diamond DAGs.
#'
#' @param ... One or more `slurmpilot_stage` objects created by [slurm_stage()].
#' @param stages Optional list of `slurmpilot_stage` objects (alternative to
#'   passing stages via `...`).
#' @param name Character pipeline name (sanitized for SLURM job prefixes).
#'   Default `"slurmpilot_pipeline"`.
#'
#' @return An S3 object of class `"slurmpilot_pipeline"` containing `name`,
#'   `stages`, `order` (topological execution order), `levels` (DAG depth per
#'   stage), `roots`, `sinks`, and `edges` (tibble of `from -> to` edges).
#' @seealso [slurm_stage()], [slurm_pipeline_run()], [slurm_pipeline_status()],
#'   [slurm_pipeline_collect()]
#' @export
#' @examples
#' s1 <- slurm_stage("branch_a", fun = function(x) x + 1, args_list = list(1, 2))
#' s2 <- slurm_stage("branch_b", fun = function(x) x * 10, args_list = list(1, 2))
#' s3 <- slurm_stage(
#'   "combine",
#'   fun = function(up) sum(up$branch_a) + sum(up$branch_b),
#'   depends_on = c("branch_a", "branch_b")
#' )
#' pipe <- slurm_pipeline(s1, s2, s3, name = "diamond_demo")
#' print(pipe)
slurm_pipeline <- function(..., stages = NULL, name = "slurmpilot_pipeline") {
  stage_list <- if (!is.null(stages)) stages else list(...)
  checkmate::assert_list(stage_list, min.len = 1L)
  for (i in seq_along(stage_list)) {
    if (!inherits(stage_list[[i]], "slurmpilot_stage")) {
      cli::cli_abort("All pipeline elements must be {.cls slurmpilot_stage} objects (element {i} is {.cls {class(stage_list[[i]])[[1L]]}}).")
    }
  }
  checkmate::assert_string(name, min.chars = 1L)
  sp_assert_no_control_chars(name, arg = "name")
  if (sp_has_shell_metachars(name)) {
    cli::cli_abort("Unsafe shell metacharacter in pipeline {.arg name}: {.val {name}}.")
  }

  stage_names <- vapply(stage_list, function(s) s$name, character(1L))
  if (any(duplicated(stage_names))) {
    dups <- unique(stage_names[duplicated(stage_names)])
    cli::cli_abort("Duplicate stage name(s) in pipeline: {paste(dups, collapse = ', ')}.")
  }
  names(stage_list) <- stage_names

  # Validate upstream references & self-loops
  edge_rows <- list()
  for (nm in stage_names) {
    deps <- stage_list[[nm]]$depends_on
    if (nm %in% deps) {
      cli::cli_abort("Self-dependency detected in stage {.val {nm}}.")
    }
    unknown <- setdiff(deps, stage_names)
    if (length(unknown) > 0L) {
      cli::cli_abort(
        "Stage {.val {nm}} depends on unknown stage(s): {paste(unknown, collapse = ', ')}."
      )
    }
    for (d in deps) {
      edge_rows[[length(edge_rows) + 1L]] <- tibble::tibble(
        from = d,
        to = nm,
        type = stage_list[[nm]]$dependency_type
      )
    }
  }

  edges <- if (length(edge_rows) > 0L) {
    do.call(rbind, edge_rows)
  } else {
    tibble::tibble(from = character(), to = character(), type = character())
  }

  topo <- sp_topo_sort_stages(stage_list)

  structure(
    list(
      name = sp_sanitize_name(name, default = "slurmpilot_pipeline"),
      stages = stage_list,
      order = topo$order,
      levels = topo$levels,
      roots = topo$roots,
      sinks = topo$sinks,
      edges = edges
    ),
    class = "slurmpilot_pipeline"
  )
}

#' @export
print.slurmpilot_pipeline <- function(x, ...) {
  cli::cli_h3("slurmpilot Pipeline DAG: {x$name}")
  cli::cli_bullets(c(
    "*" = "Stages: {length(x$stages)} | Edges: {nrow(x$edges)} | Roots: {paste(x$roots, collapse = ', ')} | Sinks: {paste(x$sinks, collapse = ', ')}",
    "*" = "Topological order: {paste(x$order, collapse = ' -> ')}"
  ))
  invisible(x)
}

sp_dependency_satisfied <- function(dep_type, upstream_states) {
  if (length(upstream_states) == 0L) return(TRUE)
  switch(
    dep_type,
    afterok = all(upstream_states == "COMPLETED"),
    afternotok = any(upstream_states %in% c("FAILED", "PARTIAL_FAILURE", "CANCELLED")),
    afterany = all(upstream_states %in% c("COMPLETED", "FAILED", "PARTIAL_FAILURE", "CANCELLED")),
    FALSE
  )
}

#' Execute a Multi-Stage SLURM Pipeline DAG
#'
#' Runs a validated [slurm_pipeline()] in topological order on any
#' [SlurmBackend].
#' - On [MockSlurmBackend] (or any backend with `wait = TRUE`), each stage runs
#'   after its upstream dependencies satisfy `dependency_type`, collects
#'   upstream results cleanly, and forwards them to downstream stages via
#'   `args_from_upstream` or fan-in aggregation.
#' - On [SlurmSshBackend] with `wait = FALSE`, stages are submitted directly to
#'   SLURM with genuine `#SBATCH --dependency=afterok:<jobid1>:<jobid2>` flags
#'   so the HPC scheduler enforces DAG ordering cluster-side.
#'
#' @param pipeline A `slurmpilot_pipeline` object from [slurm_pipeline()].
#' @param backend A [SlurmBackend] object ([MockSlurmBackend] or
#'   [SlurmSshBackend]).
#' @param wait Logical; wait for each stage to finish and pass results
#'   downstream (`TRUE`, default), or submit the full DAG asynchronously using
#'   SLURM `--dependency` flags (`FALSE`, supported for static-argument stages
#'   on [SlurmSshBackend]).
#' @param poll_interval Polling interval in seconds passed to [slurm_wait()].
#'   Default `0.08`.
#' @param timeout Per-stage timeout in seconds passed to [slurm_wait()].
#'   Default `Inf`.
#' @param auto_retry Non-negative integer adaptive retry rounds per stage when
#'   `wait = TRUE`. Default `0L`.
#' @param stop_on_failure Logical; when `TRUE` (default), skips downstream
#'   `afterok` stages if an upstream stage fails instead of aborting.
#' @param progress Logical; emit stage progress messages via `cli`.
#'   Default `FALSE`.
#'
#' @return An S3 object of class `"slurmpilot_pipeline_run"` containing
#'   `pipeline`, `backend`, `jobs`, `stage_states`, `results`,
#'   `dependencies_submitted`, `started_at`, and `finished_at`.
#' @seealso [slurm_pipeline()], [slurm_pipeline_status()],
#'   [slurm_pipeline_collect()]
#' @export
#' @examples
#' s1 <- slurm_stage("sim", fun = function(x) x^2, args_list = as.list(1:4))
#' s2 <- slurm_stage("agg", fun = function(up) sum(up$sim), depends_on = "sim")
#' pipe <- slurm_pipeline(s1, s2, name = "two_stage")
#' be <- mock_slurm_backend(max_workers = 2L)
#' run <- slurm_pipeline_run(pipe, be, poll_interval = 0.05)
#' slurm_pipeline_collect(run)
#' unlink(be$root_dir, recursive = TRUE)
slurm_pipeline_run <- function(
  pipeline,
  backend,
  wait = TRUE,
  poll_interval = 0.08,
  timeout = Inf,
  auto_retry = 0L,
  stop_on_failure = TRUE,
  progress = FALSE
) {
  checkmate::assert_class(pipeline, "slurmpilot_pipeline")
  checkmate::assert_class(backend, "SlurmBackend")
  checkmate::assert_flag(wait)
  checkmate::assert_number(poll_interval, lower = 0.01, finite = TRUE)
  checkmate::assert_number(timeout, lower = 0)
  checkmate::assert_int(auto_retry, lower = 0L)
  checkmate::assert_flag(stop_on_failure)
  checkmate::assert_flag(progress)

  started_at <- sp_timestamp()
  jobs <- list()
  stage_states <- stats::setNames(rep("PENDING", length(pipeline$order)), pipeline$order)
  stage_results <- list()
  deps_submitted <- stats::setNames(rep(NA_character_, length(pipeline$order)), pipeline$order)

  for (st_name in pipeline$order) {
    stage <- pipeline$stages[[st_name]]
    deps <- stage$depends_on

    if (isTRUE(wait) && length(deps) > 0L) {
      up_states <- unname(stage_states[deps])
      if (!sp_dependency_satisfied(stage$dependency_type, up_states)) {
        stage_states[[st_name]] <- "SKIPPED"
        if (isTRUE(progress)) {
          cli::cli_inform("Stage {.val {st_name}}: skipped (upstream {stage$dependency_type} condition unmet).")
        }
        next
      }
    }

    # Build SLURM --dependency string from upstream scheduler IDs (SSH/SLURM DAGs)
    dep_str <- NULL
    if (length(deps) > 0L) {
      up_ids <- unlist(lapply(deps, function(d) {
        j_up <- jobs[[d]]
        if (!is.null(j_up) && length(j_up$scheduler_ids) > 0L) {
          utils::tail(j_up$scheduler_ids, 1L)
        } else {
          character(0L)
        }
      }), use.names = FALSE)
      # Only attach numeric/DRY_RUN SLURM job IDs (not mock_* IDs)
      valid_slurm_ids <- up_ids[grepl("^([0-9]{1,20}|DRY_RUN(_R[0-9]+)?)$", up_ids)]
      if (length(valid_slurm_ids) > 0L) {
        dep_str <- paste0(stage$dependency_type, ":", paste(unique(valid_slurm_ids), collapse = ":"))
        deps_submitted[[st_name]] <- dep_str
      }
    }

    # Assemble stage args_list and globals from upstream outputs when wait = TRUE
    stage_globals <- stage$globals
    if (length(deps) > 0L && isTRUE(wait)) {
      up_payload <- stats::setNames(
        lapply(deps, function(d) stage_results[[d]]),
        deps
      )
      if (!is.null(stage$args_from_upstream)) {
        stage_args <- stage$args_from_upstream(up_payload)
        if (!is.list(stage_args)) stage_args <- as.list(stage_args)
      } else if (!is.null(stage$args_list)) {
        stage_args <- stage$args_list
        if (!(".upstream" %in% names(stage_globals))) {
          stage_globals$.upstream <- up_payload
        }
      } else {
        stage_args <- list(up_payload)
      }
    } else {
      if (is.null(stage$args_list)) {
        if (!is.null(stage$args_from_upstream) || length(deps) > 0L) {
          cli::cli_abort(c(
            "Stage {.val {st_name}} requires dynamic upstream results, which cannot be resolved when {.code wait = FALSE}.",
            "i" = "Provide static {.arg args_list} for queued cluster-side DAG submission, or run with {.code wait = TRUE}."
          ))
        }
      }
      stage_args <- stage$args_list
    }

    # Reconcile resource spec with resolved n_tasks
    n_t <- length(stage_args)
    stage_res <- stage$resources
    if (is.null(stage_res)) {
      stage_res <- resource_spec(n_tasks = n_t, chunk_size = max(1L, min(n_t, 4L)))
    } else if (stage_res$n_tasks != n_t) {
      stage_res <- resource_spec(
        n_tasks = n_t,
        chunk_size = min(stage_res$chunk_size, n_t),
        mem_mb = stage_res$mem_mb,
        time_minutes = stage_res$time_sec / 60,
        cpus_per_task = stage_res$cpus_per_task,
        partition = stage_res$partition,
        account = stage_res$account,
        qos = stage_res$qos,
        max_concurrent = stage_res$max_concurrent
      )
    }

    job_spec <- slurm_job_spec(
      fun = stage$fun,
      args_list = stage_args,
      resources = stage_res,
      name = paste0(pipeline$name, "_", st_name),
      packages = stage$packages,
      globals = stage_globals,
      seed = stage$seed,
      container_sif = stage$container_sif,
      container_binds = stage$container_binds,
      modules = stage$modules,
      env_vars = stage$env_vars,
      dependency = dep_str
    )

    if (isTRUE(progress)) {
      cli::cli_inform("Submitting pipeline stage {.val {st_name}} ({n_t} task{?s})...")
    }

    job <- slurm_submit(backend, job_spec)
    jobs[[st_name]] <- job

    if (isTRUE(wait)) {
      st <- slurm_wait(job, timeout = timeout, poll_interval = poll_interval, progress = progress)
      retries_left <- auto_retry
      while (retries_left > 0L && st$state %in% c("PARTIAL_FAILURE", "FAILED") && st$n_retryable > 0L) {
        job <- slurm_retry(job, adaptive = TRUE)
        jobs[[st_name]] <- job
        st <- slurm_wait(job, timeout = timeout, poll_interval = poll_interval, progress = progress)
        retries_left <- retries_left - 1L
      }
      stage_states[[st_name]] <- st$state
      if (identical(st$state, "COMPLETED")) {
        stage_results[[st_name]] <- slurm_collect(job, simplify = stage$simplify_upstream)
      } else if (!isTRUE(stop_on_failure)) {
        stage_results[[st_name]] <- tryCatch(
          slurm_collect(job, simplify = FALSE, allow_partial = TRUE),
          error = function(e) NULL
        )
      }
    } else {
      stage_states[[st_name]] <- slurm_status(job)$state
    }
  }

  structure(
    list(
      pipeline = pipeline,
      backend = backend,
      jobs = jobs,
      stage_states = stage_states,
      results = stage_results,
      dependencies_submitted = deps_submitted,
      started_at = started_at,
      finished_at = sp_timestamp()
    ),
    class = "slurmpilot_pipeline_run"
  )
}

#' Inspect Status Across All Stages of a SLURM Pipeline Run
#'
#' Refreshes live scheduler telemetry for every submitted stage in a
#' `slurmpilot_pipeline_run` and returns a tidy per-stage and aggregate status
#' summary.
#'
#' @param run A `slurmpilot_pipeline_run` object returned by
#'   [slurm_pipeline_run()].
#'
#' @return An S3 object of class `"slurmpilot_pipeline_status"` with
#'   `pipeline_name`, `state`, stage counts, `progress`, and `stages` tibble.
#' @seealso [slurm_pipeline_run()], [slurm_pipeline_collect()]
#' @export
#' @examples
#' s1 <- slurm_stage("step1", fun = function(x) x + 1, args_list = list(1, 2))
#' pipe <- slurm_pipeline(s1, name = "status_demo")
#' be <- mock_slurm_backend(max_workers = 1L)
#' run <- slurm_pipeline_run(pipe, be, poll_interval = 0.05)
#' slurm_pipeline_status(run)
#' unlink(be$root_dir, recursive = TRUE)
slurm_pipeline_status <- function(run) {
  checkmate::assert_class(run, "slurmpilot_pipeline_run")
  order_vec <- run$pipeline$order

  rows <- lapply(order_vec, function(nm) {
    j <- run$jobs[[nm]]
    if (!is.null(j)) {
      st <- slurm_status(j)
      tibble::tibble(
        stage = nm,
        level = as.integer(run$pipeline$levels[[nm]]),
        state = st$state,
        n_chunks = st$n_chunks,
        n_completed = st$n_completed,
        progress = st$progress,
        dependency = as.character(run$dependencies_submitted[[nm]]),
        job_id = j$job_id
      )
    } else {
      st_str <- run$stage_states[[nm]] %||% "PENDING"
      tibble::tibble(
        stage = nm,
        level = as.integer(run$pipeline$levels[[nm]]),
        state = st_str,
        n_chunks = 0L,
        n_completed = 0L,
        progress = 0,
        dependency = as.character(run$dependencies_submitted[[nm]]),
        job_id = NA_character_
      )
    }
  })
  stages_tbl <- do.call(rbind, rows)

  states <- stages_tbl$state
  agg_state <- if (any(states == "RUNNING")) {
    "RUNNING"
  } else if (any(states == "PENDING")) {
    "PENDING"
  } else if (all(states == "COMPLETED")) {
    "COMPLETED"
  } else if (any(states == "COMPLETED") && any(states %in% c("FAILED", "PARTIAL_FAILURE", "SKIPPED", "CANCELLED"))) {
    "PARTIAL_FAILURE"
  } else {
    "FAILED"
  }

  structure(
    list(
      pipeline_name = run$pipeline$name,
      state = agg_state,
      n_stages = nrow(stages_tbl),
      n_completed = sum(states == "COMPLETED"),
      n_running = sum(states == "RUNNING"),
      n_pending = sum(states == "PENDING"),
      n_failed = sum(states %in% c("FAILED", "PARTIAL_FAILURE")),
      n_skipped = sum(states == "SKIPPED"),
      progress = mean(states == "COMPLETED"),
      stages = stages_tbl
    ),
    class = "slurmpilot_pipeline_status"
  )
}

#' Collect Results from a Completed SLURM Pipeline Run
#'
#' Retrieves collected outputs from a named stage or automatically from the
#' terminal sink stage(s) of a [slurm_pipeline_run()].
#'
#' @param run A `slurmpilot_pipeline_run` object.
#' @param stage Optional character stage name to collect. When `NULL` (default),
#'   collects the single sink stage directly (or returns a named list if the DAG
#'   has multiple sink stages).
#' @param simplify Logical; simplify results when fetching freshly from a stage
#'   job. Default `FALSE`.
#' @param allow_partial Logical; allow collecting incomplete stage results.
#'   Default `FALSE`.
#'
#' @return Collected results for the requested stage (or named list across
#'   multiple sink stages).
#' @seealso [slurm_pipeline_run()], [slurm_pipeline_status()]
#' @export
#' @examples
#' s1 <- slurm_stage("a", fun = function(x) x * 2, args_list = as.list(1:3))
#' s2 <- slurm_stage("b", fun = function(up) sum(up$a), depends_on = "a")
#' pipe <- slurm_pipeline(s1, s2, name = "collect_demo")
#' be <- mock_slurm_backend(max_workers = 1L)
#' run <- slurm_pipeline_run(pipe, be, poll_interval = 0.05)
#' slurm_pipeline_collect(run, simplify = TRUE)
#' unlink(be$root_dir, recursive = TRUE)
slurm_pipeline_collect <- function(run, stage = NULL, simplify = FALSE, allow_partial = FALSE) {
  checkmate::assert_class(run, "slurmpilot_pipeline_run")
  valid_stages <- names(run$pipeline$stages)

  collect_one <- function(nm) {
    if (!(nm %in% valid_stages)) {
      cli::cli_abort("Unknown pipeline stage {.val {nm}}. Available stages: {paste(valid_stages, collapse = ', ')}.")
    }
    j <- run$jobs[[nm]]
    if (is.null(j)) {
      cli::cli_abort("Stage {.val {nm}} was never submitted (state = {.val {run$stage_states[[nm]]}}).")
    }
    slurm_collect(j, simplify = simplify, allow_partial = allow_partial)
  }

  if (!is.null(stage)) {
    checkmate::assert_string(stage, min.chars = 1L)
    return(collect_one(stage))
  }

  sinks <- run$pipeline$sinks
  if (length(sinks) == 1L) {
    return(collect_one(sinks[[1L]]))
  }
  stats::setNames(lapply(sinks, collect_one), sinks)
}

#' @export
print.slurmpilot_pipeline_run <- function(x, ...) {
  st <- slurm_pipeline_status(x)
  print(st)
  invisible(x)
}

#' @export
print.slurmpilot_pipeline_status <- function(x, ...) {
  cli::cli_h3("slurmpilot Pipeline Status: {x$pipeline_name} [{x$state}]")
  cli::cli_bullets(c(
    "*" = "Stages completed: {x$n_completed}/{x$n_stages} (running={x$n_running}, pending={x$n_pending}, failed={x$n_failed}, skipped={x$n_skipped})"
  ))
  invisible(x)
}
