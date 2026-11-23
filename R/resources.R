# Resource scaling model and SLURM flag estimation for slurmpilot

#' Estimate Optimal SLURM Array Resources from a Micro-Pilot
#'
#' Fits an empirical runtime and memory scaling model from a [pilot_run()]
#' result and computes optimal SLURM array chunking (`--array`), memory ceiling
#' (`--mem`), walltime limit (`--time`), and CPU allocation (`--cpus-per-task`)
#' with configurable safety margins and queue-friendly rounding.
#'
#' @details
#' For a chunk of \eqn{k} sequential tasks on \eqn{c} CPUs (relative to pilot
#' CPU count \eqn{c_0} with Amdahl parallel efficiency \eqn{\eta}):
#' - Relative speedup is
#'   \eqn{S = ((1 - \eta) + \eta / c_0) / ((1 - \eta) + \eta / c)}.
#' - Optimal chunk size \eqn{k^*} balances target chunk duration
#'   (`target_chunk_minutes`) against startup overhead amortization and
#'   `max_array_size`.
#' - Chunk walltime upper bound combines CLT standard-deviation scaling
#'   (\eqn{\sqrt{k^*}\sigma_t}) with Fenton-Wilkinson log-normal and
#'   nonparametric upper-quantile protection plus `time_safety`.
#' - Chunk memory accounts for baseline RSS, peak net working set, modest
#'   logarithmic heap fragmentation across sequential replications
#'   (\eqn{1 + 0.05 \log_2(k^*)}), and `mem_safety`.
#'
#' @param pilot A `slurmpilot_pilot` object returned by [pilot_run()].
#' @param n_tasks Positive integer total number of tasks in the full workload.
#'   Defaults to `pilot$meta$n_total_hint`.
#' @param target_chunk_minutes Target walltime in minutes per SLURM array task.
#'   Default `15`.
#' @param max_array_size Maximum number of SLURM array indices allowed by the
#'   cluster (`MaxArraySize`). Default `1000L`.
#' @param min_chunk_size Minimum tasks per SLURM array chunk. Default `1L`.
#' @param max_chunk_size Optional maximum tasks per SLURM array chunk.
#' @param mem_safety Multiplicative safety factor applied to predicted peak
#'   RSS. Default `1.35`.
#' @param time_safety Multiplicative safety factor applied to predicted upper
#'   walltime. Default `1.50`.
#' @param mem_min_mb Minimum requested memory in MB. Default `512L`.
#' @param mem_round_mb Granularity in MB to round requested memory up to.
#'   Default `256L`.
#' @param time_min_minutes Minimum requested walltime in minutes. Default `5`.
#' @param time_round_minutes Granularity in minutes to round requested walltime
#'   up to. Default `5`.
#' @param cpus_per_task Optional integer CPU count per SLURM array task.
#'   Defaults to `pilot$meta$cpus_per_task`.
#' @param parallel_efficiency Numeric in `(0, 1]` specifying Amdahl parallel
#'   efficiency when scaling `cpus_per_task` beyond the pilot CPU count.
#'   Default `0.85`.
#' @param partition Optional SLURM `--partition` name.
#' @param account Optional SLURM `--account` name.
#' @param qos Optional SLURM `--qos` name.
#' @param max_concurrent Optional positive integer array concurrency cap
#'   (`--array=1-M%max_concurrent`).
#' @param strategy Chunk assignment strategy: `"contiguous"` (default),
#'   `"round_robin"`, or `"lpt"` (Longest Processing Time first load balancing
#'   for heterogeneous task workloads).
#' @param task_weights Optional positive numeric vector of length `n_tasks`
#'   providing relative per-task runtime/cost weights for `"lpt"` load
#'   balancing. When `strategy = "lpt"` and `task_weights = NULL`, weights are
#'   interpolated linearly from the pilot trials across `1:n_tasks` (or fall
#'   back to uniform weights if fewer than 2 distinct pilot indices exist).
#'
#' @return An S3 object of class `"slurmpilot_resources"` containing computed
#'   chunking, SLURM resource values, formatted flags (`slurm_flags`),
#'   partition table (`chunks`), and diagnostic scaling estimates (`estimates`).
#'
#' @seealso [pilot_run()], [resource_spec()], [plan_chunks()], [as_slurm_flags()]
#' @export
#' @examples
#' args <- lapply(1:10, function(i) list(n = 200, seed = i))
#' pilot <- pilot_run(
#'   fun = function(x) {
#'     set.seed(x$seed)
#'     mean(rnorm(x$n))
#'   },
#'   args_list = args,
#'   n_pilot = 2L
#' )
#' res <- estimate_resources(pilot, n_tasks = 500L, target_chunk_minutes = 5)
#' print(res)
estimate_resources <- function(
  pilot,
  n_tasks = pilot$meta$n_total_hint,
  target_chunk_minutes = 15,
  max_array_size = 1000L,
  min_chunk_size = 1L,
  max_chunk_size = NULL,
  mem_safety = 1.35,
  time_safety = 1.50,
  mem_min_mb = 512L,
  mem_round_mb = 256L,
  time_min_minutes = 5,
  time_round_minutes = 5,
  cpus_per_task = NULL,
  parallel_efficiency = 0.85,
  partition = NULL,
  account = NULL,
  qos = NULL,
  max_concurrent = NULL,
  strategy = c("contiguous", "round_robin", "lpt"),
  task_weights = NULL
) {
  checkmate::assert_class(pilot, "slurmpilot_pilot")
  checkmate::assert_int(n_tasks, lower = 1L)
  checkmate::assert_number(target_chunk_minutes, lower = 0.01, finite = TRUE)
  checkmate::assert_int(max_array_size, lower = 1L)
  checkmate::assert_int(min_chunk_size, lower = 1L)
  if (!is.null(max_chunk_size)) {
    checkmate::assert_int(max_chunk_size, lower = min_chunk_size)
  }
  checkmate::assert_number(mem_safety, lower = 1.0, finite = TRUE)
  checkmate::assert_number(time_safety, lower = 1.0, finite = TRUE)
  checkmate::assert_number(mem_min_mb, lower = 16, finite = TRUE)
  checkmate::assert_number(mem_round_mb, lower = 1, finite = TRUE)
  checkmate::assert_number(time_min_minutes, lower = 0.1, finite = TRUE)
  checkmate::assert_number(time_round_minutes, lower = 0.1, finite = TRUE)
  if (is.null(cpus_per_task)) {
    cpus_per_task <- pilot$meta$cpus_per_task %||% 1L
  }
  checkmate::assert_int(cpus_per_task, lower = 1L)
  checkmate::assert_number(parallel_efficiency, lower = 0.01, upper = 1.0)
  if (!is.null(partition)) sp_assert_safe_slurm_token(partition, arg = "partition")
  if (!is.null(account)) sp_assert_safe_slurm_token(account, arg = "account")
  if (!is.null(qos)) sp_assert_safe_slurm_token(qos, arg = "qos")
  if (!is.null(max_concurrent)) checkmate::assert_int(max_concurrent, lower = 1L)
  strategy <- match.arg(strategy)
  if (!is.null(task_weights)) {
    checkmate::assert_numeric(task_weights, len = n_tasks, lower = 0, finite = TRUE, any.missing = FALSE)
  }

  s <- pilot$summary
  if (is.null(s$n_ok) || s$n_ok < 1L) {
    err_msgs <- unique(stats::na.omit(pilot$trials$error))
    cli::cli_abort(c(
      "Cannot estimate resources from a micro-pilot with 0 successful trials ({s$n_failed %||% nrow(pilot$trials)} failed, {s$n_timeout %||% 0L} timed out, {s$n_oom_suspect %||% 0L} OOM suspect).",
      if (length(err_msgs) > 0L) c("x" = "Sample pilot error: {err_msgs[[1L]]}")
    ))
  }

  # Collect raw successful execution times for robust heavy-tailed modeling
  ok_trials <- pilot$trials[pilot$trials$status == "OK", , drop = FALSE]
  exec_raw <- ok_trials$exec_sec
  exec_raw <- exec_raw[!is.na(exec_raw) & is.finite(exec_raw)]
  if (length(exec_raw) == 0L) {
    exec_raw <- max(1e-5, s$exec_mean_sec %||% 1e-3)
  }

  # 1. CPU scaling via Amdahl's law
  c0 <- as.numeric(pilot$meta$cpus_per_task %||% 1L)
  c_req <- as.numeric(cpus_per_task)
  eta <- as.numeric(parallel_efficiency)
  speedup <- ((1 - eta) + eta / c0) / ((1 - eta) + eta / c_req)

  t0 <- if (is.na(s$startup_median_sec)) 0 else max(0, s$startup_median_sec)
  exec_scaled <- pmax(exec_raw, 1e-5) / speedup
  n_ok <- length(exec_scaled)

  mu_t <- mean(exec_scaled)
  sd_t <- if (n_ok >= 2L && is.finite(stats::sd(exec_scaled)) && stats::sd(exec_scaled) > 0) {
    stats::sd(exec_scaled)
  } else {
    0.25 * mu_t
  }
  q_vals <- stats::quantile(exec_scaled, probs = c(0.50, 0.75, 0.90, 0.95), names = FALSE)
  q50_t <- q_vals[[1L]]
  q75_t <- q_vals[[2L]]
  q90_t <- max(mu_t, q_vals[[3L]])
  q95_t <- max(q90_t, q_vals[[4L]])
  max_t <- max(exec_scaled)

  # Sub-millisecond and heavy-tail diagnostics
  sub_ms <- isTRUE(q50_t < 1e-3)
  log_exec <- log(exec_scaled)
  log_mu <- mean(log_exec)
  log_sd_raw <- if (n_ok >= 2L) stats::sd(log_exec) else 0.25
  if (!is.finite(log_sd_raw) || log_sd_raw <= 0) log_sd_raw <- 0.25
  # Cap log_sd to avoid numerical explosion on tiny samples while preserving heavy tails
  log_sd <- min(log_sd_raw, 2.0)
  skew_ratio <- max_t / max(q50_t, 1e-5)
  is_heavy_tailed <- isTRUE(skew_ratio >= 2.5) || isTRUE(log_sd_raw >= 0.75)

  # 2. Optimal chunk size (overflow-safe for sub-millisecond tasks)
  target_sec <- target_chunk_minutes * 60
  eff_unit_sec <- max(mu_t, 1e-5)
  k_time_dbl <- floor(max(1, target_sec - t0) / eff_unit_sec)
  k_time <- as.integer(max(1, min(as.numeric(n_tasks), k_time_dbl)))
  k_cap <- as.integer(ceiling(n_tasks / max_array_size))
  k_upper <- min(n_tasks, max_chunk_size %||% n_tasks)
  k_lower <- min(min_chunk_size, n_tasks)

  chunk_size <- as.integer(max(k_lower, min(k_upper, max(k_time, k_cap))))
  n_chunks <- as.integer(ceiling(n_tasks / chunk_size))

  # Derive LPT weights from pilot runtimes if requested without explicit task_weights
  eff_weights <- task_weights
  if (strategy == "lpt" && is.null(eff_weights)) {
    if (nrow(ok_trials) >= 2L && length(unique(ok_trials$task_index)) >= 2L) {
      eff_weights <- stats::approx(
        x = ok_trials$task_index,
        y = pmax(ok_trials$exec_sec, 1e-5),
        xout = seq_len(n_tasks),
        rule = 2
      )$y
    } else {
      eff_weights <- rep(mu_t, n_tasks)
    }
  }

  # Preview chunk partitioning so heterogeneous load imbalance informs walltime
  preview_chunks <- sp_partition_tasks(
    n_tasks = n_tasks,
    chunk_size = chunk_size,
    strategy = strategy,
    task_weights = eff_weights
  )
  load_imbalance <- if (mean(preview_chunks$estimated_weight) > 0) {
    max(preview_chunks$estimated_weight) / mean(preview_chunks$estimated_weight)
  } else {
    1
  }

  # 3. Robust walltime prediction: max(CLT, Fenton-Wilkinson Log-Normal, Nonparametric tail)
  df <- max(1L, as.integer(n_ok) - 1L)
  z_tail <- min(3.5, max(2.326, stats::qt(0.99, df = df)))
  expected_chunk_sec <- t0 + chunk_size * mu_t * load_imbalance

  # (a) Normal CLT sum upper bound
  pred_clt_exec <- chunk_size * mu_t * load_imbalance + z_tail * sqrt(chunk_size) * sd_t

  # (b) Fenton-Wilkinson log-normal sum approximation for skewed positive runtimes
  ln_mean_1 <- exp(log_mu + 0.5 * log_sd^2)
  ln_cv2_1 <- exp(log_sd^2) - 1
  ln_sum_mean <- chunk_size * ln_mean_1 * load_imbalance
  ln_sum_sigma2 <- log(1 + ln_cv2_1 / chunk_size)
  ln_sum_mu <- log(ln_sum_mean) - 0.5 * ln_sum_sigma2
  pred_ln_exec <- exp(ln_sum_mu + z_tail * sqrt(ln_sum_sigma2))
  # Guard against pathological small-sample log-normal extrapolation (> 5x worst-case linear)
  pred_ln_exec <- min(pred_ln_exec, 5 * chunk_size * max_t)

  # (c) Nonparametric order-statistic protection (survives worst observed spike + rest at q75, or q95 linear)
  pred_np_exec <- max(chunk_size * q95_t, max_t + (chunk_size - 1) * q75_t) * load_imbalance

  candidates <- c(clt = pred_clt_exec, lognormal = pred_ln_exec, nonparametric = pred_np_exec)
  dominant_idx <- which.max(candidates)
  dominant_model <- names(candidates)[[dominant_idx]]
  pred_chunk_sec <- t0 + candidates[[dominant_idx]]
  overhead_ratio <- if (expected_chunk_sec > 0) t0 / expected_chunk_sec else 0

  req_minutes_raw <- max(time_min_minutes, (time_safety * pred_chunk_sec) / 60)
  req_minutes <- sp_ceil_to(req_minutes_raw, time_round_minutes)
  time_sec <- as.integer(ceiling(req_minutes * 60))

  # 4. Memory prediction & safety margin
  peak_obs <- if (is.na(s$peak_rss_max_mb)) 256 else s$peak_rss_max_mb
  base_obs <- if (is.na(s$baseline_rss_median_mb)) peak_obs else s$baseline_rss_median_mb
  net_obs <- if (is.na(s$net_rss_max_mb)) 0 else s$net_rss_max_mb
  base_mem <- max(peak_obs, base_obs + net_obs)

  frag_factor <- 1 + 0.05 * log2(max(1, chunk_size))
  cpu_mem_factor <- 1 + 0.15 * max(0, c_req - c0)
  pred_mem_mb <- base_mem * frag_factor * cpu_mem_factor

  mem_mb <- as.integer(sp_ceil_to(max(mem_min_mb, mem_safety * pred_mem_mb), mem_round_mb))

  # Collect actionable pilot recovery / accuracy diagnostics
  diag_warnings <- character(0L)
  fail_rate <- s$failure_rate %||% 0
  if (is.finite(fail_rate) && fail_rate > 0) {
    diag_warnings <- c(
      diag_warnings,
      sprintf(
        "Micro-pilot experienced %.0f%% failure rate (%d/%d failed; timeout=%d, oom_suspect=%d); consider increasing mem_safety/time_safety or inspecting pilot$trials$error.",
        100 * fail_rate, s$n_failed %||% 0L, s$n_trials %||% n_ok,
        s$n_timeout %||% 0L, s$n_oom_suspect %||% 0L
      )
    )
  }
  if (is_heavy_tailed) {
    diag_warnings <- c(
      diag_warnings,
      sprintf(
        "Right-skewed / heavy-tailed pilot runtimes detected (max/median = %.1fx, log-SD = %.2f); using %s upper-tail walltime bound.",
        skew_ratio, log_sd_raw, dominant_model
      )
    )
  }
  if (sub_ms && overhead_ratio > 0.25) {
    diag_warnings <- c(
      diag_warnings,
      sprintf(
        "Sub-millisecond tasks detected (median %.4fs) with %.0f%% worker startup overhead; consider increasing chunk_size.",
        q50_t, 100 * overhead_ratio
      )
    )
  }

  res <- resource_spec(
    n_tasks = n_tasks,
    chunk_size = chunk_size,
    mem_mb = mem_mb,
    time_minutes = time_sec / 60,
    cpus_per_task = cpus_per_task,
    partition = partition,
    account = account,
    qos = qos,
    max_concurrent = max_concurrent,
    strategy = strategy,
    task_weights = eff_weights
  )

  res$estimates <- list(
    source = "micro_pilot",
    n_pilot_ok = n_ok,
    pilot_failure_rate = fail_rate,
    startup_sec = t0,
    per_task_mean_sec = mu_t,
    per_task_sd_sec = sd_t,
    per_task_q90_sec = q90_t,
    per_task_q95_sec = q95_t,
    per_task_max_sec = max_t,
    cpu_speedup = speedup,
    chunk_strategy = strategy,
    load_imbalance = load_imbalance,
    expected_chunk_sec = expected_chunk_sec,
    predicted_chunk_sec = pred_chunk_sec,
    pred_clt_sec = t0 + pred_clt_exec,
    pred_lognormal_sec = t0 + pred_ln_exec,
    pred_nonparametric_sec = t0 + pred_np_exec,
    dominant_model = dominant_model,
    is_heavy_tailed = is_heavy_tailed,
    skewness_ratio = skew_ratio,
    sub_millisecond = sub_ms,
    overhead_ratio = overhead_ratio,
    predicted_peak_rss_mb = pred_mem_mb,
    total_cpu_hours = (n_chunks * expected_chunk_sec * cpus_per_task) / 3600,
    diagnostics = diag_warnings
  )
  res$assumptions <- list(
    target_chunk_minutes = target_chunk_minutes,
    max_array_size = max_array_size,
    mem_safety = mem_safety,
    time_safety = time_safety,
    parallel_efficiency = parallel_efficiency,
    z_tail = z_tail
  )
  res
}

