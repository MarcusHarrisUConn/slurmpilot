# Shiny UI Module for Micro-Pilot Auto-Sizing and HPC Job Submission

Provides a drop-in `bslib` card UI for configuring workload size,
launching a non-blocking empirical micro-pilot, inspecting auto-sized
SLURM resource recommendations (`--array`, `--mem`, `--time`,
`--cpus-per-task`), and submitting array jobs to any
[SlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.md).

## Usage

``` r
mod_hpc_submit_ui(
  id,
  title = "HPC Micro-Pilot & Submission",
  default_n_tasks = 20L,
  default_n_pilot = 3L,
  default_chunk_size = 4L,
  default_cpus = 1L,
  default_job_name = "slurmpilot_study",
  show_fault_toggle = FALSE
)
```

## Arguments

- id:

  Character module namespace ID.

- title:

  Card header title. Default `"HPC Micro-Pilot & Submission"`.

- default_n_tasks:

  Default total number of tasks. Default `20L`.

- default_n_pilot:

  Default number of micro-pilot replications. Default `3L`.

- default_chunk_size:

  Default maximum tasks per chunk. Default `4L`.

- default_cpus:

  Default CPUs per array task. Default `1L`.

- default_job_name:

  Default SLURM job name. Default `"slurmpilot_study"`.

- show_fault_toggle:

  Logical; if `TRUE`, shows a checkbox to inject a recoverable
  single-chunk failure when using
  [MockSlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/MockSlurmBackend.md)
  (useful for interactive demos of surgical retry). Default `FALSE`.

## Value

A `bslib` card UI element.

## See also

[`mod_hpc_submit_server()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_submit_server.md),
[`mod_hpc_monitor_ui()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_monitor_ui.md)

## Examples

``` r
if (requireNamespace("shiny", quietly = TRUE) &&
    requireNamespace("bslib", quietly = TRUE)) {
  ui <- mod_hpc_submit_ui("hpc_sub", default_n_tasks = 12L)
  inherits(ui, "shiny.tag")
}
#> [1] TRUE
```
