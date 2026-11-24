test_that("Multi-stage diamond DAG executes end-to-end on MockSlurmBackend with dynamic upstream passing", {
  root_dir <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root_dir, max_workers = 2L)

  s_root <- slurm_stage(
    name = "generate",
    fun = function(x) x * 2,
    args_list = as.list(1:4),
    resources = resource_spec(4L, chunk_size = 2L),
    seed = 100L
  )
  s_a <- slurm_stage(
    name = "branch_a",
    fun = function(v) v + 10,
    args_from_upstream = function(up) as.list(up$generate),
    depends_on = "generate"
  )
  s_b <- slurm_stage(
    name = "branch_b",
    fun = function(k) sum(.upstream$generate) * k,
    args_list = list(1, 2),
    depends_on = "generate"
  )
  s_sink <- slurm_stage(
    name = "aggregate",
    fun = function(up) list(a_sum = sum(up$branch_a), b_sum = sum(up$branch_b)),
    depends_on = c("branch_a", "branch_b")
  )

  expect_invisible(print(s_root))
  expect_invisible(print(s_a))
  expect_invisible(print(s_sink))

  pipe <- slurm_pipeline(s_root, s_a, s_b, s_sink, name = "diamond_dag")
  expect_s3_class(pipe, "slurmpilot_pipeline")
  expect_equal(pipe$roots, "generate")
  expect_equal(pipe$sinks, "aggregate")
  expect_equal(unname(pipe$levels[c("generate", "branch_a", "branch_b", "aggregate")]), c(1L, 2L, 2L, 3L))
  expect_invisible(print(pipe))

  run <- slurm_pipeline_run(pipe, be, wait = TRUE, poll_interval = 0.05)
  expect_s3_class(run, "slurmpilot_pipeline_run")
  expect_invisible(print(run))

  pst <- slurm_pipeline_status(run)
  expect_s3_class(pst, "slurmpilot_pipeline_status")
  expect_equal(pst$state, "COMPLETED")
  expect_equal(pst$n_completed, 4L)
  expect_equal(pst$progress, 1)

  # Default sink collection: generate = c(2,4,6,8) [sum=20]
  # branch_a = c(12,14,16,18) [sum=60], branch_b = c(20,40) [sum=60]
  sink_out <- slurm_pipeline_collect(run)
  expect_equal(sink_out[[1L]]$a_sum, 60)
  expect_equal(sink_out[[1L]]$b_sum, 60)

  # Named stage collection
  expect_equal(slurm_pipeline_collect(run, stage = "generate", simplify = TRUE), c(2, 4, 6, 8))
  expect_error(slurm_pipeline_collect(run, stage = "nonexistent"), "Unknown pipeline stage")
})

test_that("slurm_pipeline catches cycles, self-loops, unknown deps, and handles multi-sink & failure propagation", {
  # Self-dependency
  expect_error(
    slurm_pipeline(slurm_stage("a", function(x) x, args_list = list(1), depends_on = "a")),
    "Self-dependency"
  )
  # Mutual cycle A <-> B
  expect_error(
    slurm_pipeline(
      slurm_stage("a", function(x) x, args_list = list(1), depends_on = "b"),
      slurm_stage("b", function(x) x, args_list = list(1), depends_on = "a")
    ),
    "Cycle detected"
  )
  # Unknown upstream & duplicates & root missing args
  expect_error(
    slurm_pipeline(slurm_stage("a", function(x) x, args_list = list(1), depends_on = "ghost")),
    "unknown stage"
  )
  expect_error(
    slurm_pipeline(
      slurm_stage("a", function(x) x, args_list = list(1)),
      slurm_stage("a", function(x) x, args_list = list(2))
    ),
    "Duplicate stage"
  )
  expect_error(slurm_stage("root_no_args", function(x) x), "must supply")

  # Failure propagation: afterok skipped, afternotok & afterany execute!
  root_dir <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root_dir, max_workers = 2L)
  pipe_fail <- slurm_pipeline(
    slurm_stage("boom", fun = function(x) stop("intentional fail"), args_list = list(1)),
    slurm_stage("ok_only", fun = function(up) "should_skip", depends_on = "boom", dependency_type = "afterok"),
    slurm_stage("on_err", fun = function(up) "recovered_alert", depends_on = "boom", dependency_type = "afternotok"),
    slurm_stage("always", fun = function(up) "cleanup_ran", depends_on = "boom", dependency_type = "afterany"),
    name = "dep_semantics"
  )
  run_fail <- slurm_pipeline_run(pipe_fail, be, wait = TRUE, poll_interval = 0.05)
  pst <- slurm_pipeline_status(run_fail)
  expect_equal(pst$state, "PARTIAL_FAILURE")
  expect_equal(pst$stages$state[pst$stages$stage == "ok_only"], "SKIPPED")
  expect_equal(pst$stages$state[pst$stages$stage == "on_err"], "COMPLETED")
  expect_equal(pst$stages$state[pst$stages$stage == "always"], "COMPLETED")
  expect_error(slurm_pipeline_collect(run_fail, stage = "ok_only"), "never submitted")

  # Multi-sink collect returns named list
  multi <- slurm_pipeline_collect(run_fail, stage = "on_err", simplify = TRUE)
  expect_equal(multi, "recovered_alert")
})