#' Construct an Explicit SLURM Resource Specification
#'
#' Creates a validated `slurmpilot_resources` object directly from user-chosen
#' chunk size, memory, walltime, and scheduler flags (without requiring a
#' micro-pilot run).
#'
#' @param n_tasks Positive integer total number of tasks.
#' @param chunk_size Positive integer number of tasks grouped into each SLURM
#'   array chunk. Default `1L`.
#' @param mem_mb Numeric memory limit per array task in MB. Default `1024`.
#' @param time_minutes Numeric walltime limit per array task in minutes.
#'   Default `15`.
#' @param cpus_per_task Positive integer CPU cores per array task. Default `1L`.
#' @param partition Optional SLURM `--partition`.
#' @param account Optional SLURM `--account`.
#' @param qos Optional SLURM `--qos`.
#' @param max_concurrent Optional positive integer array concurrency cap.
#' @param strategy Chunk assignment strategy: `"contiguous"` (default),
#'   `"round_robin"`, or `"lpt"`.
#' @param task_weights Optional positive numeric vector of length `n_tasks`
#'   required when `strategy = "lpt"`.
#'
#' @return An S3 object of class `"slurmpilot_resources"`.
#' @seealso [estimate_resources()], [plan_chunks()], [as_slurm_flags()]
#' @export
#' @examples
#' spec <- resource_spec(n_tasks = 100, chunk_size = 10, mem_mb = 2048, time_minutes = 30)
#' as_slurm_flags(spec)
resource_spec <- function(
  n_tasks,
  chunk_size = 1L,
  mem_mb = 1024,
  time_minutes = 15,
  cpus_per_task = 1L,
  partition = NULL,
  account = NULL,
  qos = NULL,
  max_concurrent = NULL,
  strategy = c("contiguous", "round_robin", "lpt"),
  task_weights = NULL
) {
  checkmate::assert_int(n_tasks, lower = 1L)
  checkmate::assert_int(chunk_size, lower = 1L)
  checkmate::assert_number(mem_mb, lower = 16, finite = TRUE)
  checkmate::assert_number(time_minutes, lower = 1 / 60, finite = TRUE)
  checkmate::assert_int(cpus_per_task, lower = 1L)
  if (!is.null(partition)) sp_assert_safe_slurm_token(partition, arg = "partition")
  if (!is.null(account)) sp_assert_safe_slurm_token(account, arg = "account")
  if (!is.null(qos)) sp_assert_safe_slurm_token(qos, arg = "qos")
  if (!is.null(max_concurrent)) checkmate::assert_int(max_concurrent, lower = 1L)
  strategy <- match.arg(strategy)

  chunk_size <- min(as.integer(chunk_size), as.integer(n_tasks))
  chunks <- sp_partition_tasks(n_tasks, chunk_size, strategy = strategy, task_weights = task_weights)
  n_chunks <- nrow(chunks)

  mem_mb_int <- as.integer(ceiling(mem_mb))
  time_sec <- as.integer(ceiling(time_minutes * 60))
  mem_slurm <- format_slurm_mem(mem_mb_int)
  time_slurm <- format_slurm_time(time_sec)
  array_spec <- format_slurm_array_indices(seq_len(n_chunks), max_concurrent = max_concurrent)

  obj <- structure(
    list(
      n_tasks = as.integer(n_tasks),
      chunk_size = chunk_size,
      n_chunks = as.integer(n_chunks),
      strategy = strategy,
      mem_mb = mem_mb_int,
      mem_slurm = mem_slurm,
      time_sec = time_sec,
      time_slurm = time_slurm,
      cpus_per_task = as.integer(cpus_per_task),
      array_spec = array_spec,
      partition = partition,
      account = account,
      qos = qos,
      max_concurrent = if (!is.null(max_concurrent)) as.integer(max_concurrent) else NULL,
      chunks = chunks,
      estimates = list(source = "manual"),
      assumptions = list()
    ),
    class = "slurmpilot_resources"
  )
  obj$slurm_flags <- as_slurm_flags(obj)
  obj
}

