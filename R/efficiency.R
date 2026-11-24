# Post-mortem SLURM resource efficiency auditor and tightening recommender

#' Audit Post-Mortem SLURM Memory, Walltime, and Load-Balance Efficiency
#'
#' Analyzes requested versus empirically observed Peak RSS memory, walltime,
#' and cross-chunk straggler imbalance from a completed or partially failed
#' [slurm_submit()] job, [slurm_status()] telemetry object, [slurm_autopilot()]
#' run, or parsed [parse_sacct_output()] table. Quantifies memory waste %,
#' walltime slack %, and straggler ratio (`max / median` chunk time), and emits
#' a concrete recommended tightened [resource_spec()] for the next run.
#'
#' @param x A `slurmpilot_job`, `slurmpilot_autopilot`, `slurmpilot_status`, or
#'   data frame from [parse_sacct_output()].
#' @param resources Optional `slurmpilot_resources` object (required when `x` is
#'   a `slurmpilot_status` or `sacct` data frame; inferred automatically from
#'   `slurmpilot_job` or `slurmpilot_autopilot`).
#' @param mem_safety Safety multiplier applied to observed peak RSS when
#'   computing recommended `--mem`. Default `1.25`.
#' @param time_safety Safety multiplier applied to observed max walltime when
#'   computing recommended `--time`. Default `1.35`.
#' @param mem_min_mb Minimum recommended `--mem` in MB. Default `256L`.
#' @param mem_round_mb Rounding granularity in MB for recommended `--mem`.
#'   Default `128L`.
#' @param time_min_minutes Minimum recommended `--time` in minutes. Default `5`.
#' @param time_round_minutes Rounding granularity in minutes for recommended
#'   `--time`. Default `5`.
#'
#' @return An S3 object of class `"slurmpilot_efficiency"` containing:
#'   - `classification`: one of `"efficient"`, `"over_provisioned"`,
#'     `"under_provisioned"`, or `"imbalanced"`.
#'   - `metrics`: named list of utilization, waste, slack, straggler ratio,
#'     and failure counts.
#'   - `chunks`: per-chunk telemetry tibble with `mem_util_pct` and
#'     `time_util_pct`.
#'   - `requested_resources`: original `slurmpilot_resources` spec.
#'   - `recommended_resources`: tightened (or escalated) `slurmpilot_resources`
#'     spec for the next run.
#'   - `recommendations`: character vector of concrete optimization actions.
#'
#' @seealso [estimate_resources()], [parse_sacct_output()], [plan_chunks()]
#' @export
#' @examples
#' be <- mock_slurm_backend(max_workers = 2L)
#' res <- resource_spec(n_tasks = 6L, chunk_size = 2L, mem_mb = 2048L, time_minutes = 30)
#' job <- slurm_submit(be, function(x) mean(rnorm(200)), as.list(1:6), resources = res)
#' slurm_wait(job, poll_interval = 0.05)
#' eff <- slurm_efficiency_report(job)
#' print(eff)
#' unlink(be$root_dir, recursive = TRUE)
slurm_efficiency_report <- function(
  x,
  resources = NULL,
  mem_safety = 1.25,
  time_safety = 1.35,
  mem_min_mb = 256L,
  mem_round_mb = 128L,
  time_min_minutes = 5,
  time_round_minutes = 5
) {
  checkmate::assert_number(mem_safety, lower = 1.0, finite = TRUE)
  checkmate::assert_number(time_safety, lower = 1.0, finite = TRUE)
  checkmate::assert_number(mem_min_mb, lower = 16, finite = TRUE)
  checkmate::assert_number(mem_round_mb, lower = 1, finite = TRUE)
  checkmate::assert_number(time_min_minutes, lower = 0.1, finite = TRUE)
  checkmate::assert_number(time_round_minutes, lower = 0.1, finite = TRUE)

  if (inherits(x, "slurmpilot_autopilot")) {
    resources <- resources %||% x$resources
    chunks_df <- x$status$chunks
    job_name <- x$job$job_name
  } else if (inherits(x, "slurmpilot_job")) {
    resources <- resources %||% x$resources
    st <- slurm_status(x)
    chunks_df <- st$chunks
    job_name <- x$job_name
  } else if (inherits(x, "slurmpilot_status")) {
    chunks_df <- x$chunks
    job_name <- x$job_name
  } else if (is.data.frame(x)) {
    chunks_df <- tibble::as_tibble(x)
    if (!("wall_sec" %in% names(chunks_df)) && "elapsed_sec" %in% names(chunks_df)) {
      chunks_df$wall_sec <- chunks_df$elapsed_sec
    }
    job_name <- "sacct_job"
  } else {
    cli::cli_abort(
      "{.arg x} must be a {.cls slurmpilot_job}, {.cls slurmpilot_autopilot}, {.cls slurmpilot_status}, or {.code parse_sacct_output()} data frame."
    )
  }

  if (is.null(resources)) {
    cli::cli_abort("{.arg resources} must be supplied when auditing a {.cls slurmpilot_status} or {.code sacct} table directly.")
  }
  checkmate::assert_class(resources, "slurmpilot_resources")
  if (nrow(chunks_df) == 0L) {
    cli::cli_abort("Cannot compute efficiency report: telemetry table has 0 chunks.")
  }

  if (!("wall_sec" %in% names(chunks_df))) chunks_df$wall_sec <- NA_real_
  if (!("peak_rss_mb" %in% names(chunks_df))) chunks_df$peak_rss_mb <- NA_real_
  if (!("state" %in% names(chunks_df))) chunks_df$state <- "COMPLETED"

  req_mem <- as.numeric(resources$mem_mb)
  req_time <- as.numeric(resources$time_sec)

  rss_ok <- chunks_df$peak_rss_mb[!is.na(chunks_df$peak_rss_mb) & is.finite(chunks_df$peak_rss_mb)]
  wall_ok <- chunks_df$wall_sec[!is.na(chunks_df$wall_sec) & is.finite(chunks_df$wall_sec)]

  peak_rss_max <- if (length(rss_ok) > 0L) max(rss_ok) else NA_real_
  peak_rss_med <- if (length(rss_ok) > 0L) stats::median(rss_ok) else NA_real_
  wall_max <- if (length(wall_ok) > 0L) max(wall_ok) else NA_real_
  wall_med <- if (length(wall_ok) > 0L) stats::median(wall_ok) else NA_real_
  wall_total <- if (length(wall_ok) > 0L) sum(wall_ok) else 0

  mem_util_pct <- if (!is.na(peak_rss_max) && req_mem > 0) 100 * peak_rss_max / req_mem else NA_real_
  mem_waste_pct <- if (!is.na(mem_util_pct)) max(0, 100 - mem_util_pct) else NA_real_
  time_util_pct <- if (!is.na(wall_max) && req_time > 0) 100 * wall_max / req_time else NA_real_
  time_slack_pct <- if (!is.na(time_util_pct)) max(0, 100 - time_util_pct) else NA_real_

  straggler_ratio <- if (!is.na(wall_max) && !is.na(wall_med) && wall_med > 0) {
    wall_max / wall_med
  } else {
    1
  }

  n_oom <- sum(chunks_df$state == "OUT_OF_MEMORY", na.rm = TRUE)
  n_timeout <- sum(chunks_df$state == "TIMEOUT", na.rm = TRUE)
  n_failed <- sum(chunks_df$state == "FAILED", na.rm = TRUE)

  # Compute tightened / escalated recommended resources for next run
  rec_mem_raw <- if (n_oom > 0L) {
    max(req_mem * 1.5, if (!is.na(peak_rss_max)) peak_rss_max * mem_safety else req_mem * 1.5)
  } else if (!is.na(peak_rss_max)) {
    max(mem_min_mb, peak_rss_max * mem_safety)
  } else {
    req_mem
  }
  rec_mem_mb <- as.integer(sp_ceil_to(rec_mem_raw, mem_round_mb))

  rec_time_min_raw <- if (n_timeout > 0L) {
    (req_time * 1.5) / 60
  } else if (!is.na(wall_max)) {
    max(time_min_minutes, (wall_max * time_safety) / 60)
  } else {
    req_time / 60
  }
  rec_time_min <- sp_ceil_to(rec_time_min_raw, time_round_minutes)

  recommended <- resource_spec(
    n_tasks = resources$n_tasks,
    chunk_size = resources$chunk_size,
    mem_mb = rec_mem_mb,
    time_minutes = rec_time_min,
    cpus_per_task = resources$cpus_per_task,
    partition = resources$partition,
    account = resources$account,
    qos = resources$qos,
    max_concurrent = resources$max_concurrent
  )
  recommended$chunks <- resources$chunks
  recommended$strategy <- resources$strategy %||% "contiguous"

  # Classification & concrete recommendations
  recs <- character(0L)
  is_under <- (n_oom > 0L) || (n_timeout > 0L) ||
    (!is.na(mem_util_pct) && mem_util_pct > 90) ||
    (!is.na(time_util_pct) && time_util_pct > 90)
  is_imbalanced <- isTRUE(nrow(chunks_df) >= 2L && straggler_ratio >= 2.0)
  is_over <- (!is.na(mem_waste_pct) && mem_waste_pct > 50) ||
    (!is.na(time_slack_pct) && time_slack_pct > 60)

  classification <- if (is_under) {
    "under_provisioned"
  } else if (is_imbalanced) {
    "imbalanced"
  } else if (is_over) {
    "over_provisioned"
  } else {
    "efficient"
  }

  if (n_oom > 0L) {
    recs <- c(recs, sprintf("%d chunk(s) hit OUT_OF_MEMORY; raise --mem from %s to %s.", n_oom, resources$mem_slurm, recommended$mem_slurm))
  } else if (!is.na(mem_waste_pct) && mem_waste_pct > 50 && recommended$mem_mb < resources$mem_mb) {
    recs <- c(recs, sprintf("Memory waste is %.1f%% (peak %.1f MB vs %s requested); tighten --mem to %s.", mem_waste_pct, peak_rss_max, resources$mem_slurm, recommended$mem_slurm))
  }
  if (n_timeout > 0L) {
    recs <- c(recs, sprintf("%d chunk(s) hit TIMEOUT; raise --time from %s to %s.", n_timeout, resources$time_slurm, recommended$time_slurm))
  } else if (!is.na(time_slack_pct) && time_slack_pct > 60 && recommended$time_sec < resources$time_sec) {
    recs <- c(recs, sprintf("Walltime slack is %.1f%% (max %.1fs vs %s requested); tighten --time to %s.", time_slack_pct, wall_max, resources$time_slurm, recommended$time_slurm))
  }
  if (is_imbalanced) {
    recs <- c(recs, sprintf("High straggler ratio (%.2fx max/median chunk time); switch to strategy = 'lpt' in estimate_resources()/plan_chunks() to balance chunk loads.", straggler_ratio))
  }
  if (length(recs) == 0L) {
    recs <- "Resource allocations are well-calibrated to empirical usage."
  }

  chunks_out <- tibble::tibble(
    chunk_id = as.integer(chunks_df$chunk_id),
    state = as.character(chunks_df$state),
    wall_sec = as.numeric(chunks_df$wall_sec),
    peak_rss_mb = as.numeric(chunks_df$peak_rss_mb),
    mem_util_pct = ifelse(is.na(chunks_df$peak_rss_mb), NA_real_, 100 * chunks_df$peak_rss_mb / req_mem),
    time_util_pct = ifelse(is.na(chunks_df$wall_sec), NA_real_, 100 * chunks_df$wall_sec / req_time)
  )

  structure(
    list(
      job_name = job_name,
      classification = classification,
      metrics = list(
        n_chunks = nrow(chunks_out),
        requested_mem_mb = req_mem,
        peak_rss_max_mb = peak_rss_max,
        peak_rss_median_mb = peak_rss_med,
        mem_utilization_pct = mem_util_pct,
        mem_waste_pct = mem_waste_pct,
        requested_time_sec = req_time,
        wall_max_sec = wall_max,
        wall_median_sec = wall_med,
        wall_total_sec = wall_total,
        time_utilization_pct = time_util_pct,
        time_slack_pct = time_slack_pct,
        straggler_ratio = straggler_ratio,
        n_oom = as.integer(n_oom),
        n_timeout = as.integer(n_timeout),
        n_failed = as.integer(n_failed)
      ),
      chunks = chunks_out,
      requested_resources = resources,
      recommended_resources = recommended,
      recommendations = recs
    ),
    class = "slurmpilot_efficiency"
  )
}

