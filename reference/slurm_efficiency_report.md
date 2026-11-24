# Audit Post-Mortem SLURM Memory, Walltime, and Load-Balance Efficiency

Analyzes requested versus empirically observed Peak RSS memory,
walltime, and cross-chunk straggler imbalance from a completed or
partially failed
[`slurm_submit()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_submit.md)
job,
[`slurm_status()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_status.md)
telemetry object,
[`slurm_autopilot()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_autopilot.md)
run, or parsed
[`parse_sacct_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_sacct_output.md)
table. Quantifies memory waste %, walltime slack %, and straggler ratio
(`max / median` chunk time), and emits a concrete recommended tightened
[`resource_spec()`](https://marcusharrisphd.com/slurmpilot/reference/resource_spec.md)
for the next run.

## Usage

``` r
slurm_efficiency_report(
  x,
  resources = NULL,
  mem_safety = 1.25,
  time_safety = 1.35,
  mem_min_mb = 256L,
  mem_round_mb = 128L,
  time_min_minutes = 5,
  time_round_minutes = 5
)
```

## Arguments

- x:

  A `slurmpilot_job`, `slurmpilot_autopilot`, `slurmpilot_status`, or
  data frame from
  [`parse_sacct_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_sacct_output.md).

- resources:

  Optional `slurmpilot_resources` object (required when `x` is a
  `slurmpilot_status` or `sacct` data frame; inferred automatically from
  `slurmpilot_job` or `slurmpilot_autopilot`).

- mem_safety:

  Safety multiplier applied to observed peak RSS when computing
  recommended `--mem`. Default `1.25`.

- time_safety:

  Safety multiplier applied to observed max walltime when computing
  recommended `--time`. Default `1.35`.

- mem_min_mb:

  Minimum recommended `--mem` in MB. Default `256L`.

- mem_round_mb:

  Rounding granularity in MB for recommended `--mem`. Default `128L`.

- time_min_minutes:

  Minimum recommended `--time` in minutes. Default `5`.

- time_round_minutes:

  Rounding granularity in minutes for recommended `--time`. Default `5`.

## Value

An S3 object of class `"slurmpilot_efficiency"` containing:

- `classification`: one of `"efficient"`, `"over_provisioned"`,
  `"under_provisioned"`, or `"imbalanced"`.

- `metrics`: named list of utilization, waste, slack, straggler ratio,
  and failure counts.

- `chunks`: per-chunk telemetry tibble with `mem_util_pct` and
  `time_util_pct`.

- `requested_resources`: original `slurmpilot_resources` spec.

- `recommended_resources`: tightened (or escalated)
  `slurmpilot_resources` spec for the next run.

- `recommendations`: character vector of concrete optimization actions.

## See also

[`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md),
[`parse_sacct_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_sacct_output.md),
[`plan_chunks()`](https://marcusharrisphd.com/slurmpilot/reference/plan_chunks.md)

## Examples

``` r
be <- mock_slurm_backend(max_workers = 2L)
res <- resource_spec(n_tasks = 6L, chunk_size = 2L, mem_mb = 2048L, time_minutes = 30)
job <- slurm_submit(be, function(x) mean(rnorm(200)), as.list(1:6), resources = res)
slurm_wait(job, poll_interval = 0.05)
#> 
#> ── slurmpilot Job Status: slurmpilot_job [COMPLETED] 
#> • Progress: 3/3 chunks (100%) | running=0, pending=0, failed=0, oom=0,
#>   timeout=0, cancelled=0
#> • Peak RSS max: 112.3 MB | Cumulative walltime: 2.26s
eff <- slurm_efficiency_report(job)
print(eff)
#> 
#> ── slurmpilot Post-Mortem Efficiency Audit: slurmpilot_job [over_provisioned] 
#> • Memory: 112.3 MB max / 2048 MB req (5.5% util, 94.5% waste)
#> • Walltime: 1.0s max / 1800s req (0.1% util, 99.9% slack)
#> • Load balance: straggler ratio 1.30x across 3 chunks
#> • Recommended next flags: --array=1-3 --cpus-per-task=1 --mem=256M
#>   --time=00:05:00
#> ℹ Memory waste is 94.5% (peak 112.3 MB vs 2G requested); tighten --mem to 256M.
#> ℹ Walltime slack is 99.9% (max 1.0s vs 00:30:00 requested); tighten --time to
#>   00:05:00.
unlink(be$root_dir, recursive = TRUE)
```
