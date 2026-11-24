# Inspect Status Across All Stages of a SLURM Pipeline Run

Refreshes live scheduler telemetry for every submitted stage in a
`slurmpilot_pipeline_run` and returns a tidy per-stage and aggregate
status summary.

## Usage

``` r
slurm_pipeline_status(run)
```

## Arguments

- run:

  A `slurmpilot_pipeline_run` object returned by
  [`slurm_pipeline_run()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_run.md).

## Value

An S3 object of class `"slurmpilot_pipeline_status"` with
`pipeline_name`, `state`, stage counts, `progress`, and `stages` tibble.

## See also

[`slurm_pipeline_run()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_run.md),
[`slurm_pipeline_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_collect.md)

## Examples

``` r
s1 <- slurm_stage("step1", fun = function(x) x + 1, args_list = list(1, 2))
pipe <- slurm_pipeline(s1, name = "status_demo")
be <- mock_slurm_backend(max_workers = 1L)
run <- slurm_pipeline_run(pipe, be, poll_interval = 0.05)
slurm_pipeline_status(run)
#> 
#> ── slurmpilot Pipeline Status: status_demo [COMPLETED] 
#> • Stages completed: 1/1 (running=0, pending=0, failed=0, skipped=0)
unlink(be$root_dir, recursive = TRUE)
```
