test_that("SSH/SCP/scancel command builders produce safe expected arguments", {
  ssh_a <- build_ssh_args(
    host = "login.hpc.edu",
    user = "mharris",
    port = 2222L,
    ssh_key = "~/.ssh/hpc_ed25519",
    ssh_options = c("-o", "ServerAliveInterval=60"),
    remote_cmd = "sbatch --parsable /scratch/job/submit.sbatch"
  )
  expect_equal(
    ssh_a,
    c(
      "-o", "BatchMode=yes",
      "-o", "StrictHostKeyChecking=accept-new",
      "-p", "2222",
      "-i", "~/.ssh/hpc_ed25519",
      "-o", "ServerAliveInterval=60",
      "--",
      "mharris@login.hpc.edu",
      "sbatch --parsable /scratch/job/submit.sbatch"
    )
  )

  scp_a <- build_scp_args(
    src = c("payload.rds", "worker.R"),
    dest = "mharris@login.hpc.edu:/scratch/job/",
    port = 2222L,
    recursive = TRUE
  )
  expect_true("-r" %in% scp_a)
  expect_true("-P" %in% scp_a)

  expect_equal(build_scancel_command("987654"), "scancel 987654")
  expect_equal(build_scancel_command("987654", chunks = c(5, 2, 5)), "scancel 987654_2 987654_5")
})

test_that("SLURM sbatch, squeue, and sacct parsers handle realistic HPC outputs", {
  expect_equal(parse_sbatch_output("Submitted batch job 551234\n"), "551234")
  expect_equal(parse_sbatch_output("551234;uconn_hpc\n"), "551234")
  expect_error(parse_sbatch_output("sbatch: error: Invalid partition"), "Unable to parse")

  sq_out <- paste(
    "551234_1|RUNNING|03:45|cn012|None",
    "551234_[2-4,6]|PENDING|0:00||(Resources)",
    sep = "\n"
  )
  sq <- parse_squeue_output(sq_out)
  expect_equal(nrow(sq), 5L)
  expect_equal(sq$chunk_id, c(1L, 2L, 3L, 4L, 6L))
  expect_equal(sq$state, c("RUNNING", "PENDING", "PENDING", "PENDING", "PENDING"))
  expect_equal(sq$elapsed_sec[[1L]], 225)

  sa_out <- paste(
    "551234_1|COMPLETED|00:05:10||0:0",
    "551234_1.batch|COMPLETED|00:05:10|524288K|0:0",
    "551234_1.extern|COMPLETED|00:05:10|1024K|0:0",
    "551234_2|OUT_OF_MEMORY|00:01:20||0:125",
    "551234_2.batch|OUT_OF_MEMORY|00:01:20|2.5G|0:125",
    "551234_3|CANCELLED by 1042|00:00:15||0:15",
    sep = "\n"
  )
  sa <- parse_sacct_output(sa_out)
  expect_equal(nrow(sa), 3L)
  expect_equal(sa$state, c("COMPLETED", "OUT_OF_MEMORY", "CANCELLED"))
  expect_equal(sa$peak_rss_mb, c(512, 2560, NA_real_))
  expect_equal(sa$elapsed_sec, c(310, 80, 15))
})

