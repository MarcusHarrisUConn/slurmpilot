# Non-blocking Shiny micro-pilot & HPC job submission module

sp_check_shiny_deps <- function() {
  rlang::check_installed(
    c("shiny", "bslib", "htmltools"),
    reason = "to use slurmpilot Shiny modules"
  )
}

#' Shiny UI Module for Micro-Pilot Auto-Sizing and HPC Job Submission
#'
#' Provides a drop-in `bslib` card UI for configuring workload size, launching a
#' non-blocking empirical micro-pilot, inspecting auto-sized SLURM resource
#' recommendations (`--array`, `--mem`, `--time`, `--cpus-per-task`), and
#' submitting array jobs to any [SlurmBackend].
#'
#' @param id Character module namespace ID.
#' @param title Card header title. Default `"HPC Micro-Pilot & Submission"`.
#' @param default_n_tasks Default total number of tasks. Default `20L`.
#' @param default_n_pilot Default number of micro-pilot replications. Default
#'   `3L`.
#' @param default_chunk_size Default maximum tasks per chunk. Default `4L`.
#' @param default_cpus Default CPUs per array task. Default `1L`.
#' @param default_job_name Default SLURM job name. Default `"slurmpilot_study"`.
#' @param show_fault_toggle Logical; if `TRUE`, shows a checkbox to inject a
#'   recoverable single-chunk failure when using [MockSlurmBackend] (useful for
#'   interactive demos of surgical retry). Default `FALSE`.
#'
#' @return A `bslib` card UI element.
#' @seealso [mod_hpc_submit_server()], [mod_hpc_monitor_ui()]
#' @export
#' @examples
#' if (requireNamespace("shiny", quietly = TRUE) &&
#'     requireNamespace("bslib", quietly = TRUE)) {
#'   ui <- mod_hpc_submit_ui("hpc_sub", default_n_tasks = 12L)
#'   inherits(ui, "shiny.tag")
#' }
mod_hpc_submit_ui <- function(
  id,
  title = "HPC Micro-Pilot & Submission",
  default_n_tasks = 20L,
  default_n_pilot = 3L,
  default_chunk_size = 4L,
  default_cpus = 1L,
  default_job_name = "slurmpilot_study",
  show_fault_toggle = FALSE
) {
  sp_check_shiny_deps()
  ns <- shiny::NS(id)

  controls <- list(
    bslib::layout_column_wrap(
      width = 1 / 3,
      shiny::textInput(ns("job_name"), "Job Name", value = default_job_name),
      shiny::numericInput(ns("n_tasks"), "Total Tasks", value = default_n_tasks, min = 1L, step = 1L),
      shiny::numericInput(ns("n_pilot"), "Pilot Sample Size", value = default_n_pilot, min = 1L, max = 20L, step = 1L)
    ),
    bslib::layout_column_wrap(
      width = 1 / 4,
      shiny::numericInput(ns("max_chunk_size"), "Max Tasks / Chunk", value = default_chunk_size, min = 1L, step = 1L),
      shiny::numericInput(ns("cpus_per_task"), "CPUs / Task", value = default_cpus, min = 1L, max = 64L, step = 1L),
      shiny::numericInput(ns("mem_safety"), "Mem Safety (x)", value = 1.35, min = 1.0, max = 5.0, step = 0.05),
      shiny::numericInput(ns("time_safety"), "Time Safety (x)", value = 1.50, min = 1.0, max = 5.0, step = 0.1)
    )
  )

  if (isTRUE(show_fault_toggle)) {
    controls <- c(
      controls,
      list(
        shiny::checkboxInput(
          ns("inject_fault"),
          "Simulate recoverable failure on chunk #2 (demo surgical retry)",
          value = FALSE
        )
      )
    )
  }

  bslib::card(
    bslib::card_header(
      htmltools::div(
        class = "d-flex justify-content-between align-items-center",
        htmltools::span(title),
        shiny::uiOutput(ns("pilot_status_badge"), inline = TRUE)
      )
    ),
    bslib::card_body(
      controls,
      htmltools::div(
        class = "d-flex flex-wrap gap-2 my-2",
        shiny::actionButton(
          ns("run_pilot"),
          "1. Run Micro-Pilot",
          class = "btn-outline-primary"
        ),
        shiny::actionButton(
          ns("submit_job"),
          "2. Submit Array Job",
          class = "btn-primary"
        )
      ),
      shiny::uiOutput(ns("pilot_summary"))
    )
  )
}

