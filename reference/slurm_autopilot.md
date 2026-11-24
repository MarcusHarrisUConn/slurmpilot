# End-to-End Micro-Pilot to Cluster Autopilot

Executes the complete `slurmpilot` lifecycle in one call:

1.  Runs
    [`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md)
    on a controlled sample slice to empirically measure startup
    overhead, task runtime distribution, and OS peak RSS.

2.  Calls
    [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md)
    to size SLURM array chunking, `--mem`, and `--time`.

3.  Submits the full workload via
    [`slurm_submit()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_submit.md)
    on `backend`.

4.  Optionally waits for completion, performs automatic surgical retries
    on failed chunks (auto-scaling `--mem` on OOM and `--time` on
    TIMEOUT), and collects ordered results.

## Usage

``` r
slurm_autopilot(
  fun,
  args_list,
  backend,
  n_pilot = NULL,
  sample_method = c("head", "stratified", "random"),
  target_chunk_minutes = 15,
  max_array_size = 1000L,
  min_chunk_size = 1L,
  max_chunk_size = NULL,
  mem_safety = 1.35,
  time_safety = 1.5,
  cpus_per_task = 1L,
  strategy = c("contiguous", "round_robin", "lpt"),
  task_weights = NULL,
  name = NULL,
  packages = character(),
  globals = list(),
  seed = NULL,
  isolate = TRUE,
  wait = TRUE,
  auto_retry = 0L,
  retry_mem_multiplier = 1.5,
  retry_time_multiplier = 1.5,
  simplify = FALSE,
  poll_interval = 0.15,
  progress = FALSE,
  ...
)
```

## Arguments

- fun:

  A function accepting a single element of `args_list` (`fun(arg)`).

- args_list:

  Non-empty list (or vector coercible to list) of per-task arguments.

- backend:

  A
  [SlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.md)
  object (e.g.
  [`mock_slurm_backend()`](https://marcusharrisphd.com/slurmpilot/reference/mock_slurm_backend.md)
  or
  [`slurm_ssh_backend()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_ssh_backend.md)).

- n_pilot:

  Optional positive integer number of sample replications to profile.
  Defaults to `min(length(args_list), 5L)`.

- sample_method:

  Strategy for selecting pilot task indices from `args_list`: `"head"`
  (first `n_pilot`), `"stratified"` (evenly spaced across the workload),
  or `"random"`.

- target_chunk_minutes:

  Target walltime in minutes per SLURM array task. Default `15`.

- max_array_size:

  Maximum number of SLURM array indices allowed by the cluster
  (`MaxArraySize`). Default `1000L`.

- min_chunk_size:

  Minimum tasks per SLURM array chunk. Default `1L`.

- max_chunk_size:

  Optional maximum tasks per SLURM array chunk.

- mem_safety:

  Multiplicative safety factor applied to predicted peak RSS. Default
  `1.35`.

- time_safety:

  Multiplicative safety factor applied to predicted upper walltime.
  Default `1.50`.

- cpus_per_task:

  Integer number of CPU threads exposed to each pilot trial
  (`OMP_NUM_THREADS` / `OPENBLAS_NUM_THREADS`). Default `1L`.

- strategy:

  Chunk assignment strategy: `"contiguous"` (default), `"round_robin"`,
  or `"lpt"` (Longest Processing Time first load balancing for
  heterogeneous task workloads).

- task_weights:

  Optional positive numeric vector of length `n_tasks` providing
  relative per-task runtime/cost weights for `"lpt"` load balancing.
  When `strategy = "lpt"` and `task_weights = NULL`, weights are
  interpolated linearly from the pilot trials across `1:n_tasks` (or
  fall back to uniform weights if fewer than 2 distinct pilot indices
  exist).

- name:

  Optional job name.

- packages:

  Character vector of package names to attach inside each isolated
  worker before executing `fun`.

- globals:

  Named list of helper objects or functions made available in `fun`'s
  evaluation environment.

- seed:

  Optional integer base seed for reproducible sampling and child trial
  execution.

- isolate:

  Logical; if `TRUE` (default), runs each trial in a fresh background R
  process via
  [`callr::r_bg()`](https://callr.r-lib.org/reference/r_bg.html) to
  measure true startup cost and isolated OS RSS. Set `FALSE` only for
  fast in-process profiling.

- wait:

  Logical; wait for completion and collect results. Default `TRUE`.

- auto_retry:

  Non-negative integer maximum automatic surgical retry rounds when
  chunks fail. Default `0L`.

- retry_mem_multiplier:

  Memory scale factor applied when automatically retrying
  `OUT_OF_MEMORY` chunks. Default `1.5`.

- retry_time_multiplier:

  Walltime scale factor applied when automatically retrying `TIMEOUT`
  chunks. Default `1.5`.

- simplify:

  Logical passed to
  [`slurm_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_collect.md).
  Default `FALSE`.

- poll_interval:

  Polling interval in seconds passed to
  [`slurm_wait()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_wait.md).
  Default `0.15`.

- progress:

  Logical; if `TRUE`, emits concise progress messages via `cli`. Default
  `FALSE`.

- ...:

  Additional arguments passed to
  [`slurm_submit()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_submit.md).

## Value

An S3 object of class `"slurmpilot_autopilot"` containing `pilot`,
`resources`, `job`, `status`, and `results` (when `wait = TRUE`).

## Examples

``` r
backend <- mock_slurm_backend(max_workers = 2L)
run <- slurm_autopilot(
  fun = function(x) x$a + x$b,
  args_list = lapply(1:6, function(i) list(a = i, b = 10)),
  backend = backend,
  n_pilot = 2L,
  max_chunk_size = 3L,
  simplify = TRUE
)
run$results
#> [1] 11 12 13 14 15 16
unlink(backend$root_dir, recursive = TRUE)
```