test_that("SlurmSshBackend emits genuine --dependency=afterok flags for queued cluster DAGs", {
  stage_dir <- withr::local_tempdir()
  sbatch_id <- 5000L
  fake_runner <- function(cmd, args) {
    if (cmd == "ssh" && grepl("^sbatch ", args[[length(args)]])) {
      sbatch_id <<- sbatch_id + 1L
      return(list(status = 0L, stdout = paste0(sbatch_id, "\n"), stderr = ""))
    }
    list(status = 0L, stdout = "", stderr = "")
  }

  ssh_be <- slurm_ssh_backend(
    host = "cluster.example.edu",
    user = "mharris",
    local_stage_dir = stage_dir,
    command_runner = fake_runner
  )

  pipe <- slurm_pipeline(
    slurm_stage("s1", fun = function(x) x, args_list = list(1, 2)),
    slurm_stage("s2", fun = function(x) x, args_list = list(3, 4)),
    slurm_stage("s3", fun = function(x) x, args_list = list(5), depends_on = c("s1", "s2")),
    name = "ssh_dag"
  )

  run <- slurm_pipeline_run(pipe, ssh_be, wait = FALSE)
  expect_equal(run$dependencies_submitted[["s3"]], "afterok:5001:5002")

  s3_script <- paste(readLines(file.path(run$jobs$s3$local_dir, "submit.sbatch")), collapse = "\n")
  expect_match(s3_script, "#SBATCH --dependency=afterok:5001:5002", fixed = TRUE)

  # Dependency injection blocked strictly
  res <- resource_spec(2L)
  expect_error(render_sbatch_script("ok", res, "/scratch/w", dependency = "afterok:123;id"), "dependency")
  expect_error(render_sbatch_script("ok", res, "/scratch/w", dependency = "afterok:123\nwhoami"), "control or newline")
})

test_that("slurm_efficiency_report classifies over/under/imbalanced/efficient jobs and recommends tightened specs", {
  # 1. Over-provisioned real MockSlurmBackend job
  root_dir <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root_dir, max_workers = 2L)
  res_big <- resource_spec(n_tasks = 4L, chunk_size = 2L, mem_mb = 4096L, time_minutes = 60)
  job <- slurm_submit(be, function(x) mean(rnorm(100)), as.list(1:4), resources = res_big, name = "overprov")
  slurm_wait(job, timeout = 20, poll_interval = 0.05)

  eff_over <- slurm_efficiency_report(job)
  expect_s3_class(eff_over, "slurmpilot_efficiency")
  expect_equal(eff_over$classification, "over_provisioned")
  expect_gt(eff_over$metrics$mem_waste_pct, 50)
  expect_gt(eff_over$metrics$time_slack_pct, 60)
  expect_lt(eff_over$recommended_resources$mem_mb, 4096L)
  expect_lt(eff_over$recommended_resources$time_sec, 3600L)
  expect_invisible(print(eff_over))

  # Plot base and ggplot2
  tmp_pdf <- withr::local_tempfile(fileext = ".pdf")
  grDevices::pdf(tmp_pdf)
  on.exit(grDevices::dev.off(), add = TRUE)
  expect_invisible(plot(eff_over, engine = "base"))
  if (requireNamespace("ggplot2", quietly = TRUE)) {
    expect_s3_class(plot(eff_over, engine = "ggplot2"), "ggplot")
  }

  # 2. Under-provisioned sacct table with OOM and TIMEOUT
  sa_under <- parse_sacct_output(paste(
    "200_1|OUT_OF_MEMORY|00:05:00|2048M|0:125",
    "200_2|TIMEOUT|00:15:00|1024M|0:0",
    sep = "\n"
  ))
  res_small <- resource_spec(4L, 2L, mem_mb = 2048L, time_minutes = 15)
  eff_under <- slurm_efficiency_report(sa_under, resources = res_small)
  expect_equal(eff_under$classification, "under_provisioned")
  expect_gt(eff_under$recommended_resources$mem_mb, 2048L)
  expect_gt(eff_under$recommended_resources$time_sec, 900L)

  # 3. Imbalanced sacct table (straggler ratio >= 2)
  sa_imb <- parse_sacct_output(paste(
    "300_1|COMPLETED|00:02:00|700M|0:0",
    "300_2|COMPLETED|00:02:00|720M|0:0",
    "300_3|COMPLETED|00:02:00|710M|0:0",
    "300_4|COMPLETED|00:12:00|750M|0:0",
    sep = "\n"
  ))
  eff_imb <- slurm_efficiency_report(sa_imb, resources = resource_spec(8L, 2L, mem_mb = 1024L, time_minutes = 15))
  expect_equal(eff_imb$classification, "imbalanced")
  expect_gte(eff_imb$metrics$straggler_ratio, 2.0)
  expect_true(any(grepl("lpt", eff_imb$recommendations, fixed = TRUE)))

  # 4. Well-calibrated efficient job
  sa_eff <- parse_sacct_output(paste(
    "400_1|COMPLETED|00:10:00|750M|0:0",
    "400_2|COMPLETED|00:11:00|780M|0:0",
    sep = "\n"
  ))
  eff_ok <- slurm_efficiency_report(sa_eff, resources = resource_spec(4L, 2L, mem_mb = 1024L, time_minutes = 15))
  expect_equal(eff_ok$classification, "efficient")

  # Missing resources errors cleanly
  expect_error(slurm_efficiency_report(sa_eff), "resources")
})