#' Shiny Server Module for Non-Blocking Micro-Pilot and HPC Submission
#'
#' Runs micro-pilot trials asynchronously in background OS child processes
#' polled via [shiny::reactiveTimer()] so the Shiny session remains 100%
#' responsive, estimates optimal SLURM flags via [estimate_resources()], and
#' submits jobs to `backend` via [slurm_submit()].
#'
#' @param id Character module namespace ID matching [mod_hpc_submit_ui()].
#' @param backend A [SlurmBackend] object (or a reactive returning one).
#' @param fun Worker function `fun(arg)` (or a reactive returning one).
#' @param args_builder Function `function(n_tasks)` returning an `args_list` of
#'   length `n_tasks` (or a reactive returning such a function).
#' @param packages Character vector of worker packages (or reactive).
#' @param globals Named list of worker globals (or reactive).
#' @param seed Optional integer base seed (or reactive).
#' @param poll_ms Polling interval in milliseconds for non-blocking background
#'   micro-pilot progress. Default `150L`.
#' @param async_pilot Logical; if `TRUE` (default), runs micro-pilot trials in
#'   non-blocking background `callr::r_bg` processes driven by `reactiveTimer`.
#'   Set `FALSE` only for synchronous unit testing.
#'
#' @return A named list of reactives:
#'   - `job`: latest submitted `slurmpilot_job` handle (or `NULL`).
#'   - `pilot`: latest `slurmpilot_pilot` result (or `NULL`).
#'   - `resources`: latest `slurmpilot_resources` plan (or `NULL`).
#'   - `is_piloting`: logical reactive indicating an active background pilot.
#'
#' @seealso [mod_hpc_submit_ui()], [mod_hpc_monitor_server()]
#' @export
#' @examples
#' \donttest{
#' if (interactive() && requireNamespace("shiny", quietly = TRUE) &&
#'     requireNamespace("bslib", quietly = TRUE)) {
#'   ui <- bslib::page_fluid(mod_hpc_submit_ui("sub"))
#'   server <- function(input, output, session) {
#'     be <- mock_slurm_backend(max_workers = 2L)
#'     mod_hpc_submit_server(
#'       "sub",
#'       backend = be,
#'       fun = function(x) x^2,
#'       args_builder = function(n) as.list(seq_len(n))
#'     )
#'   }
#'   shiny::shinyApp(ui, server)
#' }
#' }
mod_hpc_submit_server <- function(
  id,
  backend,
  fun,
  args_builder,
  packages = character(),
  globals = list(),
  seed = 101L,
  poll_ms = 150L,
  async_pilot = TRUE
) {
  sp_check_shiny_deps()
  poll_ms <- sp_clamp_int(poll_ms, default = 150L, lower = 50L, upper = 60000L)

  resolve_val <- function(x) {
    if (shiny::is.reactive(x)) x() else x
  }

  shiny::moduleServer(id, function(input, output, session) {
    job_rv <- shiny::reactiveVal(NULL)
    pilot_rv <- shiny::reactiveVal(NULL)
    resources_rv <- shiny::reactiveVal(NULL)
    is_piloting_rv <- shiny::reactiveVal(FALSE)
    pilot_msg_rv <- shiny::reactiveVal("Ready to profile workload.")

    # Non-blocking background pilot state machine
    pilot_state <- new.env(parent = emptyenv())
    pilot_state$active <- FALSE
    pilot_state$proc <- NULL
    pilot_state$tmp_dir <- NULL
    pilot_state$indices <- integer()
    pilot_state$current_k <- 0L
    pilot_state$rows <- list()
    pilot_state$rss_samples <- numeric()
    pilot_state$t_spawn_wall <- NA_real_
    pilot_state$t_spawn_mono <- NA_real_
    pilot_state$params <- list()

    cleanup_pilot_state <- function() {
      if (!is.null(pilot_state$proc)) {
        sp_kill_and_reap(pilot_state$proc)
        pilot_state$proc <- NULL
      }
      if (!is.null(pilot_state$tmp_dir) && dir.exists(pilot_state$tmp_dir)) {
        unlink(pilot_state$tmp_dir, recursive = TRUE, force = TRUE)
      }
      pilot_state$tmp_dir <- NULL
      pilot_state$active <- FALSE
      is_piloting_rv(FALSE)
    }

    session$onSessionEnded(function() {
      cleanup_pilot_state()
    })

    spawn_next_pilot_trial <- function() {
      k <- pilot_state$current_k + 1L
      pilot_state$current_k <- k
      task_idx <- pilot_state$indices[[k]]
      p <- pilot_state$params
      task_seed <- if (!is.null(p$seed)) as.integer(p$seed + task_idx) else NULL

      payload_path <- file.path(pilot_state$tmp_dir, sprintf("payload_%03d.rds", k))
      saveRDS(
        list(
          fun = p$fun,
          arg = p$args_list[[task_idx]],
          packages = p$packages,
          globals = p$globals,
          task_seed = p$seed,
          task_index = task_idx,
          cpus_per_task = p$cpus_per_task
        ),
        file = payload_path
      )

      pilot_state$rss_samples <- numeric(0L)
      pilot_state$t_spawn_wall <- as.numeric(Sys.time())
      pilot_state$t_spawn_mono <- proc.time()[["elapsed"]]
      pilot_state$proc <- callr::r_bg(
        func = sp_pilot_child_runner,
        args = list(payload_path = payload_path),
        supervise = FALSE
      )
      pilot_msg_rv(sprintf("Profiling micro-pilot trial %d / %d (task #%d)...", k, length(pilot_state$indices), task_idx))
    }

    finalize_pilot <- function() {
      p <- pilot_state$params
      trials <- do.call(rbind, pilot_state$rows)
      summary_stats <- sp_summarize_pilot_trials(trials)
      pilot_obj <- structure(
        list(
          trials = trials,
          summary = summary_stats,
          meta = list(
            n_pilot = length(pilot_state$indices),
            n_total_hint = length(p$args_list),
            cpus_per_task = p$cpus_per_task,
            packages = p$packages,
            sample_method = "stratified",
            isolate = TRUE,
            sample_interval = poll_ms / 1000,
            timestamp = sp_timestamp(),
            r_version = as.character(getRversion()),
            platform = R.version$platform,
            seed = p$seed
          )
        ),
        class = "slurmpilot_pilot"
      )

      cleanup_pilot_state()
      pilot_rv(pilot_obj)

      if (pilot_obj$summary$n_ok > 0L) {
        res <- estimate_resources(
          pilot = pilot_obj,
          n_tasks = p$n_tasks,
          max_chunk_size = p$max_chunk_size,
          mem_safety = p$mem_safety,
          time_safety = p$time_safety,
          cpus_per_task = p$cpus_per_task
        )
        resources_rv(res)
        pilot_msg_rv("Micro-pilot complete. Resource plan updated.")
      } else {
        pilot_msg_rv("Micro-pilot failed across all trials. Check worker function.")
      }
    }

    pilot_timer <- shiny::reactiveTimer(poll_ms, session)

    shiny::observe({
      pilot_timer()
      if (!isTRUE(pilot_state$active) || is.null(pilot_state$proc)) {
        return()
      }

      proc <- pilot_state$proc
      if (proc$is_alive()) {
        rss <- sp_process_tree_rss_mb(proc$get_pid())
        if (!is.na(rss)) {
          pilot_state$rss_samples <- c(pilot_state$rss_samples, rss)
        }
        return()
      }

      # Trial finished
      k <- pilot_state$current_k
      task_idx <- pilot_state$indices[[k]]
      wall_sec <- max(0, proc.time()[["elapsed"]] - pilot_state$t_spawn_mono)
      child_res <- tryCatch(
        proc$get_result(),
        error = function(e) {
          list(
            status = "FAILED",
            error = conditionMessage(e),
            t_start_wall = pilot_state$t_spawn_wall,
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

      all_rss <- c(pilot_state$rss_samples, child_res$baseline_rss_mb, child_res$post_rss_mb)
      all_rss <- all_rss[!is.na(all_rss)]
      peak_rss <- if (length(all_rss) > 0L) max(all_rss) else NA_real_
      base_rss <- child_res$baseline_rss_mb
      if (is.na(base_rss) && length(pilot_state$rss_samples) > 0L) {
        base_rss <- pilot_state$rss_samples[[1L]]
      }
      net_rss <- if (!is.na(peak_rss) && !is.na(base_rss)) max(0, peak_rss - base_rss) else NA_real_
      startup_sec <- max(0, child_res$t_start_wall - pilot_state$t_spawn_wall)
      if (!is.na(child_res$exec_sec) && startup_sec > wall_sec) {
        startup_sec <- max(0, wall_sec - child_res$exec_sec)
      }

      pilot_state$rows[[k]] <- tibble::tibble(
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
        n_samples = as.integer(length(pilot_state$rss_samples)),
        result_size_bytes = child_res$result_size_bytes,
        error = as.character(child_res$error)
      )
      pilot_state$proc <- NULL

      if (k < length(pilot_state$indices)) {
        spawn_next_pilot_trial()
      } else {
        finalize_pilot()
      }
    })

    shiny::observeEvent(input$run_pilot, {
      if (isTRUE(pilot_state$active)) {
        return()
      }

      n_tasks <- sp_clamp_int(input$n_tasks, default = 10L, lower = 1L, upper = 1000000L)
      n_pilot <- sp_clamp_int(input$n_pilot, default = 3L, lower = 1L, upper = min(n_tasks, 50L))
      max_chunk <- sp_clamp_int(input$max_chunk_size, default = 4L, lower = 1L, upper = n_tasks)
      cpus <- sp_clamp_int(input$cpus_per_task, default = 1L, lower = 1L, upper = 256L)
      mem_s <- sp_clamp_num(input$mem_safety, default = 1.35, lower = 1.0, upper = 10.0)
      time_s <- sp_clamp_num(input$time_safety, default = 1.50, lower = 1.0, upper = 10.0)

      builder <- resolve_val(args_builder)
      cur_args <- builder(n_tasks)
      cur_fun <- resolve_val(fun)
      cur_pkgs <- resolve_val(packages)
      cur_globals <- resolve_val(globals)
      cur_seed <- resolve_val(seed)

      if (!isTRUE(async_pilot)) {
        is_piloting_rv(TRUE)
        p_obj <- pilot_run(
          fun = cur_fun,
          args_list = cur_args,
          n_pilot = n_pilot,
          sample_method = "stratified",
          cpus_per_task = cpus,
          seed = cur_seed,
          packages = cur_pkgs,
          globals = cur_globals,
          isolate = TRUE
        )
        pilot_rv(p_obj)
        if (p_obj$summary$n_ok > 0L) {
          res <- estimate_resources(
            pilot = p_obj,
            n_tasks = n_tasks,
            max_chunk_size = max_chunk,
            mem_safety = mem_s,
            time_safety = time_s,
            cpus_per_task = cpus
          )
          resources_rv(res)
          pilot_msg_rv("Micro-pilot complete. Resource plan updated.")
        }
        is_piloting_rv(FALSE)
        return()
      }

      tmp_dir <- tempfile("slurmpilot_shiny_pilot_")
      dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
      pilot_state$tmp_dir <- tmp_dir
      pilot_state$indices <- sp_select_pilot_indices(length(cur_args), n_pilot, "stratified", seed = cur_seed)
      pilot_state$current_k <- 0L
      pilot_state$rows <- vector("list", length(pilot_state$indices))
      pilot_state$params <- list(
        fun = cur_fun,
        args_list = cur_args,
        n_tasks = n_tasks,
        max_chunk_size = max_chunk,
        cpus_per_task = cpus,
        mem_safety = mem_s,
        time_safety = time_s,
        packages = cur_pkgs,
        globals = cur_globals,
        seed = cur_seed
      )
      pilot_state$active <- TRUE
      is_piloting_rv(TRUE)
      spawn_next_pilot_trial()
    })

    shiny::observeEvent(input$submit_job, {
      n_tasks <- sp_clamp_int(input$n_tasks, default = 10L, lower = 1L, upper = 1000000L)
      max_chunk <- sp_clamp_int(input$max_chunk_size, default = 4L, lower = 1L, upper = n_tasks)
      cpus <- sp_clamp_int(input$cpus_per_task, default = 1L, lower = 1L, upper = 256L)
      mem_s <- sp_clamp_num(input$mem_safety, default = 1.35, lower = 1.0, upper = 10.0)
      time_s <- sp_clamp_num(input$time_safety, default = 1.50, lower = 1.0, upper = 10.0)
      jname <- sp_sanitize_name(input$job_name, default = "slurmpilot_study")

      builder <- resolve_val(args_builder)
      cur_args <- builder(n_tasks)
      cur_fun <- resolve_val(fun)
      cur_be <- resolve_val(backend)
      cur_pkgs <- resolve_val(packages)
      cur_globals <- resolve_val(globals)
      cur_seed <- resolve_val(seed)

      cur_pilot <- pilot_rv()
      res <- if (!is.null(cur_pilot) && cur_pilot$summary$n_ok > 0L) {
        estimate_resources(
          pilot = cur_pilot,
          n_tasks = n_tasks,
          max_chunk_size = max_chunk,
          mem_safety = mem_s,
          time_safety = time_s,
          cpus_per_task = cpus
        )
      } else {
        resource_spec(
          n_tasks = n_tasks,
          chunk_size = min(n_tasks, max_chunk),
          mem_mb = 1024L,
          time_minutes = 15,
          cpus_per_task = cpus
        )
      }
      resources_rv(res)

      extra_args <- list()
      if (isTRUE(input$inject_fault) && inherits(cur_be, "MockSlurmBackend") && res$n_chunks >= 2L) {
        extra_args$fault_injection <- list(fail_chunks = 2L, fail_once = TRUE)
      }

      submitted <- do.call(
        slurm_submit,
        c(
          list(
            backend = cur_be,
            fun = cur_fun,
            args_list = cur_args,
            resources = res,
            name = jname,
            packages = cur_pkgs,
            globals = cur_globals,
            seed = cur_seed
          ),
          extra_args
        )
      )
      job_rv(submitted)
    })

    output$pilot_status_badge <- shiny::renderUI({
      if (isTRUE(is_piloting_rv())) {
        htmltools::span(class = "badge text-bg-info", "Piloting in background...")
      } else if (!is.null(pilot_rv())) {
        htmltools::span(class = "badge text-bg-success", "Auto-sized")
      } else {
        htmltools::span(class = "badge text-bg-secondary", "Not profiled")
      }
    })

    output$pilot_summary <- shiny::renderUI({
      res <- resources_rv()
      p <- pilot_rv()
      msg <- pilot_msg_rv()

      if (is.null(res)) {
        return(htmltools::div(class = "small text-muted mt-2", msg))
      }

      pilot_detail <- if (!is.null(p) && p$summary$n_ok > 0L) {
        sprintf(
          "Empirical pilot (%d/%d ok): median exec %.3fs, peak RSS %.1f MB.",
          p$summary$n_ok, p$summary$n_trials,
          p$summary$exec_q50_sec, p$summary$peak_rss_max_mb
        )
      } else {
        "Manual resource plan (run micro-pilot for empirical sizing)."
      }

      htmltools::div(
        class = "alert alert-light border mt-2 mb-0 py-2 px-3 small",
        htmltools::div(htmltools::strong("Resource Plan: "), sp_escape_ui_text(paste(res$slurm_flags, collapse = " "), 400L)),
        htmltools::div(
          class = "text-muted mt-1",
          sp_escape_ui_text(
            sprintf("%d tasks -> %d chunks (%d tasks/chunk). %s", res$n_tasks, res$n_chunks, res$chunk_size, pilot_detail),
            500L
          )
        )
      )
    })

    list(
      job = shiny::reactive(job_rv()),
      pilot = shiny::reactive(pilot_rv()),
      resources = shiny::reactive(resources_rv()),
      is_piloting = shiny::reactive(is_piloting_rv())
    )
  })
}
