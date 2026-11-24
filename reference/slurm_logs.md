# Retrieve Stdout and Stderr Logs for a Submitted Job

Retrieve Stdout and Stderr Logs for a Submitted Job

## Usage

``` r
slurm_logs(job, chunk_id = NULL)
```

## Arguments

- job:

  A `slurmpilot_job` handle.

- chunk_id:

  Optional integer chunk ID (default `NULL` retrieves all chunks).

## Value

Named list of chunk log records (`chunk_id`, `stdout`, `stderr`).

## Examples

``` r
be <- mock_slurm_backend(max_workers = 1L)
job <- slurm_submit(be, function(x) x + 1, as.list(1:2),
                    resources = resource_spec(2L, chunk_size = 2L))
slurm_wait(job, poll_interval = 0.05)
#> 
#> ── slurmpilot Job Status: slurmpilot_job [COMPLETED] 
#> • Progress: 1/1 chunks (100%) | running=0, pending=0, failed=0, oom=0,
#>   timeout=0, cancelled=0
#> • Peak RSS max: 108.0 MB | Cumulative walltime: 0.49s
slurm_logs(job, chunk_id = 1L)$chunk_1$stdout
#> [1] "[slurmpilot] Chunk 1 (attempt 1): running 2 task(s) [1,2]\n[slurmpilot] Chunk 1 finished with state=COMPLETED in 0.49s"
unlink(be$root_dir, recursive = TRUE)
```