#' @export
print.slurmpilot_efficiency <- function(x, ...) {
  m <- x$metrics
  cli::cli_h3("slurmpilot Post-Mortem Efficiency Audit: {x$job_name} [{x$classification}]")
  mem_str <- if (is.na(m$mem_utilization_pct)) {
    "n/a"
  } else {
    sprintf("%.1f MB max / %.0f MB req (%.1f%% util, %.1f%% waste)", m$peak_rss_max_mb, m$requested_mem_mb, m$mem_utilization_pct, m$mem_waste_pct)
  }
  time_str <- if (is.na(m$time_utilization_pct)) {
    "n/a"
  } else {
    sprintf("%.1fs max / %.0fs req (%.1f%% util, %.1f%% slack)", m$wall_max_sec, m$requested_time_sec, m$time_utilization_pct, m$time_slack_pct)
  }
  cli::cli_bullets(c(
    "*" = "Memory: {mem_str}",
    "*" = "Walltime: {time_str}",
    "*" = "Load balance: straggler ratio {sprintf('%.2fx', m$straggler_ratio)} across {m$n_chunks} chunks",
    "*" = "Recommended next flags: {paste(x$recommended_resources$slurm_flags, collapse = ' ')}"
  ))
  for (r in x$recommendations) {
    cli::cli_bullets(c("i" = r))
  }
  invisible(x)
}

