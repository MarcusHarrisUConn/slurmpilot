# Construct an Explicit SLURM Resource Specification

Creates a validated `slurmpilot_resources` object directly from
user-chosen chunk size, memory, walltime, and scheduler flags (without
requiring a micro-pilot run).

## Usage

``` r
resource_spec(
  n_tasks,
  chunk_size = 1L,
  mem_mb = 1024,
  time_minutes = 15,
  cpus_per_task = 1L,
  partition = NULL,
  account = NULL,
  qos = NULL,
  max_concurrent = NULL,
  strategy = c("contiguous", "round_robin", "lpt"),
  task_weights = NULL
)
```

## Arguments

- n_tasks:

  Positive integer total number of tasks.

- chunk_size:

  Positive integer number of tasks grouped into each SLURM array chunk.
  Default `1L`.

- mem_mb:

  Numeric memory limit per array task in MB. Default `1024`.

- time_minutes:

  Numeric walltime limit per array task in minutes. Default `15`.

- cpus_per_task:

  Positive integer CPU cores per array task. Default `1L`.

- partition:

  Optional SLURM `--partition`.

- account:

  Optional SLURM `--account`.

- qos:

  Optional SLURM `--qos`.

- max_concurrent:

  Optional positive integer array concurrency cap.

- strategy:

  Chunk assignment strategy: `"contiguous"` (default), `"round_robin"`,
  or `"lpt"`.

- task_weights:

  Optional positive numeric vector of length `n_tasks` required when
  `strategy = "lpt"`.

## Value

An S3 object of class `"slurmpilot_resources"`.

## See also

[`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md),
[`plan_chunks()`](https://marcusharrisphd.com/slurmpilot/reference/plan_chunks.md),
[`as_slurm_flags()`](https://marcusharrisphd.com/slurmpilot/reference/as_slurm_flags.md)

## Examples

``` r
spec <- resource_spec(n_tasks = 100, chunk_size = 10, mem_mb = 2048, time_minutes = 30)
as_slurm_flags(spec)
#> [1] "--array=1-10"      "--cpus-per-task=1" "--mem=2G"         
#> [4] "--time=00:30:00"  
```
