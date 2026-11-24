# Collect Ordered Task Results from a Completed Job

Collect Ordered Task Results from a Completed Job

## Usage

``` r
slurm_collect(job, simplify = FALSE, allow_partial = FALSE)
```

## Arguments

- job:

  A `slurmpilot_job` handle.

- simplify:

  Logical; if `TRUE`, binds homogeneous data-frame results into a tibble
  or unlists homogeneous scalar atomic results. Default `FALSE`.

- allow_partial:

  Logical; if `TRUE`, returns available results even when some chunks
  are incomplete. Default `FALSE`.

## Value

Ordered list (or simplified vector/tibble) of task results.

## Examples

``` r
be <- mock_slurm_backend(max_workers = 1L)
job <- slurm_submit(be, function(x) x * 10, as.list(1:3),
                    resources = resource_spec(3L, chunk_size = 3L))
slurm_wait(job, poll_interval = 0.05)
#> 
#> ── slurmpilot Job Status: slurmpilot_job [COMPLETED] 
#> • Progress: 1/1 chunks (100%) | running=0, pending=0, failed=0, oom=0,
#>   timeout=0, cancelled=0
#> • Peak RSS max: 109.6 MB | Cumulative walltime: 0.49s
slurm_collect(job, simplify = TRUE)
#> [1] 10 20 30
unlink(be$root_dir, recursive = TRUE)
```
