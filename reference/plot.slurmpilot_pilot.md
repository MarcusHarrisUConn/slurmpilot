# Plot a Micro-Pilot Profile

Visualizes per-trial execution time, startup overhead, and peak RSS
memory from a
[`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md)
result.

## Usage

``` r
# S3 method for class 'slurmpilot_pilot'
plot(x, engine = c("base", "ggplot2"), ...)
```

## Arguments

- x:

  A `slurmpilot_pilot` object returned by
  [`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md).

- engine:

  Graphics engine: `"base"` (default, zero extra dependencies) or
  `"ggplot2"` (returns a `ggplot` object if `ggplot2` is installed).

- ...:

  Unused; kept for S3 generic compatibility.

## Value

Invisibly returns `x` for `engine = "base"`, or a `ggplot` object for
`engine = "ggplot2"`.

## Examples

``` r
pilot <- pilot_run(
  fun = function(x) mean(rnorm(x)),
  args_list = list(100, 100),
  n_pilot = 2L,
  isolate = FALSE
)
plot(pilot, engine = "base")
```
