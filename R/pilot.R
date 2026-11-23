# Micro-pilot empirical profiler for slurmpilot

sp_pilot_child_runner <- function(payload_path) {
  payload <- readRDS(payload_path)
  cpus <- as.character(payload$cpus_per_task)
  Sys.setenv(
    OMP_NUM_THREADS = cpus,
    OPENBLAS_NUM_THREADS = cpus,
    MKL_NUM_THREADS = cpus,
    VECLIB_MAXIMUM_THREADS = cpus
  )

  for (pkg in payload$packages) {
    suppressPackageStartupMessages(
      library(pkg, character.only = TRUE)
    )
  }

  fn <- payload$fun
  if (length(payload$globals) > 0L) {
    parent_env <- environment(fn)
    if (is.null(parent_env)) {
      parent_env <- globalenv()
    }
    eval_env <- list2env(payload$globals, parent = parent_env)
    environment(fn) <- eval_env
  }

  if (!is.null(payload$task_seed)) {
    RNGkind("L'Ecuyer-CMRG")
    set.seed(as.integer(payload$task_seed))
    s <- get(".Random.seed", envir = globalenv(), inherits = FALSE)
    task_idx <- as.integer(payload$task_index %||% 1L)
    for (step in seq_len(max(1L, task_idx))) {
      s <- parallel::nextRNGStream(s)
    }
    assign(".Random.seed", s, envir = globalenv())
  }

  self_rss_mb <- function() {
    tryCatch(
      as.numeric(ps::ps_memory_info(ps::ps_handle())[["rss"]]) / (1024^2),
      error = function(e) NA_real_
    )
  }

  baseline_rss_mb <- self_rss_mb()
  t_start_wall <- as.numeric(Sys.time())
  pt0 <- proc.time()

  status <- "OK"
  err_msg <- NA_character_
  result <- NULL

  tryCatch(
    {
      result <- fn(payload$arg)
    },
    error = function(e) {
      status <<- "FAILED"
      err_msg <<- conditionMessage(e)
    }
  )

  pt1 <- proc.time()
  t_end_wall <- as.numeric(Sys.time())
  post_rss_mb <- self_rss_mb()

  list(
    status = status,
    error = err_msg,
    t_start_wall = t_start_wall,
    t_end_wall = t_end_wall,
    exec_sec = max(0, as.numeric((pt1 - pt0)[["elapsed"]])),
    cpu_user_sec = max(0, as.numeric((pt1 - pt0)[["user.self"]] + (pt1 - pt0)[["user.child"]])),
    cpu_sys_sec = max(0, as.numeric((pt1 - pt0)[["sys.self"]] + (pt1 - pt0)[["sys.child"]])),
    baseline_rss_mb = baseline_rss_mb,
    post_rss_mb = post_rss_mb,
    result_size_bytes = as.numeric(utils::object.size(result))
  )
}

sp_select_pilot_indices <- function(n_total, n_pilot, sample_method, seed = NULL) {
  if (n_pilot >= n_total) {
    return(seq_len(n_total))
  }
  switch(
    sample_method,
    head = seq_len(n_pilot),
    stratified = {
      idx <- unique(as.integer(round(seq(1, n_total, length.out = n_pilot))))
      if (length(idx) < n_pilot) {
        extras <- setdiff(seq_len(n_total), idx)
        idx <- sort(c(idx, extras[seq_len(n_pilot - length(idx))]))
      }
      idx
    },
    random = {
      if (!is.null(seed)) {
        old_seed <- if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
          get(".Random.seed", envir = globalenv(), inherits = FALSE)
        } else {
          NULL
        }
        on.exit({
          if (is.null(old_seed)) {
            if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
              rm(".Random.seed", envir = globalenv())
            }
          } else {
            assign(".Random.seed", old_seed, envir = globalenv())
          }
        }, add = TRUE)
        set.seed(seed)
      }
      sort(sample.int(n_total, n_pilot))
    }
  )
}