#' Scale Memory and/or Walltime of a Resource Specification
#'
#' Creates a copy of a `slurmpilot_resources` specification with memory and/or
#' walltime scaled by positive multipliers, commonly used when surgically
#' retrying failed `OUT_OF_MEMORY` or `TIMEOUT` chunks. Preserves exact
#' chunk-to-task assignments.
#'
#' @param resources A `slurmpilot_resources` object.
#' @param mem_multiplier Positive numeric multiplier for `mem_mb`. Default `1`.
#' @param time_multiplier Positive numeric multiplier for `time_sec`. Default `1`.
#' @param mem_round_mb Rounding granularity in MB. Default `256`.
#' @param time_round_minutes Rounding granularity in minutes. Default `1`.
#'
#' @return Updated `slurmpilot_resources` object.
#' @export
#' @examples
#' base <- resource_spec(n_tasks = 20, chunk_size = 5, mem_mb = 1024, time_minutes = 10)
#' bumped <- scale_resources(base, mem_multiplier = 1.5, time_multiplier = 2.0)
#' as_slurm_flags(bumped)
scale_resources <- function(
  resources,
  mem_multiplier = 1,
  time_multiplier = 1,
  mem_round_mb = 256,
  time_round_minutes = 1
) {
  checkmate::assert_class(resources, "slurmpilot_resources")
  checkmate::assert_number(mem_multiplier, lower = 0.1, finite = TRUE)
  checkmate::assert_number(time_multiplier, lower = 0.1, finite = TRUE)

  new_mem <- if (mem_multiplier == 1) {
    resources$mem_mb
  } else {
    sp_ceil_to(resources$mem_mb * mem_multiplier, mem_round_mb)
  }

  new_time_min <- if (time_multiplier == 1) {
    resources$time_sec / 60
  } else {
    sp_ceil_to((resources$time_sec / 60) * time_multiplier, time_round_minutes)
  }

  updated <- resource_spec(
    n_tasks = resources$n_tasks,
    chunk_size = resources$chunk_size,
    mem_mb = new_mem,
    time_minutes = new_time_min,
    cpus_per_task = resources$cpus_per_task,
    partition = resources$partition,
    account = resources$account,
    qos = resources$qos,
    max_concurrent = resources$max_concurrent
  )
  # Preserve exact original chunk assignments (including round_robin / lpt)
  updated$chunks <- resources$chunks
  updated$strategy <- resources$strategy %||% "contiguous"
  updated$estimates <- resources$estimates
  updated$assumptions <- resources$assumptions
  updated
}

