library(shiny)
library(bslib)
library(slurmpilot)

# Monte Carlo two-sample Welch power & CI coverage worker
mc_power_worker <- function(cfg) {
  set.seed(cfg$seed)
  n <- cfg$n_per_group
  delta <- cfg$effect_size
  reps <- cfg$inner_reps
  rejects <- logical(reps)
  ests <- numeric(reps)
  covers <- logical(reps)

  for (r in seq_len(reps)) {
    x <- rnorm(n, mean = 0, sd = 1)
    y <- rnorm(n, mean = delta, sd = 1)
    tt <- t.test(y, x)
    ests[[r]] <- as.numeric(diff(rev(tt$estimate)))
    rejects[[r]] <- tt$p.value < 0.05
    covers[[r]] <- (tt$conf.int[[1L]] <= delta) && (delta <= tt$conf.int[[2L]])
  }

  data.frame(
    task_id = cfg$task_id,
    mean_est = mean(ests),
    power = mean(rejects),
    coverage = mean(covers),
    inner_reps = reps
  )
}

ui <- page_navbar(
  title = "slurmpilot | Async HPC Offload Demo",
  theme = bs_theme(version = 5, bootswatch = "flatly"),
  sidebar = sidebar(
    title = "Simulation Design",
    sliderInput("effect_size", "True Effect Size (Cohen's d)", min = 0.0, max = 1.0, value = 0.35, step = 0.05),
    numericInput("n_per_group", "Sample Size / Group (n)", value = 60L, min = 10L, max = 500L, step = 10L),
    numericInput("inner_reps", "Replications / Task", value = 80L, min = 10L, max = 500L, step = 10L),
    tags$hr(),
    h6("UI Responsiveness Check"),
    p(class = "small text-muted", "Move this slider or click while a cluster job runs to verify zero UI blocking:"),
    sliderInput("ui_probe", "Instant Slider", min = 1L, max = 100L, value = 42L),
    actionButton("ping_btn", "Ping Main Thread", class = "btn-outline-secondary btn-sm w-100"),
    div(class = "small mt-2 text-primary fw-semibold", textOutput("ping_status"))
  ),
  nav_panel(
    title = "Cluster Offload",
    mod_hpc_submit_ui(
      id = "submit",
      title = "1. Micro-Pilot & Array Submission (Mock SLURM)",
      default_n_tasks = 16L,
      default_n_pilot = 3L,
      default_chunk_size = 4L,
      default_job_name = "mc_power_study",
      show_fault_toggle = TRUE
    ),
    mod_hpc_monitor_ui(
      id = "monitor",
      title = "2. Live Cluster Telemetry & Surgical Recovery"
    )
  ),
  nav_panel(
    title = "Collected Results",
    card(
      card_header("Aggregated Monte Carlo Power & Coverage"),
      card_body(
        uiOutput("results_summary"),
        plotOutput("results_plot", height = "340px")
      )
    )
  ),
  nav_panel(
    title = "HPC Export (Apptainer & SLURM)",
    layout_column_wrap(
      width = 1 / 2,
      card(
        card_header("Generated SLURM sbatch Array Script"),
        card_body(verbatimTextOutput("sbatch_preview"))
      ),
      card(
        card_header("Generated Apptainer .def Recipe"),
        card_body(verbatimTextOutput("apptainer_preview"))
      )
    )
  )
)

server <- function(input, output, session) {
  backend <- mock_slurm_backend(max_workers = 2L, queue_delay = 0.2)

  pings <- reactiveVal(0L)
  observeEvent(input$ping_btn, {
    pings(pings() + 1L)
  })
  output$ping_status <- renderText({
    sprintf("Slider = %d | Main-thread pings = %d (%s)", input$ui_probe, pings(), format(Sys.time(), "%H:%M:%S"))
  })

  args_builder <- reactive({
    d <- input$effect_size
    n <- input$n_per_group
    reps <- input$inner_reps
    function(n_tasks) {
      lapply(seq_len(n_tasks), function(i) {
        list(task_id = i, effect_size = d, n_per_group = n, inner_reps = reps, seed = 1000L + i)
      })
    }
  })

  submit_mod <- mod_hpc_submit_server(
    id = "submit",
    backend = backend,
    fun = mc_power_worker,
    args_builder = args_builder,
    poll_ms = 150L
  )

  monitor_mod <- mod_hpc_monitor_server(
    id = "monitor",
    job = submit_mod$job,
    poll_ms = 300L,
    auto_collect = TRUE,
    simplify = TRUE
  )

  output$results_summary <- renderUI({
    df <- monitor_mod$results()
    if (is.null(df) || !is.data.frame(df) || nrow(df) == 0L) {
      return(p(class = "text-muted", "Complete a cluster job on the first tab to view aggregated Monte Carlo estimates."))
    }
    total_reps <- sum(df$inner_reps)
    layout_column_wrap(
      width = 1 / 4,
      value_box("Total Replications", format(total_reps, big.mark = ","), theme = "light"),
      value_box("Empirical Power", sprintf("%.1f%%", 100 * mean(df$power)), theme = "primary"),
      value_box("Mean Effect Est.", sprintf("%.3f", mean(df$mean_est)), theme = "light"),
      value_box("95% CI Coverage", sprintf("%.1f%%", 100 * mean(df$coverage)), theme = "success")
    )
  })

  output$results_plot <- renderPlot({
    df <- monitor_mod$results()
    validate(need(!is.null(df) && is.data.frame(df) && nrow(df) > 0L, "Waiting for completed cluster results..."))
    hist(
      df$mean_est,
      col = "#2c3e50",
      border = "white",
      main = "Distribution of Task-Level Effect Estimates Across Cluster Chunks",
      xlab = "Estimated Mean Difference (d)",
      ylab = "Tasks"
    )
    abline(v = input$effect_size, col = "#e74c3c", lwd = 2, lty = 2)
    legend("topright", legend = sprintf("True d = %.2f", input$effect_size), col = "#e74c3c", lty = 2, lwd = 2, bty = "n")
  })

  output$sbatch_preview <- renderText({
    res <- submit_mod$resources()
    if (is.null(res)) {
      res <- resource_spec(n_tasks = 16L, chunk_size = 4L, mem_mb = 1024L, time_minutes = 15)
    }
    sb <- render_sbatch_script(
      job_name = "mc_power_study",
      resources = res,
      work_dir = "/scratch/researcher/mc_power_study",
      container_sif = "/scratch/containers/slurmpilot_env.sif"
    )
    sb$text
  })

  output$apptainer_preview <- renderText({
    env <- scan_project_env(extra_packages = c("lme4", "Rcpp", "tibble"))
    def <- build_apptainer_def(env)
    def$text
  })
}

shinyApp(ui = ui, server = server)
