# Non-blocking Shiny live HPC telemetry, retry, cancel & log monitor module

sp_state_badge_class <- function(state) {
  switch(
    as.character(state),
    "COMPLETED" = "text-bg-success",
    "RUNNING" = "text-bg-primary",
    "PENDING" = "text-bg-secondary",
    "PARTIAL_FAILURE" = "text-bg-warning",
    "FAILED" = "text-bg-danger",
    "OUT_OF_MEMORY" = "text-bg-danger",
    "TIMEOUT" = "text-bg-danger",
    "CANCELLED" = "text-bg-dark",
    "text-bg-secondary"
  )
}

#' Shiny UI Module for Live Cluster Telemetry and Surgical Job Recovery
#'
#' Renders a `bslib` monitoring dashboard displaying live job state, KPI
#' value boxes (state, chunk progress, peak RSS, cumulative walltime), a
#' multi-segment chunk progress bar, surgical retry / cancel / pause / collect
#' controls, a per-chunk status table, and an interactive chunk log viewer.
#'
#' @param id Character module namespace ID.
#' @param title Card header title. Default `"Cluster Job Telemetry"`.
#'
#' @return A `bslib` card UI element.
#' @seealso [mod_hpc_monitor_server()], [mod_hpc_submit_ui()]
#' @export
#' @examples
#' if (requireNamespace("shiny", quietly = TRUE) &&
#'     requireNamespace("bslib", quietly = TRUE)) {
#'   ui <- mod_hpc_monitor_ui("hpc_mon")
#'   inherits(ui, "shiny.tag")
#' }
mod_hpc_monitor_ui <- function(id, title = "Cluster Job Telemetry") {
  sp_check_shiny_deps()
  ns <- shiny::NS(id)

  bslib::card(
    bslib::card_header(
      htmltools::div(
        class = "d-flex justify-content-between align-items-center",
        htmltools::span(title),
        shiny::uiOutput(ns("status_badge"), inline = TRUE)
      )
    ),
    bslib::card_body(
      bslib::layout_column_wrap(
        width = 1 / 4,
        bslib::value_box(
          title = "Job State",
          value = shiny::textOutput(ns("kpi_state"), inline = TRUE),
          theme = "light"
        ),
        bslib::value_box(
          title = "Chunks Done",
          value = shiny::textOutput(ns("kpi_progress"), inline = TRUE),
          theme = "light"
        ),
        bslib::value_box(
          title = "Peak RSS",
          value = shiny::textOutput(ns("kpi_rss"), inline = TRUE),
          theme = "light"
        ),
        bslib::value_box(
          title = "Cumulative Time",
          value = shiny::textOutput(ns("kpi_wall"), inline = TRUE),
          theme = "light"
        )
      ),
      shiny::uiOutput(ns("progress_bar")),
      htmltools::div(
        class = "d-flex flex-wrap gap-2 align-items-center my-3",
        shiny::actionButton(ns("retry_failed"), "Retry Failed Chunks", class = "btn-warning btn-sm"),
        shiny::actionButton(ns("cancel_job"), "Cancel Active", class = "btn-outline-danger btn-sm"),
        shiny::actionButton(ns("toggle_poll"), "Pause Polling", class = "btn-outline-secondary btn-sm"),
        shiny::actionButton(ns("collect_btn"), "Collect Results", class = "btn-success btn-sm"),
        htmltools::div(
          class = "ms-2",
          shiny::checkboxInput(ns("bump_mem"), "Scale --mem 1.5x on retry", value = FALSE)
        )
      ),
      shiny::uiOutput(ns("chunk_table")),
      bslib::accordion(
        open = FALSE,
        bslib::accordion_panel(
          title = "Chunk Stdout / Stderr Logs",
          shiny::selectInput(ns("log_chunk"), "Chunk ID", choices = character(), width = "200px"),
          shiny::verbatimTextOutput(ns("chunk_log_text"))
        )
      )
    )
  )
}

