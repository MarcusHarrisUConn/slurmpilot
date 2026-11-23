test_that("pilot_run empirically measures RSS and runtime in isolated child processes", {
  args <- lapply(1:6, function(i) list(n = 3000L, seed = i))
  helper_scale <- 2.5

  pilot <- pilot_run(
    fun = function(x) {
      set.seed(x$seed)
      v <- rnorm(x$n)
      Sys.sleep(0.05)
      mean(v) * helper_scale
    },
    args_list = args,
    n_pilot = 3L,
    sample_method = "stratified",
    globals = list(helper_scale = helper_scale),
    seed = 42L,
    isolate = TRUE
  )

  expect_s3_class(pilot, "slurmpilot_pilot")
  expect_equal(nrow(pilot$trials), 3L)
  expect_equal(pilot$trials$task_index, c(1L, 4L, 6L))
  expect_equal(pilot$summary$n_ok, 3L)
  expect_equal(pilot$summary$n_failed, 0L)
  expect_true(all(pilot$trials$exec_sec >= 0.04))
  expect_true(all(pilot$trials$peak_rss_mb > 10))
  expect_true(all(!is.na(pilot$trials$startup_sec)))

  # Print and summary methods
  expect_invisible(print(pilot))
  sm <- summary(pilot)
  expect_s3_class(sm, "tbl_df")
  expect_true("peak_rss_max_mb" %in% sm$metric)

  # Base plot and ggplot2 plot
  tmp_pdf <- withr::local_tempfile(fileext = ".pdf")
  grDevices::pdf(tmp_pdf)
  on.exit(grDevices::dev.off(), add = TRUE)
  expect_invisible(plot(pilot, engine = "base"))

  if (requireNamespace("ggplot2", quietly = TRUE)) {
    gp <- plot(pilot, engine = "ggplot2")
    expect_s3_class(gp, "ggplot")
  }
})

test_that("pilot_run captures real OS RSS spikes from memory-heavy tasks", {
  light_pilot <- pilot_run(
    fun = function(x) {
      Sys.sleep(0.08)
      x + 1
    },
    args_list = list(1, 2),
    n_pilot = 1L,
    sample_interval = 0.02,
    isolate = TRUE
  )

  heavy_pilot <- pilot_run(
    fun = function(x) {
      # Allocate ~48 MB numeric vector and touch memory so OS commits RSS pages
      buf <- numeric(6e6)
      buf[seq(1L, length(buf), by = 512L)] <- 1.5
      Sys.sleep(0.12)
      sum(buf)
    },
    args_list = list(1, 2),
    n_pilot = 1L,
    sample_interval = 0.02,
    isolate = TRUE
  )

  expect_gt(heavy_pilot$summary$peak_rss_max_mb, light_pilot$summary$peak_rss_max_mb + 20)
  expect_gt(heavy_pilot$summary$net_rss_max_mb, 20)
})

test_that("pilot_run handles trial failures, timeouts, and in-process fallback", {
  expect_warning(
    fail_pilot <- pilot_run(
      fun = function(x) stop("boom"),
      args_list = list(1, 2),
      n_pilot = 2L,
      isolate = TRUE
    ),
    "All 2 micro-pilot trials failed"
  )
  expect_equal(fail_pilot$summary$n_ok, 0L)
  expect_equal(fail_pilot$summary$n_failed, 2L)
  expect_error(estimate_resources(fail_pilot, n_tasks = 10L), "0 successful trials")

  # Timeout in isolated child
  expect_warning(
    to_pilot <- pilot_run(
      fun = function(x) Sys.sleep(3),
      args_list = list(1),
      n_pilot = 1L,
      timeout_sec = 0.25,
      sample_interval = 0.03,
      isolate = TRUE
    ),
    "failed"
  )
  expect_equal(to_pilot$trials$status, "TIMEOUT")

  # In-process fallback
  fast_pilot <- pilot_run(
    fun = function(x) x^2,
    args_list = as.list(1:4),
    n_pilot = 2L,
    sample_method = "random",
    seed = 7L,
    isolate = FALSE
  )
  expect_equal(fast_pilot$summary$n_ok, 2L)
  expect_equal(fast_pilot$summary$startup_median_sec, 0)
})

