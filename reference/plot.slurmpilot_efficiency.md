# Plot a Post-Mortem SLURM Resource Efficiency Report

Visualizes per-chunk observed Peak RSS against requested `--mem` and
per-chunk walltime against requested `--time` from a
[`slurm_efficiency_report()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_efficiency_report.md)
audit.

## Usage

``` r
# S3 method for class 'slurmpilot_efficiency'
plot(x, engine = c("base", "ggplot2"), ...)
```

## Arguments

- x:

  A `slurmpilot_efficiency` object.

- engine:

  Graphics engine: `"base"` (default) or `"ggplot2"`.

- ...:

  Unused; kept for S3 generic compatibility.

## Value

Invisibly returns `x` for `engine = "base"`, or a `ggplot` object for
`engine = "ggplot2"`.

## Examples

``` r
sa <- parse_sacct_output(
  "100_1|COMPLETED|00:02:00|256M|0:0\n100_2|COMPLETED|00:04:00|300M|0:0"
)
res <- resource_spec(4L, 2L, mem_mb = 1024L, time_minutes = 15)
eff <- slurm_efficiency_report(sa, resources = res)
plot(eff, engine = "base")
```
