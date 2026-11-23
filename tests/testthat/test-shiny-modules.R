test_that("Shiny UI modules render bslib cards cleanly", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not_installed("htmltools")

  ui_sub <- mod_hpc_submit_ui("sub", show_fault_toggle = TRUE)
  html_sub <- as.character(ui_sub)
  expect_match(html_sub, "sub-run_pilot", fixed = TRUE)
  expect_match(html_sub, "sub-submit_job", fixed = TRUE)
  expect_match(html_sub, "sub-inject_fault", fixed = TRUE)

  ui_mon <- mod_hpc_monitor_ui("mon")
  html_mon <- as.character(ui_mon)
  expect_match(html_mon, "mon-retry_failed", fixed = TRUE)
  expect_match(html_mon, "mon-cancel_job", fixed = TRUE)
  expect_match(html_mon, "mon-toggle_poll", fixed = TRUE)
  expect_match(html_mon, "mon-chunk_table", fixed = TRUE)
})

test_that("mod_hpc_submit_server pilots and submits jobs cleanly via testServer", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not_installed("htmltools")

  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 2L)

  shiny::testServer(
    mod_hpc_submit_server,
    args = list(
      backend = be,
      fun = function(x) x * 2,
      args_builder = function(n) as.list(seq_len(n)),
      async_pilot = FALSE
    ),
    {
      session$setInputs(
        job_name = "shiny_test",
        n_tasks = 6L,
        n_pilot = 2L,
        max_chunk_size = 3L,
        cpus_per_task = 1L,
        mem_safety = 1.35,
        time_safety = 1.50,
        inject_fault = FALSE
      )
      expect_null(session$returned$pilot())
      expect_null(session$returned$job())

      # Run micro-pilot
      session$setInputs(run_pilot = 1L)
      p <- session$returned$pilot()
      res <- session$returned$resources()
      expect_s3_class(p, "slurmpilot_pilot")
      expect_equal(p$summary$n_ok, 2L)
      expect_s3_class(res, "slurmpilot_resources")
      expect_equal(res$n_chunks, 2L)

      # Submit job
      session$setInputs(submit_job = 1L)
      job <- session$returned$job()
      expect_s3_class(job, "slurmpilot_job")

      st <- slurm_wait(job, timeout = 20, poll_interval = 0.05)
      expect_equal(st$state, "COMPLETED")
      expect_equal(slurm_collect(job, simplify = TRUE), (1:6) * 2)
    }
  )
})

test_that("mod_hpc_monitor_server tracks status, pauses polling, retries failures, and collects results", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not_installed("htmltools")

  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 2L)

  job <- slurm_submit(
    backend = be,
    fun = function(x) x + 5,
    args_list = as.list(1:6),
    resources = resource_spec(n_tasks = 6L, chunk_size = 2L, mem_mb = 512L),
    name = "mon_test",
    fault_injection = list(fail_chunks = 2L, fail_once = TRUE)
  )
  # Let initial run reach PARTIAL_FAILURE deterministically
  st_init <- slurm_wait(job, timeout = 20, poll_interval = 0.05)
  expect_equal(st_init$state, "PARTIAL_FAILURE")

  job_reactive <- shiny::reactiveVal(job)

  shiny::testServer(
    mod_hpc_monitor_server,
    args = list(
      job = job_reactive,
      poll_ms = 5000L,
      auto_collect = TRUE,
      simplify = TRUE
    ),
    {
      session$flushReact()
      st <- session$returned$status()
      expect_equal(st$state, "PARTIAL_FAILURE")
      expect_equal(output$kpi_state, "PARTIAL_FAILURE")
      expect_equal(output$kpi_progress, "2 / 3")
      expect_null(session$returned$results())

      # Toggle polling pause / resume
      expect_true(session$returned$is_polling())
      session$setInputs(toggle_poll = 1L)
      expect_false(session$returned$is_polling())
      session$setInputs(toggle_poll = 2L)
      expect_true(session$returned$is_polling())

      # Retry failed chunk with memory bump
      session$setInputs(bump_mem = TRUE, retry_failed = 1L)
      j_retried <- session$returned$job()
      expect_equal(j_retried$resources$mem_mb, 768L)

      # Wait for retried chunk to complete, then trigger collect
      st_done <- slurm_wait(j_retried, timeout = 20, poll_interval = 0.05)
      expect_equal(st_done$state, "COMPLETED")

      session$setInputs(collect_btn = 1L)
      expect_equal(session$returned$results(), (1:6) + 5)
      expect_equal(output$kpi_state, "COMPLETED")
    }
  )
})

test_that("mod_hpc_submit_server runs non-blocking async_pilot = TRUE cleanly", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not_installed("htmltools")

  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 2L)

  shiny::testServer(
    mod_hpc_submit_server,
    args = list(
      backend = be,
      fun = function(x) x + 1,
      args_builder = function(n) as.list(seq_len(n)),
      poll_ms = 50L,
      async_pilot = TRUE
    ),
    {
      session$setInputs(
        job_name = "async_pilot_test",
        n_tasks = 4L,
        n_pilot = 2L,
        max_chunk_size = 2L,
        cpus_per_task = 1L,
        mem_safety = 1.35,
        time_safety = 1.50
      )
      session$setInputs(run_pilot = 1L)
      expect_true(session$returned$is_piloting())

      # Advance reactive clock until background callr pilot completes
      for (step in seq_len(60L)) {
        Sys.sleep(0.08)
        session$elapse(80)
        if (!isTRUE(session$returned$is_piloting())) break
      }

      expect_false(session$returned$is_piloting())
      p <- session$returned$pilot()
      expect_s3_class(p, "slurmpilot_pilot")
      expect_equal(p$summary$n_ok, 2L)
      expect_s3_class(session$returned$resources(), "slurmpilot_resources")
    }
  )
})

test_that("mod_hpc_monitor_server cancels active jobs cleanly via testServer", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not_installed("htmltools")

  root <- withr::local_tempdir()
  be <- mock_slurm_backend(root_dir = root, max_workers = 1L, queue_delay = 0.2)

  job <- slurm_submit(
    backend = be,
    fun = function(x) {
      Sys.sleep(5)
      x
    },
    args_list = list(1, 2),
    resources = resource_spec(n_tasks = 2L, chunk_size = 1L),
    name = "mon_cancel"
  )

  job_rv <- shiny::reactiveVal(job)
  shiny::testServer(
    mod_hpc_monitor_server,
    args = list(job = job_rv, poll_ms = 5000L),
    {
      session$flushReact()
      session$setInputs(cancel_job = 1L)
      st <- session$returned$status()
      expect_equal(st$state, "CANCELLED")
      expect_equal(st$n_cancelled, 2L)
    }
  )
})

test_that("Bundled demo Shiny app file exists and parses cleanly", {
  app_path <- system.file("shiny", "demo", "app.R", package = "slurmpilot")
  expect_true(nzchar(app_path))
  expect_true(file.exists(app_path))
  expect_no_error(parse(file = app_path))
})
