# Shiny Server Module for Non-Blocking Cluster Monitoring and Recovery

Polls
[`slurm_status()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_status.md)
asynchronously using a self-throttling
[`shiny::reactiveTimer()`](https://rdrr.io/pkg/shiny/man/reactiveTimer.html)
(idling automatically once a job reaches a terminal state and resuming
immediately on new submissions or surgical retries). Handles chunk-level
surgical retries, job cancellation, polling pause/resume, automatic or
manual result collection, and log inspection.

## Usage

``` r
mod_hpc_monitor_server(
  id,
  job,
  poll_ms = 400L,
  auto_collect = TRUE,
  simplify = FALSE,
  max_retries = 5L,
  retry_mem_multiplier = 1.5
)
```

## Arguments

- id:

  Character module namespace ID matching
  [`mod_hpc_monitor_ui()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_monitor_ui.md).

- job:

  A reactive returning a `slurmpilot_job` handle (or `NULL`).

- poll_ms:

  Polling interval in milliseconds. Default `400L`.

- auto_collect:

  Logical; if `TRUE` (default), automatically collects ordered results
  once the job reaches `"COMPLETED"`.

- simplify:

  Logical passed to
  [`slurm_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_collect.md).
  Default `FALSE`.

- max_retries:

  Positive integer cap on surgical retry button clicks per job (clamped
  to `[1, 50]`). Default `5L`.

- retry_mem_multiplier:

  Memory scaling multiplier applied when `bump_mem` is checked (clamped
  to `[1.0, 4.0]`). Default `1.5`.

## Value

A named list of reactives:

- `status`: latest `slurmpilot_status` object (or `NULL`).

- `results`: collected results (or `NULL` until collected).

- `is_polling`: logical reactive indicating whether live polling is
  active.

- `job`: active `slurmpilot_job` handle (updated on surgical retries).

## See also

[`mod_hpc_monitor_ui()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_monitor_ui.md),
[`mod_hpc_submit_server()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_submit_server.md)

## Examples

``` r
# \donttest{
if (interactive() && requireNamespace("shiny", quietly = TRUE) &&
    requireNamespace("bslib", quietly = TRUE)) {
  ui <- bslib::page_fluid(
    mod_hpc_submit_ui("sub"),
    mod_hpc_monitor_ui("mon")
  )
  server <- function(input, output, session) {
    be <- mock_slurm_backend(max_workers = 2L)
    sub <- mod_hpc_submit_server(
      "sub",
      backend = be,
      fun = function(x) x^2,
      args_builder = function(n) as.list(seq_len(n))
    )
    mod_hpc_monitor_server("mon", job = sub$job)
  }
  shiny::shinyApp(ui, server)
}
# }
```