#' Convert a Resource Specification into SLURM CLI Flags
#'
#' Formats a `slurmpilot_resources` object into canonical SLURM `--flag=value`
#' directives suitable for `sbatch` headers or command-line submission.
#'
#' @param x Object to format (typically a `slurmpilot_resources` object).
#' @param array_indices Optional integer vector overriding the `--array` range
#'   (used during surgical retries of specific failed chunks).
#' @param ... Additional arguments passed to methods.
#'
#' @return Character vector of SLURM flags (e.g. `c("--array=1-10", "--mem=2G", ...)`).
#' @export
#' @examples
#' res <- resource_spec(n_tasks = 20, chunk_size = 5, mem_mb = 2048, time_minutes = 30)
#' as_slurm_flags(res)
#' as_slurm_flags(res, array_indices = c(2L, 4L))
as_slurm_flags <- function(x, array_indices = NULL, ...) {
  UseMethod("as_slurm_flags")
}

#' @rdname as_slurm_flags
#' @export
as_slurm_flags.slurmpilot_resources <- function(x, array_indices = NULL, ...) {
  array_val <- if (!is.null(array_indices)) {
    format_slurm_array_indices(array_indices, max_concurrent = x$max_concurrent)
  } else {
    x$array_spec
  }

  flags <- c(
    paste0("--array=", array_val),
    paste0("--cpus-per-task=", x$cpus_per_task),
    paste0("--mem=", x$mem_slurm),
    paste0("--time=", x$time_slurm)
  )
  if (!is.null(x$partition)) {
    flags <- c(flags, paste0("--partition=", x$partition))
  }
  if (!is.null(x$account)) {
    flags <- c(flags, paste0("--account=", x$account))
  }
  if (!is.null(x$qos)) {
    flags <- c(flags, paste0("--qos=", x$qos))
  }
  flags
}

#' @export
print.slurmpilot_resources <- function(x, ...) {
  cli::cli_h3("slurmpilot SLURM Resource Plan")
  cli::cli_bullets(c(
    "*" = "Workload: {x$n_tasks} tasks -> {x$n_chunks} array chunks ({x$chunk_size} tasks/chunk)",
    "*" = "SLURM flags: {paste(x$slurm_flags, collapse = ' ')}"
  ))
  if (identical(x$estimates$source, "micro_pilot")) {
    e <- x$estimates
    cli::cli_bullets(c(
      "i" = "Predicted chunk walltime: {sprintf('%.1fs', e$predicted_chunk_sec)} (expected {sprintf('%.1fs', e$expected_chunk_sec)}, startup overhead {sprintf('%.1f%%', 100 * e$overhead_ratio)})",
      "i" = "Predicted peak RSS: {sprintf('%.1f MB', e$predicted_peak_rss_mb)} -> requested {x$mem_slurm}",
      "i" = "Estimated total compute: {sprintf('%.2f CPU-hours', e$total_cpu_hours)}"
    ))
  }
  invisible(x)
}
