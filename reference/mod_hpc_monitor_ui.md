# Shiny UI Module for Live Cluster Telemetry and Surgical Job Recovery

Renders a `bslib` monitoring dashboard displaying live job state, KPI
value boxes (state, chunk progress, peak RSS, cumulative walltime), a
multi-segment chunk progress bar, surgical retry / cancel / pause /
collect controls, a per-chunk status table, and an interactive chunk log
viewer.

## Usage

``` r
mod_hpc_monitor_ui(id, title = "Cluster Job Telemetry")
```

## Arguments

- id:

  Character module namespace ID.

- title:

  Card header title. Default `"Cluster Job Telemetry"`.

## Value

A `bslib` card UI element.

## See also

[`mod_hpc_monitor_server()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_monitor_server.md),
[`mod_hpc_submit_ui()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_submit_ui.md)

## Examples

``` r
if (requireNamespace("shiny", quietly = TRUE) &&
    requireNamespace("bslib", quietly = TRUE)) {
  ui <- mod_hpc_monitor_ui("hpc_mon")
  inherits(ui, "shiny.tag")
}
#> [1] TRUE
```
