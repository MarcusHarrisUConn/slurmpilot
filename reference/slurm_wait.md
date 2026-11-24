# Wait for a Job to Reach a Terminal State

Wait for a Job to Reach a Terminal State

## Usage

``` r
slurm_wait(job, timeout = Inf, poll_interval = 0.2, progress = FALSE)
```

## Arguments

- job:

  A `slurmpilot_job` handle.

- timeout:

  Maximum wait time in seconds. Default `Inf`.

- poll_interval:

  Polling interval in seconds. Default `0.2`.

- progress:

  Logical; print progress updates when chunks complete. Default `FALSE`.

## Value

A `slurmpilot_status` object.

## Examples

``` r
be <- mock_slurm_backend(max_workers = 1L)
job <- slurm_submit(be, function(x) x + 1, as.list(1:2),
                    resources = resource_spec(2L, chunk_size = 2L))
st <- slurm_wait(job, poll_interval = 0.05)
st$state
#> [1] "COMPLETED"
unlink(be$root_dir, recursive = TRUE)
```