sp_summarize_pilot_trials <- function(trials) {
  ok <- trials[trials$status == "OK", , drop = FALSE]
  n_total <- nrow(trials)
  n_ok <- nrow(ok)
  n_failed <- n_total - n_ok

  if (n_ok == 0L) {
    n_timeout <- sum(trials$status == "TIMEOUT", na.rm = TRUE)
    n_oom <- sum(grepl("memory|alloc|oom|killed|137", trials$error, ignore.case = TRUE), na.rm = TRUE)
    return(list(
      n_trials = n_total,
      n_ok = 0L,
      n_failed = n_failed,
      n_timeout = as.integer(n_timeout),
      n_oom_suspect = as.integer(n_oom),
      failure_rate = if (n_total > 0L) 1 else NA_real_,
      exec_min_sec = NA_real_,
      exec_q50_sec = NA_real_,
      exec_q75_sec = NA_real_,
      exec_q90_sec = NA_real_,
      exec_q95_sec = NA_real_,
      exec_max_sec = NA_real_,
      exec_mean_sec = NA_real_,
      exec_sd_sec = NA_real_,
      exec_cv = NA_real_,
      exec_log_mean = NA_real_,
      exec_log_sd = NA_real_,
      skewness_ratio = NA_real_,
      is_heavy_tailed = FALSE,
      sub_millisecond = FALSE,
      startup_median_sec = NA_real_,
      wall_median_sec = NA_real_,
      baseline_rss_median_mb = NA_real_,
      peak_rss_max_mb = NA_real_,
      peak_rss_q95_mb = NA_real_,
      net_rss_max_mb = NA_real_,
      result_size_max_mb = NA_real_
    ))
  }

  exec <- ok$exec_sec
  exec_pos <- pmax(exec, 1e-5)
  exec_mean <- mean(exec, na.rm = TRUE)
  exec_sd <- if (n_ok >= 2L) stats::sd(exec, na.rm = TRUE) else NA_real_
  exec_cv <- if (!is.na(exec_sd) && exec_mean > 0) exec_sd / exec_mean else NA_real_

  log_exec <- log(exec_pos)
  exec_log_mean <- mean(log_exec, na.rm = TRUE)
  exec_log_sd <- if (n_ok >= 2L) stats::sd(log_exec, na.rm = TRUE) else NA_real_

  q_exec <- stats::quantile(exec, probs = c(0.50, 0.75, 0.90, 0.95), names = FALSE, na.rm = TRUE)
  peak_q95 <- stats::quantile(ok$peak_rss_mb, probs = 0.95, names = FALSE, na.rm = TRUE)
  skew_ratio <- max(exec, na.rm = TRUE) / max(q_exec[[1L]], 1e-5)
  is_heavy <- isTRUE(skew_ratio >= 2.5) || (!is.na(exec_log_sd) && exec_log_sd >= 0.75)
  is_sub_ms <- isTRUE(q_exec[[1L]] < 1e-3)

  n_timeout <- sum(trials$status == "TIMEOUT", na.rm = TRUE)
  n_oom <- sum(grepl("memory|alloc|oom|killed|137", trials$error, ignore.case = TRUE), na.rm = TRUE)

  list(
    n_trials = n_total,
    n_ok = n_ok,
    n_failed = n_failed,
    n_timeout = as.integer(n_timeout),
    n_oom_suspect = as.integer(n_oom),
    failure_rate = n_failed / n_total,
    exec_min_sec = min(exec, na.rm = TRUE),
    exec_q50_sec = q_exec[[1L]],
    exec_q75_sec = q_exec[[2L]],
    exec_q90_sec = q_exec[[3L]],
    exec_q95_sec = q_exec[[4L]],
    exec_max_sec = max(exec, na.rm = TRUE),
    exec_mean_sec = exec_mean,
    exec_sd_sec = exec_sd,
    exec_cv = exec_cv,
    exec_log_mean = exec_log_mean,
    exec_log_sd = exec_log_sd,
    skewness_ratio = skew_ratio,
    is_heavy_tailed = is_heavy,
    sub_millisecond = is_sub_ms,
    startup_median_sec = stats::median(ok$startup_sec, na.rm = TRUE),
    wall_median_sec = stats::median(ok$wall_sec, na.rm = TRUE),
    baseline_rss_median_mb = stats::median(ok$baseline_rss_mb, na.rm = TRUE),
    peak_rss_max_mb = max(ok$peak_rss_mb, na.rm = TRUE),
    peak_rss_q95_mb = peak_q95,
    net_rss_max_mb = max(ok$net_rss_mb, na.rm = TRUE),
    result_size_max_mb = max(ok$result_size_bytes, na.rm = TRUE) / (1024^2)
  )
}