test_that("estimate_resources obeys chunking, scaling math, safety margins, and flags", {
  # Construct deterministic synthetic pilot to verify exact math invariants
  synth_trials <- tibble::tibble(
    trial_id = 1:4,
    task_index = 1:4,
    status = rep("OK", 4),
    wall_sec = c(11.0, 12.0, 13.0, 14.0),
    startup_sec = c(2.0, 2.0, 2.0, 2.0),
    exec_sec = c(9.0, 10.0, 11.0, 12.0),
    baseline_rss_mb = c(120, 120, 120, 120),
    peak_rss_mb = c(400, 420, 450, 430),
    net_rss_mb = c(280, 300, 330, 310),
    cpu_user_sec = c(8, 9, 10, 11),
    cpu_sys_sec = c(0.2, 0.2, 0.2, 0.2),
    n_samples = rep(20L, 4),
    result_size_bytes = rep(1024, 4),
    error = rep(NA_character_, 4)
  )
  synth_pilot <- structure(
    list(
      trials = synth_trials,
      summary = sp_summarize_pilot_trials(synth_trials),
      meta = list(n_pilot = 4L, n_total_hint = 500L, cpus_per_task = 1L, isolate = TRUE)
    ),
    class = "slurmpilot_pilot"
  )

  r_base <- estimate_resources(
    synth_pilot,
    n_tasks = 500L,
    target_chunk_minutes = 5,
    mem_safety = 1.25,
    time_safety = 1.25,
    partition = "general",
    account = "stat_lab",
    qos = "normal",
    max_concurrent = 10L
  )
  expect_s3_class(r_base, "slurmpilot_resources")
  expect_equal(r_base$n_tasks, 500L)
  expect_equal(sum(r_base$chunks$n_tasks), 500L)
  expect_true(r_base$n_chunks <= 1000L)
  expect_true(any(grepl("^--partition=general$", r_base$slurm_flags)))
  expect_true(any(grepl("^--account=stat_lab$", r_base$slurm_flags)))
  expect_true(any(grepl("^--qos=normal$", r_base$slurm_flags)))
  expect_true(any(grepl("%10$", r_base$slurm_flags)))

  # Higher safety margins produce >= memory and >= time
  r_safe <- estimate_resources(
    synth_pilot,
    n_tasks = 500L,
    target_chunk_minutes = 5,
    mem_safety = 2.0,
    time_safety = 2.0
  )
  expect_gte(r_safe$mem_mb, r_base$mem_mb)
  expect_gte(r_safe$time_sec, r_base$time_sec)

  # Max array size forces larger chunks
  r_capped <- estimate_resources(
    synth_pilot,
    n_tasks = 500L,
    target_chunk_minutes = 1,
    max_array_size = 5L
  )
  expect_lte(r_capped$n_chunks, 5L)
  expect_gte(r_capped$chunk_size, 100L)

  # Amdahl speedup with more CPUs
  r_4cpu <- estimate_resources(
    synth_pilot,
    n_tasks = 500L,
    target_chunk_minutes = 5,
    cpus_per_task = 4L,
    parallel_efficiency = 0.8
  )
  expect_gt(r_4cpu$estimates$cpu_speedup, 2.0)
  expect_lt(r_4cpu$estimates$per_task_mean_sec, r_base$estimates$per_task_mean_sec)

  # scale_resources and surgical flag override
  r_scaled <- scale_resources(r_base, mem_multiplier = 1.5, time_multiplier = 2.0)
  expect_gte(r_scaled$mem_mb, r_base$mem_mb * 1.5)
  expect_gte(r_scaled$time_sec, r_base$time_sec * 2.0)

  retry_flags <- as_slurm_flags(r_base, array_indices = c(2L, 3L, 7L))
  expect_equal(retry_flags[[1L]], "--array=2-3,7%10")
  expect_invisible(print(r_base))
})
