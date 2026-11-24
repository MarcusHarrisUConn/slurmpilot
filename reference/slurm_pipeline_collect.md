# Collect Results from a Completed SLURM Pipeline Run

Retrieves collected outputs from a named stage or automatically from the
terminal sink stage(s) of a
[`slurm_pipeline_run()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_run.md).

## Usage

``` r
slurm_pipeline_collect(
  run,
  stage = NULL,
  simplify = FALSE,
  allow_partial = FALSE
)
```

## Arguments

- run:

  A `slurmpilot_pipeline_run` object.

- stage:

  Optional character stage name to collect. When `NULL` (default),
  collects the single sink stage directly (or returns a named list if
  the DAG has multiple sink stages).

- simplify:

  Logical; simplify results when fetching freshly from a stage job.
  Default `FALSE`.

- allow_partial:

  Logical; allow collecting incomplete stage results. Default `FALSE`.

## Value

Collected results for the requested stage (or named list across multiple
sink stages).

## See also

[`slurm_pipeline_run()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_run.md),
[`slurm_pipeline_status()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_status.md)

## Examples

``` r
s1 <- slurm_stage("a", fun = function(x) x * 2, args_list = as.list(1:3))
s2 <- slurm_stage("b", fun = function(up) sum(up$a), depends_on = "a")
pipe <- slurm_pipeline(s1, s2, name = "collect_demo")
be <- mock_slurm_backend(max_workers = 1L)
run <- slurm_pipeline_run(pipe, be, poll_interval = 0.05)
slurm_pipeline_collect(run, simplify = TRUE)
#> [1] 12
unlink(be$root_dir, recursive = TRUE)
```