#' Run an Empirical Micro-Pilot to Profile Runtime and Peak RSS Memory
#'
#' Executes a controlled sample slice of a workload (`fun` applied to selected
#' elements of `args_list`) in isolated background child R processes while
#' polling OS-level Resident Set Size (RSS) via `ps`. Separating cold worker
#' startup overhead from marginal per-task execution time and measuring true
#' process-tree RSS (including native C++/Stan/BLAS allocations) feeds directly
#' into [estimate_resources()].
#'
#' @param fun A function accepting a single element of `args_list` (`fun(arg)`).
#' @param args_list Non-empty list (or vector coercible to list) of per-task
#'   arguments.
#' @param n_pilot Optional positive integer number of sample replications to
#'   profile. Defaults to `min(length(args_list), 5L)`.
#' @param sample_method Strategy for selecting pilot task indices from
#'   `args_list`: `"head"` (first `n_pilot`), `"stratified"` (evenly spaced
#'   across the workload), or `"random"`.
#' @param cpus_per_task Integer number of CPU threads exposed to each pilot
#'   trial (`OMP_NUM_THREADS` / `OPENBLAS_NUM_THREADS`). Default `1L`.
#' @param sample_interval Numeric polling interval in seconds for OS RSS
#'   sampling of child processes. Default `0.03`.
#' @param timeout_sec Numeric per-trial timeout in seconds. Trials exceeding
#'   this limit are terminated and recorded as `"TIMEOUT"`. Default `300`.
#' @param seed Optional integer base seed for reproducible sampling and child
#'   trial execution.
#' @param packages Character vector of package names to attach inside each
#'   isolated worker before executing `fun`.
#' @param globals Named list of helper objects or functions made available in
#'   `fun`'s evaluation environment.
#' @param isolate Logical; if `TRUE` (default), runs each trial in a fresh
#'   background R process via [callr::r_bg()] to measure true startup cost and
#'   isolated OS RSS. Set `FALSE` only for fast in-process profiling.
#' @param progress Logical; if `TRUE`, emits concise progress messages via
#'   `cli`. Default `FALSE`.
#'
#' @return An S3 object of class `"slurmpilot_pilot"` with elements:
#'   - `trials`: a [tibble::tibble()] with one row per pilot trial containing
#'     `trial_id`, `task_index`, `status`, `wall_sec`, `startup_sec`,
#'     `exec_sec`, `baseline_rss_mb`, `peak_rss_mb`, `net_rss_mb`,
#'     `cpu_user_sec`, `cpu_sys_sec`, `n_samples`, `result_size_bytes`, and
#'     `error`.
#'   - `summary`: named list of empirical quantiles and memory statistics.
#'   - `meta`: provenance metadata (`n_pilot`, `n_total_hint`, `cpus_per_task`,
#'     `packages`, `sample_method`, `isolate`, `timestamp`, `r_version`,
#'     `platform`, `seed`).
#'
#' @seealso [estimate_resources()], [slurm_autopilot()]
#' @export
#' @examples
#' args <- lapply(1:20, function(i) list(n = 200, seed = i))
#' pilot <- pilot_run(
#'   fun = function(x) {
#'     set.seed(x$seed)
#'     mean(rnorm(x$n))
#'   },
#'   args_list = args,
#'   n_pilot = 2L
#' )
#' print(pilot)
pilot_run <- function(
  fun,
  args_list,
  n_pilot = NULL,
  sample_method = c("head", "stratified", "random"),
  cpus_per_task = 1L,
  sample_interval = 0.03,
  timeout_sec = 300,
  seed = NULL,
  packages = character(),
  globals = list(),
  isolate = TRUE,
  progress = FALSE
) {
  checkmate::assert_function(fun)
  if (!is.list(args_list)) {
    args_list <- as.list(args_list)
  }
  checkmate::assert_list(args_list, min.len = 1L)
  n_total <- length(args_list)
  if (is.null(n_pilot)) {
    n_pilot <- min(n_total, 5L)
  }
  checkmate::assert_int(n_pilot, lower = 1L, upper = n_total)
  sample_method <- match.arg(sample_method)
  checkmate::assert_int(cpus_per_task, lower = 1L)
  checkmate::assert_number(sample_interval, lower = 0.005, finite = TRUE)
  checkmate::assert_number(timeout_sec, lower = 0.1, finite = TRUE)
  if (!is.null(seed)) {
    checkmate::assert_int(seed)
  }
  checkmate::assert_character(packages, any.missing = FALSE)
  checkmate::assert_list(globals)
  if (length(globals) > 0L) {
    checkmate::assert_named(globals, type = "unique")
  }
  checkmate::assert_flag(isolate)
  checkmate::assert_flag(progress)

  selected_idx <- sp_select_pilot_indices(n_total, n_pilot, sample_method, seed = seed)

  tmp_dir <- tempfile("slurmpilot_pilot_")
  dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
  live_procs <- list()
  on.exit({
    for (lp in live_procs) {
      if (!is.null(lp)) sp_kill_and_reap(lp)
    }
    unlink(tmp_dir, recursive = TRUE, force = TRUE)
  }, add = TRUE)

  rows <- vector("list", length(selected_idx))

  for (k in seq_along(selected_idx)) {
    task_idx <- selected_idx[[k]]
    task_seed <- if (!is.null(seed)) as.integer(seed + task_idx) else NULL

    if (progress) {
      cli::cli_inform("Running micro-pilot trial {k}/{length(selected_idx)} (task #{task_idx})...")
    }

    if (isTRUE(isolate)) {
      payload_path <- file.path(tmp_dir, sprintf("payload_%03d.rds", k))
      saveRDS(
        list(
          fun = fun,
          arg = args_list[[task_idx]],
          packages = packages,
          globals = globals,
          task_seed = seed,
          task_index = task_idx,
          cpus_per_task = cpus_per_task
        ),
        file = payload_path
      )

      t_spawn_wall <- as.numeric(Sys.time())
      t_spawn_mono <- proc.time()[["elapsed"]]
      proc <- callr::r_bg(
        func = sp_pilot_child_runner,
        args = list(payload_path = payload_path),
        supervise = FALSE
      )
      live_procs[[k]] <- proc

      rss_samples <- numeric(0L)
      timed_out <- FALSE

      while (proc$is_alive()) {
        rss <- sp_process_tree_rss_mb(proc$get_pid())
        if (!is.na(rss)) {
          rss_samples <- c(rss_samples, rss)
        }
        elapsed_now <- proc.time()[["elapsed"]] - t_spawn_mono
        if (elapsed_now > timeout_sec) {
          timed_out <- TRUE
          sp_kill_and_reap(proc)
          break
        }
        Sys.sleep(sample_interval)
      }
      if (!timed_out) {
        try(proc$wait(timeout = 500L), silent = TRUE)
      }
      live_procs[[k]] <- NULL

      wall_sec <- max(0, proc.time()[["elapsed"]] - t_spawn_mono)

      if (timed_out) {
        peak_rss <- if (length(rss_samples) > 0L) max(rss_samples, na.rm = TRUE) else NA_real_
        rows[[k]] <- tibble::tibble(
          trial_id = as.integer(k),
          task_index = as.integer(task_idx),
          status = "TIMEOUT",
          wall_sec = wall_sec,
          startup_sec = NA_real_,
          exec_sec = NA_real_,
          baseline_rss_mb = if (length(rss_samples) > 0L) rss_samples[[1L]] else NA_real_,
          peak_rss_mb = peak_rss,
          net_rss_mb = NA_real_,
          cpu_user_sec = NA_real_,
          cpu_sys_sec = NA_real_,
          n_samples = as.integer(length(rss_samples)),
          result_size_bytes = NA_real_,
          error = sprintf("Pilot trial exceeded timeout of %.1fs", timeout_sec)
        )
      } else {
        child_res <- tryCatch(
          proc$get_result(),
          error = function(e) {
            list(
              status = "FAILED",
              error = conditionMessage(e),
              t_start_wall = t_spawn_wall,
              t_end_wall = as.numeric(Sys.time()),
              exec_sec = NA_real_,
              cpu_user_sec = NA_real_,
              cpu_sys_sec = NA_real_,
              baseline_rss_mb = NA_real_,
              post_rss_mb = NA_real_,
              result_size_bytes = NA_real_
            )
          }
        )

        all_rss <- c(rss_samples, child_res$baseline_rss_mb, child_res$post_rss_mb)
        all_rss <- all_rss[!is.na(all_rss)]
        peak_rss <- if (length(all_rss) > 0L) max(all_rss) else NA_real_
        base_rss <- child_res$baseline_rss_mb
        if (is.na(base_rss) && length(rss_samples) > 0L) {
          base_rss <- rss_samples[[1L]]
        }
        net_rss <- if (!is.na(peak_rss) && !is.na(base_rss)) max(0, peak_rss - base_rss) else NA_real_
        startup_sec <- max(0, child_res$t_start_wall - t_spawn_wall)
        if (!is.na(child_res$exec_sec) && startup_sec > wall_sec) {
          startup_sec <- max(0, wall_sec - child_res$exec_sec)
        }

        rows[[k]] <- tibble::tibble(
          trial_id = as.integer(k),
          task_index = as.integer(task_idx),
          status = as.character(child_res$status),
          wall_sec = wall_sec,
          startup_sec = startup_sec,
          exec_sec = child_res$exec_sec,
          baseline_rss_mb = base_rss,
          peak_rss_mb = peak_rss,
          net_rss_mb = net_rss,
          cpu_user_sec = child_res$cpu_user_sec,
          cpu_sys_sec = child_res$cpu_sys_sec,
          n_samples = as.integer(length(rss_samples)),
          result_size_bytes = child_res$result_size_bytes,
          error = as.character(child_res$error)
        )
      }
    } else {
      # Fast in-process profiling fallback
      for (pkg in packages) {
        suppressPackageStartupMessages(library(pkg, character.only = TRUE))
      }
      fn_local <- fun
      if (length(globals) > 0L) {
        parent_env <- environment(fn_local) %||% globalenv()
        environment(fn_local) <- list2env(globals, parent = parent_env)
      }
      if (!is.null(seed)) {
        old_kind_in <- RNGkind()
        has_seed_in <- exists(".Random.seed", envir = globalenv(), inherits = FALSE)
        old_seed_in <- if (has_seed_in) get(".Random.seed", envir = globalenv(), inherits = FALSE) else NULL
        stream_s <- slurmpilot_rng_stream(seed, chunk_id = task_idx, task_pos = 1L)
        RNGkind("L'Ecuyer-CMRG")
        assign(".Random.seed", stream_s, envir = globalenv())
      }
      base_rss <- sp_process_tree_rss_mb(Sys.getpid())
      pt0 <- proc.time()
      status <- "OK"
      err_msg <- NA_character_
      res_val <- NULL
      tryCatch(
        {
          res_val <- fn_local(args_list[[task_idx]])
        },
        error = function(e) {
          status <<- "FAILED"
          err_msg <<- conditionMessage(e)
        }
      )
      if (!is.null(seed)) {
        suppressWarnings(RNGkind(kind = old_kind_in[[1L]], normal.kind = old_kind_in[[2L]], sample.kind = old_kind_in[[3L]]))
        if (has_seed_in) {
          assign(".Random.seed", old_seed_in, envir = globalenv())
        } else if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
          rm(".Random.seed", envir = globalenv())
        }
      }
      pt1 <- proc.time()
      post_rss <- sp_process_tree_rss_mb(Sys.getpid())
      exec_sec <- max(0, as.numeric((pt1 - pt0)[["elapsed"]]))
      peak_rss <- max(c(base_rss, post_rss), na.rm = TRUE)
      if (!is.finite(peak_rss)) peak_rss <- NA_real_
      net_rss <- if (!is.na(peak_rss) && !is.na(base_rss)) max(0, peak_rss - base_rss) else NA_real_

      rows[[k]] <- tibble::tibble(
        trial_id = as.integer(k),
        task_index = as.integer(task_idx),
        status = status,
        wall_sec = exec_sec,
        startup_sec = 0,
        exec_sec = exec_sec,
        baseline_rss_mb = base_rss,
        peak_rss_mb = peak_rss,
        net_rss_mb = net_rss,
        cpu_user_sec = max(0, as.numeric((pt1 - pt0)[["user.self"]])),
        cpu_sys_sec = max(0, as.numeric((pt1 - pt0)[["sys.self"]])),
        n_samples = 1L,
        result_size_bytes = as.numeric(utils::object.size(res_val)),
        error = err_msg
      )
    }
  }

  trials <- do.call(rbind, rows)
  summary_stats <- sp_summarize_pilot_trials(trials)

  if (summary_stats$n_ok == 0L) {
    cli::cli_warn("All {summary_stats$n_trials} micro-pilot trial{?s} failed; inspect `$trials$error`.")
  }

  structure(
    list(
      trials = trials,
      summary = summary_stats,
      meta = list(
        n_pilot = as.integer(length(selected_idx)),
        n_total_hint = as.integer(n_total),
        cpus_per_task = as.integer(cpus_per_task),
        packages = packages,
        sample_method = sample_method,
        isolate = isolate,
        sample_interval = sample_interval,
        timestamp = sp_timestamp(),
        r_version = as.character(getRversion()),
        platform = R.version$platform,
        seed = seed
      )
    ),
    class = "slurmpilot_pilot"
  )
}

