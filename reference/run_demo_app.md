# Launch the Bundled Non-Blocking `slurmpilot` Demo Shiny App

Starts the interactive Monte Carlo simulation studio bundled in
`inst/shiny/demo/app.R`, demonstrating empirical micro-pilot
auto-sizing, non-blocking background
[MockSlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/MockSlurmBackend.md)
cluster execution, surgical chunk retry, live UI responsiveness during
heavy compute, and Apptainer/SLURM script export.

## Usage

``` r
run_demo_app(launch.browser = interactive(), port = NULL, ...)
```

## Arguments

- launch.browser:

  Logical; open the app in a web browser. Defaults to
  [`interactive()`](https://rdrr.io/r/base/interactive.html).

- port:

  Optional TCP port passed to
  [`shiny::runApp()`](https://rdrr.io/pkg/shiny/man/runApp.html).

- ...:

  Additional arguments passed to
  [`shiny::runApp()`](https://rdrr.io/pkg/shiny/man/runApp.html).

## Value

Invisibly returns the result of
[`shiny::runApp()`](https://rdrr.io/pkg/shiny/man/runApp.html).

## Examples

``` r
# \donttest{
if (interactive()) {
  run_demo_app()
}
# }
```