test_that("SlurmSshBackend full lifecycle contract with mocked command_runner works", {
  stage_dir <- withr::local_tempdir()
  recorded_cmds <- list()
  sbatch_counter <- 0L
  phase <- "initial_partial_fail"

  fake_runner <- function(cmd, args) {
    recorded_cmds[[length(recorded_cmds) + 1L]] <<- list(cmd = cmd, args = args)

    if (cmd == "scp") {
      # When collecting results, populate local results dir with valid checkpoints
      dest <- args[[length(args)]]
      if (dir.exists(dest) && grepl("results", dest, fixed = TRUE)) {
        for (cid in 1:3) {
          tids <- ((cid - 1L) * 2L + 1L):(cid * 2L)
          saveRDS(
            list(
              chunk_id = cid,
              attempt = if (cid == 2L) 2L else 1L,
              task_indices = tids,
              results = lapply(tids, function(ti) list(ok = TRUE, task_index = ti, value = ti * 100, error = NA_character_))
            ),
            file = file.path(dest, sprintf("chunk_%04d.rds", cid))
          )
        }
      }
      return(list(status = 0L, stdout = "", stderr = ""))
    }

    remote_cmd <- args[[length(args)]]

    if (grepl("^sbatch ", remote_cmd)) {
      sbatch_counter <<- sbatch_counter + 1L
      jid <- as.character(9000L + sbatch_counter)
      return(list(status = 0L, stdout = paste0(jid, "\n"), stderr = ""))
    }

    if (grepl("^squeue ", remote_cmd)) {
      return(list(status = 0L, stdout = "", stderr = ""))
    }

    if (grepl("^sacct ", remote_cmd)) {
      if (phase == "initial_partial_fail") {
        out <- paste(
          "9001_1|COMPLETED|00:02:00||0:0",
          "9001_1.batch|COMPLETED|00:02:00|300M|0:0",
          "9001_2|OUT_OF_MEMORY|00:00:45||0:125",
          "9001_2.batch|OUT_OF_MEMORY|00:00:45|1024M|0:125",
          "9001_3|COMPLETED|00:02:10||0:0",
          "9001_3.batch|COMPLETED|00:02:10|320M|0:0",
          sep = "\n"
        )
      } else {
        out <- paste(
          "9001_1|COMPLETED|00:02:00||0:0",
          "9001_1.batch|COMPLETED|00:02:00|300M|0:0",
          "9001_2|OUT_OF_MEMORY|00:00:45||0:125",
          "9001_3|COMPLETED|00:02:10||0:0",
          "9001_3.batch|COMPLETED|00:02:10|320M|0:0",
          "9002_2|COMPLETED|00:02:30||0:0",
          "9002_2.batch|COMPLETED|00:02:30|1400M|0:0",
          sep = "\n"
        )
      }
      return(list(status = 0L, stdout = out, stderr = ""))
    }

    if (grepl("^cat ", remote_cmd)) {
      return(list(status = 0L, stdout = "[slurmpilot] remote log line\n", stderr = ""))
    }

    list(status = 0L, stdout = "", stderr = "")
  }

  ssh_be <- slurm_ssh_backend(
    host = "cluster.uconn.edu",
    user = "mharris",
    remote_dir = "/scratch/mharris/sp",
    local_stage_dir = stage_dir,
    partition = "general",
    container_sif = "/scratch/containers/r_stan.sif",
    modules = c("apptainer"),
    command_runner = fake_runner
  )

  res <- resource_spec(n_tasks = 6L, chunk_size = 2L, mem_mb = 1024L, time_minutes = 10)
  job <- slurm_submit(
    backend = ssh_be,
    fun = function(x) x * 100,
    args_list = as.list(1:6),
    resources = res,
    name = "ssh_contract"
  )
  expect_equal(job$scheduler_ids, "9001")

  # Verify initial status shows chunk 2 OOM
  st1 <- slurm_status(job)
  expect_equal(st1$state, "PARTIAL_FAILURE")
  expect_equal(st1$n_oom, 1L)
  expect_equal(st1$chunks$state, c("COMPLETED", "OUT_OF_MEMORY", "COMPLETED"))

  # Surgical retry bumps --mem and submits ONLY chunk 2 as job 9002
  job <- slurm_retry(job, mem_multiplier = 2.0)
  expect_equal(job$scheduler_ids, c("9001", "9002"))
  retry_script <- paste(readLines(file.path(job$local_dir, "retry_2.sbatch")), collapse = "\n")
  expect_match(retry_script, "#SBATCH --array=2", fixed = TRUE)
  expect_match(retry_script, "#SBATCH --mem=2G", fixed = TRUE)

  # Reconciled status across job 9001 (chunks 1, 3) and 9002 (chunk 2) -> COMPLETED
  phase <- "retried_ok"
  st2 <- slurm_status(job)
  expect_equal(st2$state, "COMPLETED")
  expect_equal(st2$chunks$worker_id, c("9001_1", "9002_2", "9001_3"))
  expect_equal(st2$peak_rss_max_mb, 1400)

  # Logs & collect
  lg <- slurm_logs(job, chunk_id = 2L)
  expect_match(lg$chunk_2$stdout, "remote log line", fixed = TRUE)

  collected <- slurm_collect(job, simplify = TRUE)
  expect_equal(collected, (1:6) * 100)

  # Targeted cancel command emitted cleanly
  slurm_cancel(job, chunks = c(2L))
  scancel_calls <- Filter(
    function(x) x$cmd == "ssh" && grepl("^scancel ", x$args[[length(x$args)]]),
    recorded_cmds
  )
  expect_length(scancel_calls, 1L)
  expect_equal(scancel_calls[[1L]]$args[[length(scancel_calls[[1L]]$args)]], "scancel 9002_2")
})

test_that("SlurmSshBackend dry_run stages local bundle with zero network calls", {
  stage_dir <- withr::local_tempdir()
  called <- FALSE
  ssh_dry <- slurm_ssh_backend(
    host = "cluster.uconn.edu",
    user = "mharris",
    local_stage_dir = stage_dir,
    dry_run = TRUE,
    command_runner = function(cmd, args) {
      called <<- TRUE
      list(status = 0L, stdout = "", stderr = "")
    }
  )
  job <- slurm_submit(
    backend = ssh_dry,
    fun = function(x) x,
    args_list = list(1, 2),
    resources = resource_spec(n_tasks = 2L, chunk_size = 1L),
    name = "dry_test"
  )
  expect_false(called)
  expect_equal(job$scheduler_ids, "DRY_RUN")
  expect_true(file.exists(file.path(job$local_dir, "submit.sbatch")))
  expect_true(file.exists(file.path(job$local_dir, "worker.R")))
  expect_named(job$meta$dry_run_commands, c("mkdir", "scp", "sbatch"))
  expect_equal(slurm_status(job)$state, "PENDING")
})
