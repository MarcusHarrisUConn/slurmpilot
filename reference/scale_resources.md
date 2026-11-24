# Scale Memory and/or Walltime of a Resource Specification

Creates a copy of a `slurmpilot_resources` specification with memory
and/or walltime scaled by positive multipliers, commonly used when
surgically retrying failed `OUT_OF_MEMORY` or `TIMEOUT` chunks.
Preserves exact chunk-to-task assignments.

## Usage

``` r
scale_resources(
  resources,
  mem_multiplier = 1,
  time_multiplier = 1,
  mem_round_mb = 256,
  time_round_minutes = 1
)
```

## Arguments

- resources:

  A `slurmpilot_resources` object.

- mem_multiplier:

  Positive numeric multiplier for `mem_mb`. Default `1`.

- time_multiplier:

  Positive numeric multiplier for `time_sec`. Default `1`.

- mem_round_mb:

  Rounding granularity in MB. Default `256`.

- time_round_minutes:

  Rounding granularity in minutes. Default `1`.

## Value

Updated `slurmpilot_resources` object.

## Examples

``` r
base <- resource_spec(n_tasks = 20, chunk_size = 5, mem_mb = 1024, time_minutes = 10)
bumped <- scale_resources(base, mem_multiplier = 1.5, time_multiplier = 2.0)
as_slurm_flags(bumped)
#> [1] "--array=1-4"       "--cpus-per-task=1" "--mem=1536M"      
#> [4] "--time=00:20:00"  
```