#' @export
print.slurmpilot_pilot <- function(x, ...) {
  s <- x$summary
  cli::cli_h3("slurmpilot Micro-Pilot Profile")
  cli::cli_bullets(c(
    "*" = "Trials: {s$n_ok}/{s$n_trials} succeeded (isolated={x$meta$isolate}, cpus={x$meta$cpus_per_task})",
    "*" = "Task exec time: median {sprintf('%.3fs', s$exec_q50_sec)}, p90 {sprintf('%.3fs', s$exec_q90_sec)}, max {sprintf('%.3fs', s$exec_max_sec)}",
    "*" = "Worker startup: median {sprintf('%.3fs', s$startup_median_sec)}",
    "*" = "Memory (RSS): baseline {sprintf('%.1f MB', s$baseline_rss_median_mb)}, peak max {sprintf('%.1f MB', s$peak_rss_max_mb)}, net max {sprintf('%.1f MB', s$net_rss_max_mb)}"
  ))
  invisible(x)
}

#' @export
summary.slurmpilot_pilot <- function(object, ...) {
  s <- object$summary
  tibble::tibble(
    metric = c(
      "n_trials", "n_ok", "n_failed",
      "startup_median_sec", "exec_mean_sec", "exec_sd_sec",
      "exec_q50_sec", "exec_q90_sec", "exec_q95_sec", "exec_max_sec",
      "baseline_rss_median_mb", "peak_rss_max_mb", "net_rss_max_mb"
    ),
    value = c(
      s$n_trials, s$n_ok, s$n_failed,
      s$startup_median_sec, s$exec_mean_sec, s$exec_sd_sec,
      s$exec_q50_sec, s$exec_q90_sec, s$exec_q95_sec, s$exec_max_sec,
      s$baseline_rss_median_mb, s$peak_rss_max_mb, s$net_rss_max_mb
    )
  )
}