test_that("use_rcapsule_container validates paths, binds, and attaches duck-typed rcapsule metadata cleanly", {
  spec <- slurm_job_spec(function(x) x + 1, list(1, 2), resources = resource_spec(2L))

  # Duck-typed rcapsule manifest with nested targets$apptainer + manifest$content_digest
  rcap_obj <- structure(
    list(
      targets = list(
        apptainer = list(
          sif_path = "/scratch/containers/study_v1.sif",
          def_path = "/scratch/containers/study_v1.def",
          binds = c("/scratch/input:/input:ro")
        )
      ),
      manifest = list(
        content_digest = "sha256:abcdef0123456789",
        r_version = "4.4.1"
      )
    ),
    class = "rcapsule"
  )

  spec2 <- use_rcapsule_container(spec, rcap_obj, binds = c("/scratch/out:/out:rw"))
  expect_equal(spec2$container_sif, "/scratch/containers/study_v1.sif")
  expect_equal(spec2$container_binds, c("/scratch/input:/input:ro", "/scratch/out:/out:rw"))
  expect_equal(spec2$env_vars$SLURMPILOT_CONTAINER_DIGEST, "sha256:abcdef0123456789")
  expect_equal(spec2$container_meta$source, "rcapsule")
  expect_invisible(print(spec2$container_meta))

  # Staging via SlurmSshBackend(dry_run = TRUE) includes binds + provenance env var
  ssh_be <- slurm_ssh_backend("hpc.example.edu", local_stage_dir = withr::local_tempdir(), dry_run = TRUE)
  dry_job <- slurm_submit(ssh_be, spec2)
  sb_txt <- paste(readLines(file.path(dry_job$local_dir, "submit.sbatch")), collapse = "\n")
  expect_match(sb_txt, "/scratch/input:/input:ro", fixed = TRUE)
  expect_match(sb_txt, "SLURMPILOT_CONTAINER_DIGEST='sha256:abcdef0123456789'", fixed = TRUE)

  # Standalone mode with .def path, .sif path, and slurmpilot_apptainer_def
  c_def <- use_rcapsule_container(container = "/opt/hpc/r_env.def")
  expect_equal(c_def$sif_path, "/opt/hpc/r_env.sif")
  c_sp <- use_rcapsule_container(container = build_apptainer_def(scan_project_env(extra_packages = "lme4"), r_version = "4.4.1"))
  expect_equal(c_sp$source, "slurmpilot_apptainer_def")

  # check_exists works on real temp file & rejects missing
  tmp_sif <- withr::local_tempfile(fileext = ".sif")
  writeLines("dummy", tmp_sif)
  expect_equal(use_rcapsule_container(container = tmp_sif, check_exists = TRUE)$sif_path, tmp_sif)
  expect_error(use_rcapsule_container(container = "/nonexistent/img.sif", check_exists = TRUE), "not found")

  # Injection / traversal guards
  expect_error(use_rcapsule_container(container = "/scratch/../etc/passwd.sif"), "Path traversal")
  expect_error(use_rcapsule_container(container = "/scratch/bad.txt"), "must end with")
  expect_error(use_rcapsule_container(container = list(sif_path = "/opt/a.sif", content_digest = "bad;id")), "Invalid container")
})