#' Shiny Server Module for Non-Blocking Cluster Monitoring and Recovery
#'
#' Polls `slurm_status()` asynchronously using a self-throttling
#' [shiny::reactiveTimer()] (idling automatically once a job reaches a terminal
#' state and resuming immediately on new submissions or surgical retries).
#' Handles chunk-level surgical retries, job cancellation, polling pause/resume,
#' automatic or manual result collection, and log inspection.
#'
#' @param id Character module namespace ID matching [mod_hpc_monitor_ui()].
#' @param job A reactive returning a `slurmpilot_job` handle (or `NULL`).
#' @param poll_ms Polling interval in milliseconds. Default `400L`.
#' @param auto_collect Logical; if `TRUE` (default), automatically collects
#'   ordered results once the job reaches `"COMPLETED"`.
#' @param simplify Logical passed to [slurm_collect()]. Default `FALSE`.
#' @param max_retries Positive integer cap on surgical retry button clicks per
#'   job (clamped to `[1, 50]`). Default `5L`.
#' @param retry_mem_multiplier Memory scaling multiplier applied when
#'   `bump_mem` is checked (clamped to `[1.0, 4.0]`). Default `1.5`.
#'
#' @return A named list of reactives:
#'   - `status`: latest `slurmpilot_status` object (or `NULL`).
#'   - `results`: collected results (or `NULL` until collected).
#'   - `is_polling`: logical reactive indicating whether live polling is active.
#'   - `job`: active `slurmpilot_job` handle (updated on surgical retries).
#'
#' @seealso [mod_hpc_monitor_ui()], [mod_hpc_submit_server()]
#' @export
#' @examples
#' \donttest{
#' if (interactive() && requireNamespace("shiny", quietly = TRUE) &&
#'     requireNamespace("bslib", quietly = TRUE)) {
#'   ui <- bslib::page_fluid(
#'     mod_hpc_submit_ui("sub"),
#'     mod_hpc_monitor_ui("mon")
#'   )
#'   server <- function(input, output, session) {
#'     be <- mock_slurm_backend(max_workers = 2L)
#'     sub <- mod_hpc_submit_server(
#'       "sub",
#'       backend = be,
#'       fun = function(x) x^2,
#'       args_builder = function(n) as.list(seq_len(n))
#'     )
#'     mod_hpc_monitor_server("mon", job = sub$job)
#'   }
#'   shiny::shinyApp(ui, server)
#' }
#' }
mod_hpc_monitor_server <- function(
  id,
  job,
  poll_ms = 400L,
  auto_collect = TRUE,
  simplify = FALSE,
  max_retries = 5L,
  retry_mem_multiplier = 1.5
) {
  sp_check_shiny_deps()
  poll_ms <- sp_clamp_int(poll_ms, default = 400L, lower = 50L, upper = 60000L)
  max_retries <- sp_clamp_int(max_retries, default = 5L, lower = 1L, upper = 50L)
  retry_mem_multiplier <- sp_clamp_num(retry_mem_multiplier, default = 1.5, lower = 1.0, upper = 4.0)

  shiny::moduleServer(id, function(input, output, session) {
    active_job_rv <- shiny::reactiveVal(NULL)
    status_rv <- shiny::reactiveVal(NULL)
    results_rv <- shiny::reactiveVal(NULL)
    polling_rv <- shiny::reactiveVal(TRUE)
    retry_count_rv <- shiny::reactiveVal(0L)

    refresh_status <- function(j) {
      if (is.null(j)) {
        status_rv(NULL)
        return(invisible(NULL))
      }
      st <- slurm_status(j)
      status_rv(st)
      if (isTRUE(auto_collect) && identical(st$state, "COMPLETED") && is.null(results_rv())) {
        res <- tryCatch(
          slurm_collect(j, simplify = simplify),
          error = function(e) NULL
        )
        if (!is.null(res)) {
          results_rv(res)
        }
      }
      invisible(st)
    }

    # React when a new job is submitted upstream
    shiny::observeEvent(job(), {
      j <- job()
      active_job_rv(j)
      results_rv(NULL)
      retry_count_rv(0L)
      polling_rv(TRUE)
      shiny::updateActionButton(session, "toggle_poll", label = "Pause Polling")
      if (!is.null(j)) {
        choices <- stats::setNames(
          as.character(seq_len(j$resources$n_chunks)),
          paste("Chunk", seq_len(j$resources$n_chunks))
        )
        shiny::updateSelectInput(session, "log_chunk", choices = choices, selected = "1")
        refresh_status(j)
      } else {
        status_rv(NULL)
      }
    }, ignoreNULL = FALSE)

    # Non-blocking self-throttling poll loop (strictly isolated to prevent reactive loops)
    poll_timer <- shiny::reactiveTimer(poll_ms, session)
    shiny::observe({
      poll_timer()
      if (!isTRUE(shiny::isolate(polling_rv()))) return()
      j <- shiny::isolate(active_job_rv())
      if (is.null(j)) return()
      cur_st <- shiny::isolate(status_rv())
      if (!is.null(cur_st) && isTRUE(cur_st$is_terminal)) return()
      refresh_status(j)
    })

    # Surgical retry of failed/OOM/timeout/cancelled chunks (with retry cap & memory ceiling)
    shiny::observeEvent(input$retry_failed, {
      j <- active_job_rv()
      if (is.null(j)) return()
      cur_st <- shiny::isolate(status_rv())
      if (!is.null(cur_st) && identical(cur_st$n_retryable, 0L)) return()
      if (retry_count_rv() >= max_retries) {
        shiny::showNotification(
          sprintf("Retry cap (%d) reached for this job.", max_retries),
          type = "warning"
        )
        return()
      }
      mem_mult <- if (isTRUE(input$bump_mem)) retry_mem_multiplier else NULL
      if (!is.null(mem_mult) && j$resources$mem_mb * mem_mult > 1048576) {
        mem_mult <- NULL
      }
      j_updated <- slurm_retry(j, mem_multiplier = mem_mult)
      retry_count_rv(retry_count_rv() + 1L)
      active_job_rv(j_updated)
      results_rv(NULL)
      polling_rv(TRUE)
      shiny::updateActionButton(session, "toggle_poll", label = "Pause Polling")
      refresh_status(j_updated)
    })

    # Cancel active chunks
    shiny::observeEvent(input$cancel_job, {
      j <- active_job_rv()
      if (is.null(j)) return()
      slurm_cancel(j)
      refresh_status(j)
    })

    # Pause / resume polling
    shiny::observeEvent(input$toggle_poll, {
      new_val <- !isTRUE(polling_rv())
      polling_rv(new_val)
      shiny::updateActionButton(
        session,
        "toggle_poll",
        label = if (new_val) "Pause Polling" else "Resume Polling"
      )
      if (new_val && !is.null(active_job_rv())) {
        refresh_status(active_job_rv())
      }
    })

    # Manual result collection
    shiny::observeEvent(input$collect_btn, {
      j <- active_job_rv()
      if (is.null(j)) return()
      st <- refresh_status(j)
      allow_part <- !identical(st$state, "COMPLETED")
      res <- tryCatch(
        slurm_collect(j, simplify = simplify, allow_partial = allow_part),
        error = function(e) {
          shiny::showNotification(conditionMessage(e), type = "error")
          NULL
        }
      )
      if (!is.null(res)) {
        results_rv(res)
      }
    })

    # Outputs
    output$status_badge <- shiny::renderUI({
      st <- status_rv()
      if (is.null(st)) {
        return(htmltools::span(class = "badge text-bg-light text-dark", "Idle"))
      }
      htmltools::span(class = paste("badge", sp_state_badge_class(st$state)), st$state)
    })

    output$kpi_state <- shiny::renderText({
      st <- status_rv()
      if (is.null(st)) "Idle" else st$state
    })

    output$kpi_progress <- shiny::renderText({
      st <- status_rv()
      if (is.null(st)) "0 / 0" else sprintf("%d / %d", st$n_completed, st$n_chunks)
    })

    output$kpi_rss <- shiny::renderText({
      st <- status_rv()
      if (is.null(st) || is.na(st$peak_rss_max_mb)) "--" else sprintf("%.1f MB", st$peak_rss_max_mb)
    })

    output$kpi_wall <- shiny::renderText({
      st <- status_rv()
      if (is.null(st)) "0.0s" else sprintf("%.1fs", st$total_wall_sec)
    })

    output$progress_bar <- shiny::renderUI({
      st <- status_rv()
      if (is.null(st) || st$n_chunks == 0L) {
        return(htmltools::div(class = "progress", style = "height: 18px;"))
      }
      pct <- function(n) sprintf("%.1f%%", 100 * n / st$n_chunks)
      n_err <- st$n_failed + st$n_oom + st$n_timeout + st$n_cancelled
      htmltools::div(
        class = "progress mt-2",
        style = "height: 20px;",
        htmltools::div(
          class = "progress-bar bg-success",
          role = "progressbar",
          style = paste0("width: ", pct(st$n_completed)),
          if (st$n_completed > 0L) sprintf("%d done", st$n_completed) else ""
        ),
        htmltools::div(
          class = "progress-bar progress-bar-striped progress-bar-animated bg-primary",
          role = "progressbar",
          style = paste0("width: ", pct(st$n_running)),
          if (st$n_running > 0L) sprintf("%d run", st$n_running) else ""
        ),
        htmltools::div(
          class = "progress-bar bg-danger",
          role = "progressbar",
          style = paste0("width: ", pct(n_err)),
          if (n_err > 0L) sprintf("%d err", n_err) else ""
        ),
        htmltools::div(
          class = "progress-bar bg-secondary",
          role = "progressbar",
          style = paste0("width: ", pct(st$n_pending)),
          if (st$n_pending > 0L) sprintf("%d queue", st$n_pending) else ""
        )
      )
    })

    output$chunk_table <- shiny::renderUI({
      st <- status_rv()
      if (is.null(st) || nrow(st$chunks) == 0L) {
        return(htmltools::p(class = "text-muted small", "Submit a job to see live per-chunk status."))
      }
      df <- st$chunks
      rows <- lapply(seq_len(nrow(df)), function(i) {
        wall_str <- if (is.na(df$wall_sec[[i]])) "--" else sprintf("%.2fs", df$wall_sec[[i]])
        rss_str <- if (is.na(df$peak_rss_mb[[i]])) "--" else sprintf("%.1f MB", df$peak_rss_mb[[i]])
        err_str <- sp_escape_ui_text(df$error_message[[i]], max_chars = 300L)
        state_str <- sp_escape_ui_text(df$state[[i]], max_chars = 32L)
        worker_str <- if (is.na(df$worker_id[[i]])) "--" else sp_escape_ui_text(df$worker_id[[i]], max_chars = 64L)
        htmltools::tags$tr(
          htmltools::tags$td(as.character(df$chunk_id[[i]])),
          htmltools::tags$td(as.character(df$n_tasks[[i]])),
          htmltools::tags$td(
            htmltools::span(class = paste("badge", sp_state_badge_class(state_str)), state_str)
          ),
          htmltools::tags$td(as.character(df$attempt[[i]])),
          htmltools::tags$td(worker_str),
          htmltools::tags$td(wall_str),
          htmltools::tags$td(rss_str),
          htmltools::tags$td(if (isTRUE(df$checkpoint_exists[[i]])) "Saved" else "--"),
          htmltools::tags$td(class = "text-danger small", err_str)
        )
      })

      htmltools::div(
        class = "table-responsive",
        htmltools::tags$table(
          class = "table table-sm table-hover align-middle small",
          htmltools::tags$thead(
            htmltools::tags$tr(
              htmltools::tags$th("Chunk"),
              htmltools::tags$th("Tasks"),
              htmltools::tags$th("State"),
              htmltools::tags$th("Attempt"),
              htmltools::tags$th("Worker"),
              htmltools::tags$th("Walltime"),
              htmltools::tags$th("Peak RSS"),
              htmltools::tags$th("Checkpoint"),
              htmltools::tags$th("Notes")
            )
          ),
          htmltools::tags$tbody(rows)
        )
      )
    })

    output$chunk_log_text <- shiny::renderText({
      j <- active_job_rv()
      cid <- sp_clamp_int(input$log_chunk, default = NA_integer_, lower = 1L, upper = if (!is.null(j)) j$resources$n_chunks else 1L)
      st <- status_rv()
      if (is.null(j) || is.na(cid) || is.null(st)) {
        return("No chunk logs available yet.")
      }
      lg <- slurm_logs(j, chunk_id = cid)[[1L]]
      out_clean <- sp_escape_ui_text(lg$stdout, max_chars = 8000L)
      err_clean <- sp_escape_ui_text(lg$stderr, max_chars = 8000L)
      paste0(
        "=== STDOUT (chunk ", cid, ") ===\n",
        if (nzchar(out_clean)) out_clean else "(empty)",
        "\n\n=== STDERR (chunk ", cid, ") ===\n",
        if (nzchar(err_clean)) err_clean else "(empty)"
      )
    })

    list(
      status = shiny::reactive(status_rv()),
      results = shiny::reactive(results_rv()),
      is_polling = shiny::reactive(polling_rv()),
      job = shiny::reactive(active_job_rv())
    )
  })
}
