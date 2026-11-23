test_that("slurm_retry performs adaptive OOM and TIMEOUT escalation with safety caps and provenance", {
  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 2L)

  res <- resource_spec(n_tasks = 8L, chunk_size = 2L, mem_mb = 512L, time_minutes = 10)
  job <- slurm_submit(
    backend = be,
    fun = function(x) x^2,
    args_list = as.list(1:8),
    resources = res,
    name = "adaptive_retry_test",
    fault_injection = list(oom_chunks = 2L, timeout_chunks = 4L, fail_once = TRUE)
  )

  st1 <- slurm_wait(job, timeout = 20, poll_interval = 0.05)
  expect_equal(st1$state, "PARTIAL_FAILURE")
  expect_equal(st1$n_oom, 1L)
  expect_equal(st1$n_timeout, 1L)
  expect_equal(nrow(slurm_retry_history(job)), 0L)

  # Adaptive retry automatically bumps --mem (OOM) AND --time (TIMEOUT)
  job <- slurm_retry(job, adaptive = TRUE, auto_mem_multiplier = 1.5, auto_time_multiplier = 1.5)
  expect_equal(job$resources$mem_mb, 768L)
  expect_equal(job$resources$time_sec, 900L)

  hist <- slurm_retry_history(job)
  expect_s3_class(hist, "tbl_df")
  expect_equal(nrow(hist), 2L)
  expect_equal(hist$chunk_id, c(2L, 4L))
  expect_equal(hist$trigger_state, c("OUT_OF_MEMORY", "TIMEOUT"))
  expect_equal(hist$old_mem_mb, c(512L, 512L))
  expect_equal(hist$new_mem_mb, c(768L, 768L))
  expect_equal(hist$old_time_sec, c(600L, 600L))
  expect_equal(hist$new_time_sec, c(900L, 900L))
  expect_true(all(hist$adaptive))
  expect_true(file.exists(file.path(job$local_dir, "retry_history.json")))

  st2 <- slurm_wait(job, timeout = 20, poll_interval = 0.05)
  expect_equal(st2$state, "COMPLETED")
  expect_equal(st2$chunks$attempt, c(1L, 2L, 1L, 2L))
  expect_equal(slurm_collect(job, simplify = TRUE), (1:8)^2)

  # Verify hard escalation ceilings (max_mem_mb / max_time_minutes)
  job_cap <- slurm_submit(
    backend = be,
    fun = function(x) x,
    args_list = as.list(1:4),
    resources = resource_spec(n_tasks = 4L, chunk_size = 2L, mem_mb = 512L, time_minutes = 10),
    name = "cap_test",
    fault_injection = list(oom_chunks = 1L, timeout_chunks = 2L, fail_once = TRUE)
  )
  slurm_wait(job_cap, timeout = 20, poll_interval = 0.05)
  job_cap <- slurm_retry(
    job_cap,
    adaptive = TRUE,
    auto_mem_multiplier = 4.0,
    auto_time_multiplier = 4.0,
    max_mem_mb = 640L,
    max_time_minutes = 12
  )
  expect_equal(job_cap$resources$mem_mb, 640L)
  expect_equal(job_cap$resources$time_sec, 720L)
  slurm_wait(job_cap, timeout = 20, poll_interval = 0.05)
})

