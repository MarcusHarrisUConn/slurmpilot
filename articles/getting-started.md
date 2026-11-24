# Getting Started with slurmpilot

## Why `slurmpilot`?

Running large Monte Carlo power studies, hierarchical models, or
bootstraps on a SLURM cluster usually forces researchers into manual
batch scripting and blind guesses for `--mem`, `--time`, and array
chunking. `slurmpilot` replaces that guesswork with an empirical,
reproducible four-stage pipeline:

1.  **Micro-pilot profiling
    ([`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md)):**
    Executes a small sample slice in isolated child R processes while
    polling real OS resident memory (RSS) via `ps`.
2.  **Resource auto-sizing
    ([`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md)):**
    Computes optimal array chunk sizes, `--mem`, `--time`, and
    `--cpus-per-task` flags with tail-safe margins.
3.  **Pluggable execution (`MockSlurmBackend` / `SlurmSshBackend`):**
    Develop and test the complete lifecycle locally in parallel
    background R processes on a laptop, then switch to SSH/SLURM with
    zero workflow rewrites.
4.  **Atomic checkpoints & surgical retries
    ([`slurm_retry()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_retry.md),
    [`slurm_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_collect.md)):**
    Every chunk writes an atomic `.rds` checkpoint protected by a
    SHA-256 sidecar so failed or OOM chunks retry cleanly without
    recomputing completed work.

## Quickstart: Five-Minute Local-to-Cluster Pipeline

Define a lightweight simulation task list and worker function:

``` r

library(slurmpilot)

tasks <- lapply(seq_len(12L), function(i) {
  list(task_id = i, n = 60L, effect = 0.35, reps = 50L)
})

power_worker <- function(cfg) {
  rejects <- replicate(cfg$reps, {
    x <- stats::rnorm(cfg$n, mean = 0, sd = 1)
    y <- stats::rnorm(cfg$n, mean = cfg$effect, sd = 1)
    stats::t.test(y, x)$p.value < 0.05
  })
  data.frame(
    task_id = cfg$task_id,
    empirical_power = mean(rejects)
  )
}
```

Before staging a workload, run
[`inspect_job_globals()`](https://marcusharrisphd.com/slurmpilot/reference/inspect_job_globals.md)
to verify that your worker does not accidentally capture large local
objects or miss helper functions:

``` r

audit <- inspect_job_globals(power_worker, args_list = tasks)
print(audit)
#> 
#> ── slurmpilot Pre-Submit Globals & Bundle Audit [OK]
#> • Estimated payload size: 0.01 MB (closure=0.00 MB, globals=0.00 MB, args=0.00
#>   MB)
#> • Captured local closure objects: 0 | Explicit globals: 0
#> • Unresolved variables: 0 | Unexported functions: 0
```

Now run a quick empirical micro-pilot (`n_pilot = 2L`), auto-size SLURM
resources, and execute on `MockSlurmBackend` (strictly capped at 2 local
workers):

``` r

pilot <- pilot_run(
  fun = power_worker,
  args_list = tasks,
  n_pilot = 2L,
  seed = 2026L
)
print(pilot)
#> 
#> ── slurmpilot Micro-Pilot Profile
#> • Trials: 2/2 succeeded (isolated=TRUE, cpus=1)
#> • Task exec time: median 0.011s, p90 0.011s, max 0.011s
#> • Worker startup: median 0.282s
#> • Memory (RSS): baseline 76.3 MB, peak max 76.8 MB, net max 0.4 MB

resources <- estimate_resources(
  pilot = pilot,
  n_tasks = length(tasks),
  max_chunk_size = 4L
)
print(resources)
#> 
#> ── slurmpilot SLURM Resource Plan
#> • Workload: 12 tasks -> 3 array chunks (4 tasks/chunk)
#> • SLURM flags: --array=1-3 --cpus-per-task=1 --mem=512M --time=00:05:00
#> ℹ Predicted chunk walltime: 0.3s (expected 0.3s, startup overhead 86.5%)
#> ℹ Predicted peak RSS: 84.5 MB -> requested 512M
#> ℹ Estimated total compute: 0.00 CPU-hours

tmp_root <- tempfile("sp_gs_")
backend <- mock_slurm_backend(root_dir = tmp_root, max_workers = 2L)

job <- slurm_submit(
  backend = backend,
  fun = power_worker,
  args_list = tasks,
  resources = resources,
  name = "quickstart_power",
  seed = 2026L
)

status <- slurm_wait(job, timeout = 30, poll_interval = 0.05)
print(status)
#> 
#> ── slurmpilot Job Status: quickstart_power [COMPLETED]
#> • Progress: 3/3 chunks (100%) | running=0, pending=0, failed=0, oom=0,
#>   timeout=0, cancelled=0
#> • Peak RSS max: 73.5 MB | Cumulative walltime: 0.27s

results <- slurm_collect(job, simplify = TRUE)
head(results)
#> # A tibble: 6 × 2
#>   task_id empirical_power
#>     <int>           <dbl>
#> 1       1            0.46
#> 2       2            0.48
#> 3       3            0.42
#> 4       4            0.52
#> 5       5            0.48
#> 6       6            0.38
```

## One-Call Autopilot

For everyday runs,
[`slurm_autopilot()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_autopilot.md)
orchestrates piloting, sizing, submission, waiting, automatic adaptive
retries, and result collection in one function call:

``` r

tmp_auto <- tempfile("sp_auto_")
auto_backend <- mock_slurm_backend(root_dir = tmp_auto, max_workers = 2L)

run <- slurm_autopilot(
  fun = function(x) data.frame(id = x, squared = x^2),
  args_list = as.list(seq_len(8L)),
  backend = auto_backend,
  n_pilot = 2L,
  max_chunk_size = 4L,
  auto_retry = 1L,
  simplify = TRUE,
  poll_interval = 0.05
)

print(run)
#> 
#> ── slurmpilot Autopilot Run
#> • Job: autopilot_job [COMPLETED] (2/2 chunks)
#> • Recommended SLURM flags: --array=1-2 --cpus-per-task=1 --mem=512M
#>   --time=00:05:00
#> • Results collected: TRUE
run$results
#> # A tibble: 8 × 2
#>      id squared
#>   <int>   <dbl>
#> 1     1       1
#> 2     2       4
#> 3     3       9
#> 4     4      16
#> 5     5      25
#> 6     6      36
#> 7     7      49
#> 8     8      64

unlink(c(tmp_root, tmp_auto), recursive = TRUE)
```

## Next Steps

- See
  [`vignette("pilot-to-cluster", package = "slurmpilot")`](https://marcusharrisphd.com/slurmpilot/articles/pilot-to-cluster.md)
  for heavy-tailed runtime modeling, Longest Processing Time (LPT) load
  balancing for heterogeneous tasks, and closure auditing.
- See
  [`vignette("apptainer-ssh-shiny", package = "slurmpilot")`](https://marcusharrisphd.com/slurmpilot/articles/apptainer-ssh-shiny.md)
  for Apptainer container generation, remote SSH/SLURM execution, and
  non-blocking Shiny offloading.
- See
  [`vignette("troubleshooting-and-retries", package = "slurmpilot")`](https://marcusharrisphd.com/slurmpilot/articles/troubleshooting-and-retries.md)
  for adaptive OOM/timeout recovery, SHA-256 checkpoint verification,
  and independent `L'Ecuyer-CMRG` parallel random streams.
