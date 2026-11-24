# Retrieve Per-Chunk Surgical Retry Provenance for a Job

Returns a tidy tibble recording every surgical retry round executed via
[`slurm_retry()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_retry.md),
including chunk IDs, triggering failure states, memory and walltime
escalation transitions, and timestamps.

## Usage

``` r
slurm_retry_history(job)
```

## Arguments

- job:

  A `slurmpilot_job` handle.

## Value

A
[`tibble::tibble()`](https://tibble.tidyverse.org/reference/tibble.html)
with columns `retry_round`, `timestamp`, `chunk_id`, `trigger_state`,
`old_mem_mb`, `new_mem_mb`, `old_time_sec`, `new_time_sec`, and
`adaptive`.

## See also

[`slurm_retry()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_retry.md)

## Examples

``` r
be <- mock_slurm_backend(max_workers = 1L)
job <- slurm_submit(be, function(x) x, as.list(1:2))
slurm_wait(job, poll_interval = 0.05)
#> 
#> ── slurmpilot Job Status: slurmpilot_job [COMPLETED] 
#> • Progress: 2/2 chunks (100%) | running=0, pending=0, failed=0, oom=0,
#>   timeout=0, cancelled=0
#> • Peak RSS max: 120.5 MB | Cumulative walltime: 0.97s
slurm_retry_history(job)
#> # A tibble: 0 × 9
#> # ℹ 9 variables: retry_round <int>, timestamp <chr>, chunk_id <int>,
#> #   trigger_state <chr>, old_mem_mb <int>, new_mem_mb <int>,
#> #   old_time_sec <int>, new_time_sec <int>, adaptive <lgl>
unlink(be$root_dir, recursive = TRUE)
```
