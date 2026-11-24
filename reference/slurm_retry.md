# Surgically Retry Failed, OOM, Timed-Out, or Cancelled Chunks

Resubmits only unsuccessful array chunks while preserving
already-completed chunk checkpoints on disk. Supports **adaptive
resource escalation**: when `adaptive = TRUE` (default), chunks that
failed with `OUT_OF_MEMORY` automatically scale `--mem` by
`auto_mem_multiplier` (capped at `max_mem_mb`) and chunks that failed
with `TIMEOUT` automatically scale `--time` by `auto_time_multiplier`
(capped at `max_time_minutes`). Records per-chunk retry provenance
accessible via
[`slurm_retry_history()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_retry_history.md).

## Usage

``` r
slurm_retry(
  job,
  chunks = NULL,
  mem_multiplier = NULL,
  time_multiplier = NULL,
  resources = NULL,
  adaptive = TRUE,
  auto_mem_multiplier = 1.5,
  auto_time_multiplier = 1.5,
  max_mem_mb = 524288L,
  max_time_minutes = 10080
)
```

## Arguments

- job:

  A `slurmpilot_job` handle.

- chunks:

  Optional integer vector of chunk IDs to retry. Defaults to all chunks
  currently in `FAILED`, `OUT_OF_MEMORY`, `TIMEOUT`, or `CANCELLED`.

- mem_multiplier:

  Optional explicit numeric multiplier to bump `--mem` on retry
  (overrides adaptive OOM scaling when supplied).

- time_multiplier:

  Optional explicit numeric multiplier to bump `--time` on retry
  (overrides adaptive TIMEOUT scaling when supplied).

- resources:

  Optional explicit replacement `slurmpilot_resources` object (takes
  precedence over multipliers and adaptive escalation).

- adaptive:

  Logical; if `TRUE` (default), automatically escalates `--mem` for
  `OUT_OF_MEMORY` failures and `--time` for `TIMEOUT` failures.

- auto_mem_multiplier:

  Adaptive `--mem` escalation factor for `OUT_OF_MEMORY` chunks. Default
  `1.5`.

- auto_time_multiplier:

  Adaptive `--time` escalation factor for `TIMEOUT` chunks. Default
  `1.5`.

- max_mem_mb:

  Maximum memory ceiling in MB for adaptive escalation. Default
  `524288L` (512 GiB).

- max_time_minutes:

  Maximum walltime ceiling in minutes for adaptive escalation. Default
  `10080` (7 days).

## Value

Updated `slurmpilot_job` handle with appended `$retry_history`
provenance.

## See also

[`slurm_retry_history()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_retry_history.md),
[`scale_resources()`](https://marcusharrisphd.com/slurmpilot/reference/scale_resources.md)

## Examples

``` r
be <- mock_slurm_backend(max_workers = 1L)
job <- slurm_submit(
  be, function(x) x^2, as.list(1:4),
  resources = resource_spec(4L, chunk_size = 2L, mem_mb = 512L),
  fault_injection = list(oom_chunks = 2L, fail_once = TRUE)
)
slurm_wait(job, poll_interval = 0.05)
#> 
#> ── slurmpilot Job Status: slurmpilot_job [PARTIAL_FAILURE] 
#> • Progress: 1/2 chunks (50%) | running=0, pending=0, failed=0, oom=1,
#>   timeout=0, cancelled=0
#> • Peak RSS max: 104.6 MB | Cumulative walltime: 0.98s
job <- slurm_retry(job)
slurm_wait(job, poll_interval = 0.05)
#> 
#> ── slurmpilot Job Status: slurmpilot_job [COMPLETED] 
#> • Progress: 2/2 chunks (100%) | running=0, pending=0, failed=0, oom=0,
#>   timeout=0, cancelled=0
#> • Peak RSS max: 106.9 MB | Cumulative walltime: 0.98s
slurm_retry_history(job)
#> # A tibble: 1 × 9
#>   retry_round timestamp             chunk_id trigger_state old_mem_mb new_mem_mb
#>         <int> <chr>                    <int> <chr>              <int>      <int>
#> 1           1 2026-11-24T19:33:28.…        2 OUT_OF_MEMORY        512        768
#> # ℹ 3 more variables: old_time_sec <int>, new_time_sec <int>, adaptive <lgl>
unlink(be$root_dir, recursive = TRUE)
```