test_that("covr-audited edge cases and latent bug fixes behave deterministically", {
  # 1. Empty/whitespace .sha256 sidecar no longer crashes verify_checkpoint()
  tmp_rds <- withr::local_tempfile(fileext = ".rds")
  saveRDS(list(chunk_id = 1L, results = list()), tmp_rds)
  writeLines("   ", paste0(tmp_rds, ".sha256"))
  chk_blank <- verify_checkpoint(tmp_rds)
  expect_false(chk_blank$ok)
  expect_match(chk_blank$reason, "SHA-256 sidecar mismatch")

  # Missing file, missing required sidecar, expected digest mismatch, corrupt RDS
  expect_false(verify_checkpoint(file.path(tempdir(), "does_not_exist_999.rds"))$ok)
  unlink(paste0(tmp_rds, ".sha256"))
  expect_false(verify_checkpoint(tmp_rds, require_sidecar = TRUE)$ok)
  expect_false(verify_checkpoint(tmp_rds, expected_sha256 = paste(rep("0", 64), collapse = ""))$ok)
  writeLines("not-an-rds-file", tmp_rds)
  expect_false(verify_checkpoint(tmp_rds)$ok)

  # 2. sacct & squeue skip header rows and fold .batch even when .batch precedes parent row
  sa_hdr <- parse_sacct_output(paste(
    "JobID|State|Elapsed|MaxRSS|ExitCode",
    "555_1.batch|COMPLETED|00:01:30|512M|0:0",
    "555_1|COMPLETED|00:01:30||0:0",
    sep = "\n"
  ))
  expect_equal(nrow(sa_hdr), 1L)
  expect_equal(sa_hdr$peak_rss_mb, 512)
  sq_hdr <- parse_squeue_output("JOBID|STATE|TIME|NODELIST|REASON\n555_1|RUNNING|00:10|n1|None")
  expect_equal(nrow(sq_hdr), 1L)

  # 3. SlurmBackend abstract base class methods & cleanup
  base_be <- SlurmBackend$new()
  expect_invisible(print(base_be))
  expect_error(base_be$submit(NULL), "must be implemented")
  expect_error(base_be$status(NULL), "must be implemented")
  expect_error(base_be$retry(NULL), "must be implemented")
  expect_error(base_be$cancel(NULL), "must be implemented")
  expect_error(base_be$logs(NULL), "must be implemented")
  expect_error(base_be$collect(NULL), "must be implemented")

  # 4. MockSlurmBackend set_fault_injection, retry preserves container_sif, continue_on_error partial errors
  root_dir <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root_dir, max_workers = 1L)
  be$set_fault_injection(fail_chunks = 1L, fail_once = TRUE)
  sp <- slurm_job_spec(
    fun = function(x) {
      if (x == 2L) stop("task2 err")
      x * 5
    },
    args_list = list(1, 2),
    resources = resource_spec(2L, chunk_size = 2L),
    continue_on_error = TRUE,
    container_sif = "/opt/hpc/test.sif",
    modules = c("apptainer")
  )
  j <- slurm_submit(be, sp)
  slurm_wait(j, timeout = 20, poll_interval = 0.05)
  j <- slurm_retry(j, adaptive = FALSE)
  r_sbatch <- paste(readLines(file.path(j$local_dir, "retry_2.sbatch")), collapse = "\n")
  expect_match(r_sbatch, "/opt/hpc/test.sif", fixed = TRUE)
  expect_match(r_sbatch, "module load apptainer", fixed = TRUE)
  slurm_wait(j, timeout = 20, poll_interval = 0.05)
  expect_error(slurm_collect(j, allow_partial = FALSE), "failed")
  part <- slurm_collect(j, allow_partial = TRUE)
  expect_equal(part[[1L]], 5)
  expect_s3_class(part[[2L]], "slurmpilot_task_error")

  # Cleanup removes job workspace cleanly
  expect_true(dir.exists(j$local_dir))
  be$cleanup(j)
  expect_false(dir.exists(j$local_dir))
})

test_that("mod_hpc_monitor_server renders logs and protects completed results against accidental retry click", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not_installed("htmltools")

  root_dir <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root_dir, max_workers = 1L)
  job <- slurm_submit(be, function(x) x + 1, list(1, 2), resources = resource_spec(2L, chunk_size = 2L))
  slurm_wait(job, timeout = 20, poll_interval = 0.05)

  job_rv <- shiny::reactiveVal(job)
  shiny::testServer(
    mod_hpc_monitor_server,
    args = list(job = job_rv, poll_ms = 5000L, auto_collect = TRUE, simplify = TRUE),
    {
      session$flushReact()
      expect_equal(session$returned$results(), c(2, 3))
      session$setInputs(log_chunk = "1")
      expect_match(output$chunk_log_text, "STDOUT \\(chunk 1\\)")

      # Clicking retry_failed on already-COMPLETED job preserves results()!
      session$setInputs(retry_failed = 1L)
      expect_equal(session$returned$results(), c(2, 3))
    }
  )
})
