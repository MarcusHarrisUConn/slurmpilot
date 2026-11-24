# Poll Current Status of a Submitted Job

Poll Current Status of a Submitted Job

## Usage

``` r
slurm_status(job)
```

## Arguments

- job:

  A `slurmpilot_job` handle returned by
  [`slurm_submit()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_submit.md).

## Value

A `slurmpilot_status` object with aggregate job state and a per-chunk
telemetry tibble (`$chunks`).

## Examples

``` r
be <- mock_slurm_backend(max_workers = 1L)
job <- slurm_submit(be, function(x) x * 2, as.list(1:2))
st <- slurm_wait(job, poll_interval = 0.05)
slurm_status(job)$state
#> [1] "COMPLETED"
unlink(be$root_dir, recursive = TRUE)
```
