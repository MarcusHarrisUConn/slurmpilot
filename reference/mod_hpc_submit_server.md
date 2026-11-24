# Shiny Server Module for Non-Blocking Micro-Pilot and HPC Submission

Runs micro-pilot trials asynchronously in background OS child processes
polled via
[`shiny::reactiveTimer()`](https://rdrr.io/pkg/shiny/man/reactiveTimer.html)
so the Shiny session remains 100% responsive, estimates optimal SLURM
flags via
[`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md),
and submits jobs to `backend` via
[`slurm_submit()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_submit.md).

## Usage

``` r
mod_hpc_submit_server(
  id,
  backend,
  fun,
  args_builder,
  packages = character(),
  globals = list(),
  seed = 101L,
  poll_ms = 150L,
  async_pilot = TRUE
)
```

## Arguments

- id:

  Character module namespace ID matching
  [`mod_hpc_submit_ui()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_submit_ui.md).

- backend:

  A
  [SlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.md)
  object (or a reactive returning one).

- fun:

  Worker function `fun(arg)` (or a reactive returning one).

- args_builder:

  Function `function(n_tasks)` returning an `args_list` of length
  `n_tasks` (or a reactive returning such a function).

- packages:

  Character vector of worker packages (or reactive).

- globals:

  Named list of worker globals (or reactive).

- seed:

  Optional integer base seed (or reactive).

- poll_ms:

  Polling interval in milliseconds for non-blocking background
  micro-pilot progress. Default `150L`.

- async_pilot:

  Logical; if `TRUE` (default), runs micro-pilot trials in non-blocking
  background
  [`callr::r_bg`](https://callr.r-lib.org/reference/r_bg.html) processes
  driven by `reactiveTimer`. Set `FALSE` only for synchronous unit
  testing.

## Value

A named list of reactives:

- `job`: latest submitted `slurmpilot_job` handle (or `NULL`).

- `pilot`: latest `slurmpilot_pilot` result (or `NULL`).

- `resources`: latest `slurmpilot_resources` plan (or `NULL`).

- `is_piloting`: logical reactive indicating an active background pilot.

## See also

[`mod_hpc_submit_ui()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_submit_ui.md),
[`mod_hpc_monitor_server()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_monitor_server.md)

## Examples

``` r
# \donttest{
if (interactive() && requireNamespace("shiny", quietly = TRUE) &&
    requireNamespace("bslib", quietly = TRUE)) {
  ui <- bslib::page_fluid(mod_hpc_submit_ui("sub"))
  server <- function(input, output, session) {
    be <- mock_slurm_backend(max_workers = 2L)
    mod_hpc_submit_server(
      "sub",
      backend = be,
      fun = function(x) x^2,
      args_builder = function(n) as.list(seq_len(n))
    )
  }
  shiny::shinyApp(ui, server)
}
# }
```
