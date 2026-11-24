# Execute a Multi-Stage SLURM Pipeline DAG

Runs a validated
[`slurm_pipeline()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline.md)
in topological order on any
[SlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.md).

- On
  [MockSlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/MockSlurmBackend.md)
  (or any backend with `wait = TRUE`), each stage runs after its
  upstream dependencies satisfy `dependency_type`, collects upstream
  results cleanly, and forwards them to downstream stages via
  `args_from_upstream` or fan-in aggregation.

- On
  [SlurmSshBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmSshBackend.md)
  with `wait = FALSE`, stages are submitted directly to SLURM with
  genuine `#SBATCH --dependency=afterok:<jobid1>:<jobid2>` flags so the
  HPC scheduler enforces DAG ordering cluster-side.

## Usage

``` r
slurm_pipeline_run(
  pipeline,
  backend,
  wait = TRUE,
  poll_interval = 0.08,
  timeout = Inf,
  auto_retry = 0L,
  stop_on_failure = TRUE,
  progress = FALSE
)
```

## Arguments

- pipeline:

  A `slurmpilot_pipeline` object from
  [`slurm_pipeline()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline.md).

- backend:

  A
  [SlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.md)
  object
  ([MockSlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/MockSlurmBackend.md)
  or
  [SlurmSshBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmSshBackend.md)).

- wait:

  Logical; wait for each stage to finish and pass results downstream
  (`TRUE`, default), or submit the full DAG asynchronously using SLURM
  `--dependency` flags (`FALSE`, supported for static-argument stages on
  [SlurmSshBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmSshBackend.md)).

- poll_interval:

  Polling interval in seconds passed to
  [`slurm_wait()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_wait.md).
  Default `0.08`.

- timeout:

  Per-stage timeout in seconds passed to
  [`slurm_wait()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_wait.md).
  Default `Inf`.

- auto_retry:

  Non-negative integer adaptive retry rounds per stage when
  `wait = TRUE`. Default `0L`.

- stop_on_failure:

  Logical; when `TRUE` (default), skips downstream `afterok` stages if
  an upstream stage fails instead of aborting.

- progress:

  Logical; emit stage progress messages via `cli`. Default `FALSE`.

## Value

An S3 object of class `"slurmpilot_pipeline_run"` containing `pipeline`,
`backend`, `jobs`, `stage_states`, `results`, `dependencies_submitted`,
`started_at`, and `finished_at`.

## See also

[`slurm_pipeline()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline.md),
[`slurm_pipeline_status()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_status.md),
[`slurm_pipeline_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_collect.md)

## Examples

``` r
s1 <- slurm_stage("sim", fun = function(x) x^2, args_list = as.list(1:4))
s2 <- slurm_stage("agg", fun = function(up) sum(up$sim), depends_on = "sim")
pipe <- slurm_pipeline(s1, s2, name = "two_stage")
be <- mock_slurm_backend(max_workers = 2L)
run <- slurm_pipeline_run(pipe, be, poll_interval = 0.05)
slurm_pipeline_collect(run)
#> [[1]]
#> [1] 30
#> 
unlink(be$root_dir, recursive = TRUE)
```
