test_that("End-to-end pilot -> resources -> MockSlurmBackend submit/wait/collect works", {
  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 2L)

  args <- lapply(1:10, function(i) list(id = i, x = i * 3))
  worker <- function(item) {
    data.frame(id = item$id, val = item$x + offset)
  }

  pilot <- pilot_run(
    fun = worker,
    args_list = args,
    n_pilot = 2L,
    globals = list(offset = 10),
    isolate = TRUE
  )
  res <- estimate_resources(pilot, n_tasks = 10L, max_chunk_size = 3L)
  expect_equal(res$n_chunks, 4L)

  job <- slurm_submit(
    backend = be,
    fun = worker,
    args_list = args,
    resources = res,
    name = "e2e_test",
    globals = list(offset = 10),
    seed = 99L
  )
  expect_s3_class(job, "slurmpilot_job")
  expect_invisible(print(job))

  st <- slurm_wait(job, timeout = 30, poll_interval = 0.05)
  expect_s3_class(st, "slurmpilot_status")
  expect_equal(st$state, "COMPLETED")
  expect_equal(st$n_completed, 4L)
  expect_equal(st$progress, 1)
  expect_true(all(st$chunks$checkpoint_exists))
  expect_invisible(print(st))

  df <- slurm_collect(job, simplify = TRUE)
  expect_s3_class(df, "tbl_df")
  expect_equal(nrow(df), 10L)
  expect_equal(df$id, 1:10)
  expect_equal(df$val, (1:10) * 3 + 10)

  logs <- slurm_logs(job, chunk_id = 1L)
  expect_match(logs$chunk_1$stdout, "Chunk 1 finished with state=COMPLETED", fixed = TRUE)
})

test_that("MockSlurmBackend supports fault injection and surgical retry preserving completed checkpoints", {
  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 2L)

  args <- as.list(1:8)
  res <- resource_spec(n_tasks = 8L, chunk_size = 2L, mem_mb = 512L, time_minutes = 5)

  job <- slurm_submit(
    backend = be,
    fun = function(x) x * x,
    args_list = args,
    resources = res,
    name = "retry_demo",
    fault_injection = list(fail_chunks = 2L, oom_chunks = 4L, fail_once = TRUE)
  )

  st1 <- slurm_wait(job, timeout = 30, poll_interval = 0.05)
  expect_equal(st1$state, "PARTIAL_FAILURE")
  expect_equal(st1$n_completed, 2L)
  expect_equal(st1$n_failed, 1L)
  expect_equal(st1$n_oom, 1L)
  expect_equal(st1$chunks$state, c("COMPLETED", "FAILED", "COMPLETED", "OUT_OF_MEMORY"))

  # Incomplete collect refuses unless allow_partial = TRUE
  expect_error(slurm_collect(job), "chunk checkpoints missing")
  partial <- slurm_collect(job, allow_partial = TRUE)
  expect_equal(partial[[1L]], 1)
  expect_null(partial[[3L]])
  expect_equal(partial[[5L]], 25)

  # Capture checkpoint mtimes for completed chunks 1 and 3
  cp1 <- file.path(job$local_dir, "results", "chunk_0001.rds")
  cp3 <- file.path(job$local_dir, "results", "chunk_0003.rds")
  mtime1 <- file.info(cp1)$mtime
  mtime3 <- file.info(cp3)$mtime

  # Surgical retry with 1.5x memory scale
  job <- slurm_retry(job, mem_multiplier = 1.5)
  expect_equal(job$resources$mem_mb, 768L)
  retry_sbatch <- file.path(job$local_dir, "retry_2.sbatch")
  expect_true(file.exists(retry_sbatch))
  expect_match(paste(readLines(retry_sbatch), collapse = "\n"), "#SBATCH --array=2,4", fixed = TRUE)

  st2 <- slurm_wait(job, timeout = 30, poll_interval = 0.05)
  expect_equal(st2$state, "COMPLETED")
  expect_equal(st2$chunks$attempt, c(1L, 2L, 1L, 2L))

  # Completed chunks 1 and 3 were NEVER overwritten
  expect_equal(file.info(cp1)$mtime, mtime1)
  expect_equal(file.info(cp3)$mtime, mtime3)

  out <- slurm_collect(job, simplify = TRUE)
  expect_equal(out, (1:8)^2)
})

