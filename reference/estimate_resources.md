# Estimate Optimal SLURM Array Resources from a Micro-Pilot

Fits an empirical runtime and memory scaling model from a
[`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md)
result and computes optimal SLURM array chunking (`--array`), memory
ceiling (`--mem`), walltime limit (`--time`), and CPU allocation
(`--cpus-per-task`) with configurable safety margins and queue-friendly
rounding.

## Usage

``` r
estimate_resources(
  pilot,
  n_tasks = pilot$meta$n_total_hint,
  target_chunk_minutes = 15,
  max_array_size = 1000L,
  min_chunk_size = 1L,
  max_chunk_size = NULL,
  mem_safety = 1.35,
  time_safety = 1.5,
  mem_min_mb = 512L,
  mem_round_mb = 256L,
  time_min_minutes = 5,
  time_round_minutes = 5,
  cpus_per_task = NULL,
  parallel_efficiency = 0.85,
  partition = NULL,
  account = NULL,
  qos = NULL,
  max_concurrent = NULL,
  strategy = c("contiguous", "round_robin", "lpt"),
  task_weights = NULL
)
```

## Arguments

- pilot:

  A `slurmpilot_pilot` object returned by
  [`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md).

- n_tasks:

  Positive integer total number of tasks in the full workload. Defaults
  to `pilot$meta$n_total_hint`.

- target_chunk_minutes:

  Target walltime in minutes per SLURM array task. Default `15`.

- max_array_size:

  Maximum number of SLURM array indices allowed by the cluster
  (`MaxArraySize`). Default `1000L`.

- min_chunk_size:

  Minimum tasks per SLURM array chunk. Default `1L`.

- max_chunk_size:

  Optional maximum tasks per SLURM array chunk.

- mem_safety:

  Multiplicative safety factor applied to predicted peak RSS. Default
  `1.35`.

- time_safety:

  Multiplicative safety factor applied to predicted upper walltime.
  Default `1.50`.

- mem_min_mb:

  Minimum requested memory in MB. Default `512L`.

- mem_round_mb:

  Granularity in MB to round requested memory up to. Default `256L`.

- time_min_minutes:

  Minimum requested walltime in minutes. Default `5`.

- time_round_minutes:

  Granularity in minutes to round requested walltime up to. Default `5`.

- cpus_per_task:

  Optional integer CPU count per SLURM array task. Defaults to
  `pilot$meta$cpus_per_task`.

- parallel_efficiency:

  Numeric in `(0, 1]` specifying Amdahl parallel efficiency when scaling
  `cpus_per_task` beyond the pilot CPU count. Default `0.85`.

- partition:

  Optional SLURM `--partition` name.

- account:

  Optional SLURM `--account` name.

- qos:

  Optional SLURM `--qos` name.

- max_concurrent:

  Optional positive integer array concurrency cap
  (`--array=1-M%max_concurrent`).

- strategy:

  Chunk assignment strategy: `"contiguous"` (default), `"round_robin"`,
  or `"lpt"` (Longest Processing Time first load balancing for
  heterogeneous task workloads).

- task_weights:

  Optional positive numeric vector of length `n_tasks` providing
  relative per-task runtime/cost weights for `"lpt"` load balancing.
  When `strategy = "lpt"` and `task_weights = NULL`, weights are
  interpolated linearly from the pilot trials across `1:n_tasks` (or
  fall back to uniform weights if fewer than 2 distinct pilot indices
  exist).

## Value

An S3 object of class `"slurmpilot_resources"` containing computed
chunking, SLURM resource values, formatted flags (`slurm_flags`),
partition table (`chunks`), and diagnostic scaling estimates
(`estimates`).

## Details

For a chunk of \\k\\ sequential tasks on \\c\\ CPUs (relative to pilot
CPU count \\c_0\\ with Amdahl parallel efficiency \\\eta\\):

- Relative speedup is \\S = ((1 - \eta) + \eta / c_0) / ((1 - \eta) +
  \eta / c)\\.

- Optimal chunk size \\k^\*\\ balances target chunk duration
  (`target_chunk_minutes`) against startup overhead amortization and
  `max_array_size`.

- Chunk walltime upper bound combines CLT standard-deviation scaling
  (\\\sqrt{k^\*}\sigma_t\\) with Fenton-Wilkinson log-normal and
  nonparametric upper-quantile protection plus `time_safety`.

- Chunk memory accounts for baseline RSS, peak net working set, modest
  logarithmic heap fragmentation across sequential replications (\\1 +
  0.05 \log_2(k^\*)\\), and `mem_safety`.

## See also

[`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md),
[`resource_spec()`](https://marcusharrisphd.com/slurmpilot/reference/resource_spec.md),
[`plan_chunks()`](https://marcusharrisphd.com/slurmpilot/reference/plan_chunks.md),
[`as_slurm_flags()`](https://marcusharrisphd.com/slurmpilot/reference/as_slurm_flags.md)

## Examples

``` r
args <- lapply(1:10, function(i) list(n = 200, seed = i))
pilot <- pilot_run(
  fun = function(x) {
    set.seed(x$seed)
    mean(rnorm(x$n))
  },
  args_list = args,
  n_pilot = 2L
)
res <- estimate_resources(pilot, n_tasks = 500L, target_chunk_minutes = 5)
print(res)
#> 
#> ── slurmpilot SLURM Resource Plan 
#> • Workload: 500 tasks -> 1 array chunks (500 tasks/chunk)
#> • SLURM flags: --array=1 --cpus-per-task=1 --mem=512M --time=00:05:00
#> ℹ Predicted chunk walltime: 1.3s (expected 1.2s, startup overhead 59.3%)
#> ℹ Predicted peak RSS: 130.8 MB -> requested 512M
#> ℹ Estimated total compute: 0.00 CPU-hours
```
