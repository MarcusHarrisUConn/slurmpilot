# Cancel Active Chunks of a Submitted Job

Cancel Active Chunks of a Submitted Job

## Usage

``` r
slurm_cancel(job, chunks = NULL)
```

## Arguments

- job:

  A `slurmpilot_job` handle.

- chunks:

  Optional integer vector of chunk IDs to cancel (defaults to all
  pending/running chunks).

## Value

Latest `slurmpilot_status` invisibly.

## Examples

``` r
be <- mock_slurm_backend(max_workers = 1L, queue_delay = 0.2)
job <- slurm_submit(be, function(x) { Sys.sleep(2); x }, as.list(1:2))
st <- slurm_cancel(job)
st$state
#> [1] "CANCELLED"
unlink(be$root_dir, recursive = TRUE)
```