test_that("MockSlurmBackend captures real user errors, live TIMEOUT, live OOM, and cancellation", {
  root <- withr::local_tempdir()

  # 1. Real R error inside worker function
  be_err <- mock_slurm_backend(root_dir = file.path(root, "err"), max_workers = 2L)
  job_err <- slurm_submit(
    backend = be_err,
    fun = function(x) {
      if (x == 3L) stop("singular matrix in task 3")
      x + 1
    },
    args_list = as.list(1:4),
    resources = resource_spec(n_tasks = 4L, chunk_size = 2L),
    name = "real_err"
  )
  st_err <- slurm_wait(job_err, timeout = 20, poll_interval = 0.05)
  expect_equal(st_err$state, "PARTIAL_FAILURE")
  expect_match(st_err$chunks$error_message[[2L]], "singular matrix in task 3")

  # 2. Live enforced walltime TIMEOUT
  be_to <- mock_slurm_backend(root_dir = file.path(root, "to"), max_workers = 1L, time_limit_sec = 0.3)
  job_to <- slurm_submit(
    backend = be_to,
    fun = function(x) {
      Sys.sleep(5)
      x
    },
    args_list = list(1),
    resources = resource_spec(n_tasks = 1L, chunk_size = 1L),
    name = "live_timeout"
  )
  st_to <- slurm_wait(job_to, timeout = 10, poll_interval = 0.05)
  expect_equal(st_to$state, "FAILED")
  expect_equal(st_to$n_timeout, 1L)

  # 3. Live enforced RSS OUT_OF_MEMORY (5 MB limit is below any R process RSS)
  be_oom <- mock_slurm_backend(root_dir = file.path(root, "oom"), max_workers = 1L, mem_limit_mb = 5)
  job_oom <- slurm_submit(
    backend = be_oom,
    fun = function(x) {
      Sys.sleep(1.5)
      x
    },
    args_list = list(1),
    resources = resource_spec(n_tasks = 1L, chunk_size = 1L),
    name = "live_oom"
  )
  st_oom <- slurm_wait(job_oom, timeout = 10, poll_interval = 0.05)
  expect_equal(st_oom$n_oom, 1L)

  # 4. Cancellation of queued + running chunks
  be_can <- mock_slurm_backend(root_dir = file.path(root, "can"), max_workers = 1L, queue_delay = 0.2)
  job_can <- slurm_submit(
    backend = be_can,
    fun = function(x) {
      Sys.sleep(5)
      x
    },
    args_list = as.list(1:3),
    resources = resource_spec(n_tasks = 3L, chunk_size = 1L),
    name = "cancel_me"
  )
  Sys.sleep(0.1)
  st_can <- slurm_cancel(job_can)
  expect_equal(st_can$state, "CANCELLED")
  expect_equal(st_can$n_cancelled, 3L)
})

test_that("slurm_autopilot runs full end-to-end lifecycle with automatic surgical retry", {
  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 2L)

  run <- slurm_autopilot(
    fun = function(x) x * 10,
    args_list = as.list(1:6),
    backend = be,
    n_pilot = 2L,
    max_chunk_size = 2L,
    auto_retry = 1L,
    simplify = TRUE,
    poll_interval = 0.05,
    fault_injection = list(oom_chunks = 2L, fail_once = TRUE)
  )

  expect_s3_class(run, "slurmpilot_autopilot")
  expect_equal(run$status$state, "COMPLETED")
  expect_equal(run$status$chunks$attempt, c(1L, 2L, 1L))
  expect_equal(run$results, (1:6) * 10)
  expect_invisible(print(run))
})