#' Plot a Micro-Pilot Profile
#'
#' Visualizes per-trial execution time, startup overhead, and peak RSS memory
#' from a [pilot_run()] result.
#'
#' @param x A `slurmpilot_pilot` object returned by [pilot_run()].
#' @param engine Graphics engine: `"base"` (default, zero extra dependencies) or
#'   `"ggplot2"` (returns a `ggplot` object if `ggplot2` is installed).
#' @param ... Unused; kept for S3 generic compatibility.
#'
#' @return Invisibly returns `x` for `engine = "base"`, or a `ggplot` object
#'   for `engine = "ggplot2"`.
#' @export
#' @examples
#' pilot <- pilot_run(
#'   fun = function(x) mean(rnorm(x)),
#'   args_list = list(100, 100),
#'   n_pilot = 2L,
#'   isolate = FALSE
#' )
#' plot(pilot, engine = "base")
plot.slurmpilot_pilot <- function(x, engine = c("base", "ggplot2"), ...) {
  engine <- match.arg(engine)
  trials <- x$trials

  if (engine == "ggplot2") {
    rlang::check_installed("ggplot2", reason = "to plot pilot profiles with ggplot2")
    df_time <- tibble::tibble(
      trial = factor(paste0("#", trials$trial_id), levels = paste0("#", trials$trial_id)),
      panel = "Task Exec Time (s)",
      value = trials$exec_sec
    )
    df_mem <- tibble::tibble(
      trial = factor(paste0("#", trials$trial_id), levels = paste0("#", trials$trial_id)),
      panel = "Peak RSS (MB)",
      value = trials$peak_rss_mb
    )
    df <- rbind(df_time, df_mem)
    p <- ggplot2::ggplot(df, ggplot2::aes(x = .data$trial, y = .data$value, fill = .data$panel)) +
      ggplot2::geom_col(show.legend = FALSE, width = 0.65) +
      ggplot2::facet_wrap(~ .data$panel, scales = "free_y") +
      ggplot2::labs(
        title = "slurmpilot Micro-Pilot Resource Profile",
        x = "Pilot Trial",
        y = NULL
      ) +
      ggplot2::theme_minimal()
    return(p)
  }

  old_par <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(old_par), add = TRUE)
  graphics::par(mfrow = c(1L, 2L), mar = c(4.2, 4.2, 3, 1))

  labels <- paste0("#", trials$trial_id)
  exec_vals <- ifelse(is.na(trials$exec_sec), 0, trials$exec_sec)
  startup_vals <- ifelse(is.na(trials$startup_sec), 0, trials$startup_sec)
  time_mat <- rbind(Startup = startup_vals, Execution = exec_vals)

  graphics::barplot(
    time_mat,
    names.arg = labels,
    col = c("#6c757d", "#0d6efd"),
    border = NA,
    ylab = "Seconds",
    xlab = "Pilot Trial",
    main = "Walltime Breakdown",
    legend.text = TRUE,
    args.legend = list(bty = "n", cex = 0.85, x = "topright")
  )

  base_vals <- ifelse(is.na(trials$baseline_rss_mb), 0, trials$baseline_rss_mb)
  net_vals <- ifelse(is.na(trials$net_rss_mb), 0, trials$net_rss_mb)
  mem_mat <- rbind(Baseline = base_vals, NetWork = net_vals)

  graphics::barplot(
    mem_mat,
    names.arg = labels,
    col = c("#adb5bd", "#198754"),
    border = NA,
    ylab = "Memory (MB)",
    xlab = "Pilot Trial",
    main = "Peak RSS Memory",
    legend.text = TRUE,
    args.legend = list(bty = "n", cex = 0.85, x = "topright")
  )

  invisible(x)
}