test_that("plan_chunks, resource_spec, and estimate_resources support round_robin and LPT load balancing", {
  weights <- c(5, 10, 12, 15, 20, 30, 50, 70, 90, 100, 120, 150)

  p_con <- plan_chunks(length(weights), chunk_size = 3L, strategy = "contiguous", task_weights = weights)
  p_rr  <- plan_chunks(length(weights), chunk_size = 3L, strategy = "round_robin", task_weights = weights)
  p_lpt <- plan_chunks(length(weights), chunk_size = 3L, strategy = "lpt", task_weights = weights)

  # All strategies cover exact 1:12 tasks with zero duplicates
  expect_equal(sort(unlist(p_con$task_indices)), seq_along(weights))
  expect_equal(sort(unlist(p_rr$task_indices)), seq_along(weights))
  expect_equal(sort(unlist(p_lpt$task_indices)), seq_along(weights))

  # LPT achieves dramatically lower max chunk weight (makespan) than contiguous
  expect_lt(max(p_lpt$estimated_weight), max(p_con$estimated_weight))
  expect_lte(max(p_lpt$estimated_weight), max(p_rr$estimated_weight))

  # LPT without weights raises informative error in plan_chunks
  expect_error(plan_chunks(8L, chunk_size = 2L, strategy = "lpt"), "task_weights")

  # End-to-end execution of LPT chunking preserves exact 1..N ordering in slurm_collect()
  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 2L)
  res_lpt <- resource_spec(
    n_tasks = length(weights),
    chunk_size = 3L,
    mem_mb = 512L,
    strategy = "lpt",
    task_weights = weights
  )
  # scale_resources preserves LPT chunk assignments
  res_scaled <- scale_resources(res_lpt, mem_multiplier = 1.5)
  expect_equal(res_scaled$strategy, "lpt")
  expect_equal(res_scaled$chunks$task_indices, res_lpt$chunks$task_indices)

  job <- slurm_submit(
    backend = be,
    fun = function(item) data.frame(id = item$id, val = item$w * 2),
    args_list = Map(function(i, w) list(id = i, w = w), seq_along(weights), weights),
    resources = res_lpt,
    name = "lpt_e2e"
  )
  st <- slurm_wait(job, timeout = 20, poll_interval = 0.05)
  expect_equal(st$state, "COMPLETED")
  out <- slurm_collect(job, simplify = TRUE)
  expect_equal(out$id, seq_along(weights))
  expect_equal(out$val, weights * 2)

  # estimate_resources with strategy = "lpt" interpolates weights from stratified pilot
  pilot_trials <- tibble::tibble(
    trial_id = 1:3,
    task_index = c(1L, 6L, 12L),
    status = rep("OK", 3),
    wall_sec = c(2, 10, 40),
    startup_sec = c(1, 1, 1),
    exec_sec = c(1, 9, 39),
    baseline_rss_mb = c(80, 80, 80),
    peak_rss_mb = c(120, 140, 180),
    net_rss_mb = c(40, 60, 100),
    cpu_user_sec = c(1, 9, 39),
    cpu_sys_sec = c(0.1, 0.1, 0.1),
    n_samples = c(5L, 5L, 5L),
    result_size_bytes = c(256, 256, 256),
    error = rep(NA_character_, 3)
  )
  pilot_obj <- structure(
    list(
      trials = pilot_trials,
      summary = slurmpilot:::sp_summarize_pilot_trials(pilot_trials),
      meta = list(n_pilot = 3L, n_total_hint = 12L, cpus_per_task = 1L, isolate = TRUE)
    ),
    class = "slurmpilot_pilot"
  )
  est_lpt <- estimate_resources(pilot_obj, n_tasks = 12L, max_chunk_size = 3L, strategy = "lpt")
  expect_equal(est_lpt$strategy, "lpt")
  expect_equal(est_lpt$estimates$chunk_strategy, "lpt")
  expect_lt(est_lpt$estimates$load_imbalance, 1.35)
})

test_that("inspect_job_globals detects closure bloat, missing variables, and unexported helpers", {
  # Clean worker
  clean_fn <- function(x) stats::rnorm(x)
  rep_ok <- inspect_job_globals(clean_fn, args_list = list(10, 20))
  expect_s3_class(rep_ok, "slurmpilot_globals_report")
  expect_true(rep_ok$ok)
  expect_length(rep_ok$warnings, 0L)
  expect_invisible(print(rep_ok))

  # Bloated closure + missing variable + unexported helper
  make_bad_worker <- function() {
    big_matrix <- numeric(200000) # ~1.6 MB
    function(x) helper_fn_xyz(x) + undeclared_var_xyz + length(big_matrix)
  }
  bad_fn <- make_bad_worker()
  rep_bad <- inspect_job_globals(bad_fn, args_list = list(1, 2), size_warn_mb = 1.0)
  expect_false(rep_bad$ok)
  expect_true("big_matrix" %in% rep_bad$closure_objects$name)
  expect_true("undeclared_var_xyz" %in% rep_bad$missing_variables)
  expect_true("helper_fn_xyz" %in% rep_bad$unexported_functions)
  expect_gte(length(rep_bad$warnings), 3L)
  expect_invisible(print(rep_bad))

  # Supplying explicit globals resolves missing/unexported checks
  clean_globals_fn <- function(x) helper_fn_xyz(x) + undeclared_var_xyz
  environment(clean_globals_fn) <- globalenv()
  rep_fixed <- inspect_job_globals(
    clean_globals_fn,
    globals = list(helper_fn_xyz = function(z) z * 2, undeclared_var_xyz = 5)
  )
  expect_true(rep_fixed$ok)

  # slurm_job_spec warns when estimated payload exceeds warn_bundle_mb
  expect_warning(
    slurm_job_spec(bad_fn, args_list = list(1, 2), warn_bundle_mb = 1.0),
    "estimated staged payload"
  )
})

