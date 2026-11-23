# Demo Shiny application launcher

#' Launch the Bundled Non-Blocking `slurmpilot` Demo Shiny App
#'
#' Starts the interactive Monte Carlo simulation studio bundled in
#' `inst/shiny/demo/app.R`, demonstrating empirical micro-pilot auto-sizing,
#' non-blocking background [MockSlurmBackend] cluster execution, surgical chunk
#' retry, live UI responsiveness during heavy compute, and Apptainer/SLURM
#' script export.
#'
#' @param launch.browser Logical; open the app in a web browser. Defaults to
#'   `interactive()`.
#' @param port Optional TCP port passed to [shiny::runApp()].
#' @param ... Additional arguments passed to [shiny::runApp()].
#'
#' @return Invisibly returns the result of [shiny::runApp()].
#' @export
run_demo_app <- function(launch.browser = interactive(), port = NULL, ...) {
  sp_check_shiny_deps()
  app_dir <- system.file("shiny", "demo", package = "slurmpilot")
  if (!nzchar(app_dir) || !dir.exists(app_dir)) {
    cli::cli_abort("Could not locate bundled demo app directory {.path inst/shiny/demo}.")
  }
  shiny::runApp(appDir = app_dir, launch.browser = launch.browser, port = port, ...)
}
