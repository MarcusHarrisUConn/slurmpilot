# Run an Empirical Micro-Pilot to Profile Runtime and Peak RSS Memory

Executes a controlled sample slice of a workload (`fun` applied to
selected elements of `args_list`) in isolated background child R
processes while polling OS-level Resident Set Size (RSS) via `ps`.
Separating cold worker startup overhead from marginal per-task execution
time and measuring true process-tree RSS (including native C++/Stan/BLAS
allocations) feeds directly into
[`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md).

## Usage

``` r
pilot_run(
  fun,
  args_list,
  n_pilot = NULL,
  sample_method = c("head", "stratified", "random"),
  cpus_per_task = 1L,
  sample_interval = 0.03,
  timeout_sec = 300,
  seed = NULL,
  packages = character(),
  globals = list(),
  isolate = TRUE,
  progress = FALSE
)
```

## Arguments

- fun:

  A function accepting a single element of `args_list` (`fun(arg)`).

- args_list:

  Non-empty list (or vector coercible to list) of per-task arguments.

- n_pilot:

  Optional positive integer number of sample replications to profile.
  Defaults to `min(length(args_list), 5L)`.

- sample_method:

  Strategy for selecting pilot task indices from `args_list`: `"head"`
  (first `n_pilot`), `"stratified"` (evenly spaced across the workload),
  or `"random"`.

- cpus_per_task:

  Integer number of CPU threads exposed to each pilot trial
  (`OMP_NUM_THREADS` / `OPENBLAS_NUM_THREADS`). Default `1L`.

- sample_interval:

  Numeric polling interval in seconds for OS RSS sampling of child
  processes. Default `0.03`.

- timeout_sec:

  Numeric per-trial timeout in seconds. Trials exceeding this limit are
  terminated and recorded as `"TIMEOUT"`. Default `300`.

- seed:

  Optional integer base seed for reproducible sampling and child trial
  execution.

- packages:

  Character vector of package names to attach inside each isolated
  worker before executing `fun`.

- globals:

  Named list of helper objects or functions made available in `fun`'s
  evaluation environment.

- isolate:

  Logical; if `TRUE` (default), runs each trial in a fresh background R
  process via
  [`callr::r_bg()`](https://callr.r-lib.org/reference/r_bg.html) to
  measure true startup cost and isolated OS RSS. Set `FALSE` only for
  fast in-process profiling.

- progress:

  Logical; if `TRUE`, emits concise progress messages via `cli`. Default
  `FALSE`.

## Value

An S3 object of class `"slurmpilot_pilot"` with elements:

- `trials`: a
  [`tibble::tibble()`](https://tibble.tidyverse.org/reference/tibble.html)
  with one row per pilot trial containing `trial_id`, `task_index`,
  `status`, `wall_sec`, `startup_sec`, `exec_sec`, `baseline_rss_mb`,
  `peak_rss_mb`, `net_rss_mb`, `cpu_user_sec`, `cpu_sys_sec`,
  `n_samples`, `result_size_bytes`, and `error`.

- `summary`: named list of empirical quantiles and memory statistics.

- `meta`: provenance metadata (`n_pilot`, `n_total_hint`,
  `cpus_per_task`, `packages`, `sample_method`, `isolate`, `timestamp`,
  `r_version`, `platform`, `seed`).

## See also

[`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md),
[`slurm_autopilot()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_autopilot.md)

## Examples

``` r
args <- lapply(1:20, function(i) list(n = 200, seed = i))
pilot <- pilot_run(
  fun = function(x) {
    set.seed(x$seed)
    mean(rnorm(x$n))
  },
  args_list = args,
  n_pilot = 2L
)
print(pilot)
#> 
#> ── slurmpilot Micro-Pilot Profile 
#> • Trials: 2/2 succeeded (isolated=TRUE, cpus=1)
#> • Task exec time: median 0.001s, p90 0.001s, max 0.001s
#> • Worker startup: median 0.728s
#> • Memory (RSS): baseline 89.7 MB, peak max 90.0 MB, net max 0.2 MB
```