test_that("SLURM edge-case parsers handle Mc/Mn, stepped arrays, fractional times, and transient SSH backoff", {
  # Memory suffixes: K, M, G, T, Mc, Mn, Gc, GiB, 0, NA, empty
  expect_equal(
    parse_slurm_mem(c("1024K", "2.5G", "0.5T", "100Mc", "200Mn", "2Gc", "1GiB", "0", "0M")),
    c(1, 2560, 524288, 100, 200, 2048, 1024, 0, 0)
  )
  expect_true(all(is.na(parse_slurm_mem(c("", "NA", "bad")))))
  expect_equal(parse_slurm_mem(NULL), numeric(0L))

  # Time formats: MM:SS, HH:MM:SS, D-HH:MM:SS, D-HH:MM, D-HH, MM, fractional seconds
  expect_equal(
    parse_slurm_time(c("05:30", "01:00:00", "1-02:03:04", "2-04:30", "1-06", "15", "00:01:02.5")),
    c(330, 3600, 86400 + 7384, 2 * 86400 + 4 * 3600 + 1800, 86400 + 6 * 3600, 900, 62.5)
  )
  expect_true(all(is.na(parse_slurm_time(c("UNLIMITED", "Partition_Limit", "INVALID", "")))))

  # Stepped & throttled array specs
  expect_equal(parse_slurm_array_spec("1-10:2"), c(1L, 3L, 5L, 7L, 9L))
  expect_equal(parse_slurm_array_spec("1,3,5-9%4"), c(1L, 3L, 5L, 6L, 7L, 8L, 9L))
  expect_equal(parse_slurm_array_spec(""), integer(0L))
  expect_equal(parse_slurm_array_spec(NULL), integer(0L))

  # Edge-case sacct & squeue outputs
  expect_equal(nrow(parse_squeue_output("   \n\n")), 0L)
  expect_equal(nrow(parse_sacct_output("   \n\n")), 0L)
  sq_step <- parse_squeue_output("777_[1-5:2%2]|PENDING|0:00||(Resources)")
  expect_equal(sq_step$chunk_id, c(1L, 3L, 5L))

  sa_edge <- parse_sacct_output(paste(
    "777_1|COMPLETED|00:03:10.5||0:0",
    "777_1.0|COMPLETED|00:03:10.5|250Mc|0:0",
    "777_1.interactive|COMPLETED|00:03:10.5|50M|0:0",
    "777_2|DEADLINE|01:00:00|200Mn|0:0",
    sep = "\n"
  ))
  expect_equal(sa_edge$state, c("COMPLETED", "TIMEOUT"))
  expect_equal(sa_edge$peak_rss_mb, c(250, 200))
  expect_equal(sa_edge$elapsed_sec[[1L]], 190.5)

  # Transient SSH retry with bounded exponential backoff succeeds on attempt 3
  calls <- 0L
  stage_dir <- withr::local_tempdir()
  flaky_runner <- function(cmd, args) {
    calls <<- calls + 1L
    if (cmd == "ssh" && calls <= 2L) {
      return(list(status = 255L, stdout = "", stderr = "Connection reset by peer"))
    }
    if (cmd == "ssh" && grepl("^sbatch ", args[[length(args)]])) {
      return(list(status = 0L, stdout = "88888\n", stderr = ""))
    }
    list(status = 0L, stdout = "", stderr = "")
  }
  ssh_be <- slurm_ssh_backend(
    host = "hpc.example.edu",
    local_stage_dir = stage_dir,
    ssh_max_retries = 2L,
    ssh_retry_base_sec = 0.01,
    ssh_retry_max_sec = 0.05,
    command_runner = flaky_runner
  )
  j_ok <- slurm_submit(ssh_be, function(x) x, list(1), resource_spec(1L), name = "transient_ok")
  expect_equal(j_ok$scheduler_ids, "88888")
  expect_gte(calls, 4L) # 2 failed mkdirs + 1 ok mkdir + scp + sbatch

  # Permanent auth failure fails fast WITHOUT retrying
  perm_calls <- 0L
  perm_runner <- function(cmd, args) {
    perm_calls <<- perm_calls + 1L
    list(status = 255L, stdout = "", stderr = "Permission denied (publickey).")
  }
  ssh_perm <- slurm_ssh_backend(
    host = "hpc.example.edu",
    local_stage_dir = stage_dir,
    ssh_max_retries = 3L,
    ssh_retry_base_sec = 0.01,
    command_runner = perm_runner
  )
  expect_error(
    slurm_submit(ssh_perm, function(x) x, list(1), resource_spec(1L), name = "auth_fail"),
    "Permission denied"
  )
  expect_equal(perm_calls, 1L)
})

test_that("Bundled standalone example scripts exist and parse cleanly", {
  ex1 <- system.file("examples", "01_autopilot_monte_carlo.R", package = "slurmpilot")
  ex2 <- system.file("examples", "02_hpc_packaging_and_lpt.R", package = "slurmpilot")
  expect_true(nzchar(ex1) && file.exists(ex1))
  expect_true(nzchar(ex2) && file.exists(ex2))
  expect_no_error(parse(file = ex1))
  expect_no_error(parse(file = ex2))
})