#' Plot a Post-Mortem SLURM Resource Efficiency Report
#'
#' Visualizes per-chunk observed Peak RSS against requested `--mem` and
#' per-chunk walltime against requested `--time` from a
#' [slurm_efficiency_report()] audit.
#'
#' @param x A `slurmpilot_efficiency` object.
#' @param engine Graphics engine: `"base"` (default) or `"ggplot2"`.
#' @param ... Unused; kept for S3 generic compatibility.
#'
#' @return Invisibly returns `x` for `engine = "base"`, or a `ggplot` object
#'   for `engine = "ggplot2"`.
#' @export
#' @examples
#' sa <- parse_sacct_output(
#'   "100_1|COMPLETED|00:02:00|256M|0:0\n100_2|COMPLETED|00:04:00|300M|0:0"
#' )
#' res <- resource_spec(4L, 2L, mem_mb = 1024L, time_minutes = 15)
#' eff <- slurm_efficiency_report(sa, resources = res)
#' plot(eff, engine = "base")
plot.slurmpilot_efficiency <- function(x, engine = c("base", "ggplot2"), ...) {
  engine <- match.arg(engine)
  ch <- x$chunks
  m <- x$metrics

  if (engine == "ggplot2") {
    rlang::check_installed("ggplot2", reason = "to plot efficiency reports with ggplot2")
    df <- rbind(
      tibble::tibble(
        chunk = factor(paste0("#", ch$chunk_id), levels = paste0("#", ch$chunk_id)),
        metric = "Peak RSS (MB)",
        observed = ifelse(is.na(ch$peak_rss_mb), 0, ch$peak_rss_mb),
        requested = m$requested_mem_mb
      ),
      tibble::tibble(
        chunk = factor(paste0("#", ch$chunk_id), levels = paste0("#", ch$chunk_id)),
        metric = "Walltime (s)",
        observed = ifelse(is.na(ch$wall_sec), 0, ch$wall_sec),
        requested = m$requested_time_sec
      )
    )
    p <- ggplot2::ggplot(df, ggplot2::aes(x = .data$chunk, y = .data$observed)) +
      ggplot2::geom_col(fill = "#264653", width = 0.65) +
      ggplot2::geom_hline(ggplot2::aes(yintercept = .data$requested), linetype = "dashed", color = "#d62828") +
      ggplot2::facet_wrap(~ .data$metric, scales = "free_y") +
      ggplot2::labs(
        title = sprintf("Resource Efficiency Audit: %s (%s)", x$job_name, x$classification),
        subtitle = "Dashed line = requested SLURM limit",
        x = "Chunk",
        y = NULL
      ) +
      ggplot2::theme_minimal()
    return(p)
  }

  old_par <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(old_par), add = TRUE)
  graphics::par(mfrow = c(1L, 2L), mar = c(4.2, 4.2, 3, 1))

  labels <- paste0("#", ch$chunk_id)
  rss_vals <- ifelse(is.na(ch$peak_rss_mb), 0, ch$peak_rss_mb)
  ymax_rss <- max(c(rss_vals, m$requested_mem_mb), na.rm = TRUE) * 1.12
  graphics::barplot(
    rss_vals,
    names.arg = labels,
    col = "#264653",
    border = NA,
    ylim = c(0, ymax_rss),
    ylab = "Memory (MB)",
    xlab = "Chunk",
    main = "Peak RSS vs Requested --mem"
  )
  graphics::abline(h = m$requested_mem_mb, col = "#d62828", lty = 2, lwd = 2)

  wall_vals <- ifelse(is.na(ch$wall_sec), 0, ch$wall_sec)
  ymax_wall <- max(c(wall_vals, m$requested_time_sec), na.rm = TRUE) * 1.12
  graphics::barplot(
    wall_vals,
    names.arg = labels,
    col = "#2a9d8f",
    border = NA,
    ylim = c(0, ymax_wall),
    ylab = "Walltime (s)",
    xlab = "Chunk",
    main = "Chunk Walltime vs Requested --time"
  )
  graphics::abline(h = m$requested_time_sec, col = "#d62828", lty = 2, lwd = 2)

  invisible(x)
}
