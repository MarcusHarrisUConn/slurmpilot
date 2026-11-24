# slurmpilot

> **Auto-profiling 'SLURM' HPC job orchestration, 'Apptainer' packaging, and non-blocking 'Shiny' compute offloading for compute-heavy R workflows.**

`slurmpilot` eliminates manual SLURM scripting, blind `--mem`/`--time` guessing, fragile container builds, correlated parallel RNG streams, and frozen Shiny servers for computational statistics workflows (Monte Carlo power studies, Bayesian MCMC, mixed-effects/DSEM models, and large-scale bootstraps).

## Four Core Pillars

1. **Empirical Micro-Pilot Auto-Profiler & Load Balancer (`pilot_run()`, `estimate_resources()`, `plan_chunks()`, `inspect_job_globals()`):**
   Runs a controlled sample slice in isolated child R processes (`callr`) while continuously sampling OS-level process-tree Resident Set Size (RSS) via `ps`. Separates cold startup overhead from marginal per-task runtime, fits a heavy-tail-safe walltime envelope (normal CLT + Fenton-Wilkinson log-normal sum + nonparametric tail guard), supports Longest Processing Time (`"lpt"`) load balancing for heterogeneous workloads, and audits closures/globals for >50 MB bloat before staging.
2. **HPC Environment & Apptainer Packager (`scan_project_env()`, `build_apptainer_def()`, `render_sbatch_script()`, `render_worker_script()`):**
   Scans `renv.lock`, `DESCRIPTION`, and R/Rmd/Quarto scripts, detects compiled toolchains (`Rcpp`, `cmdstanr`, `RTMB`, `TMB`, `rstan`, `JAGS`, `sf`, `lme4`, `arrow`), and emits hardened Apptainer/Singularity `.def` recipes, self-contained SLURM array `sbatch` scripts, and a zero-dependency base-R `worker.R` runner with independent `L'Ecuyer-CMRG` parallel RNG streams (`slurmpilot_rng_stream()`).
3. **Pluggable Scheduler Backend + Local Mock SLURM (`MockSlurmBackend`, `SlurmSshBackend`):**
   Develop and test the entire cluster lifecycle locally via `MockSlurmBackend` (real parallel background R workers via `processx`, queue slot throttling, live RSS/timeout enforcement, atomic SHA-256 checkpoints verified by `verify_checkpoint()`, fault injection, and adaptive OOM/timeout retry escalation via `slurm_retry()` + `slurm_retry_history()`), then switch to `SlurmSshBackend` (firewall-safe SSH/SCP with bounded exponential backoff and strict CLI injection defenses) with zero workflow changes.
4. **Non-Blocking Shiny Offload Modules (`mod_hpc_submit_*`, `mod_hpc_monitor_*`, `run_demo_app()`):**
   Drop-in `bslib`/Shiny modules executing micro-piloting and cluster submission asynchronously without freezing the Shiny session, with XSS-safe rendering, live KPI value boxes, multi-segment chunk progress bars, adaptive retry buttons, cancellation controls, and chunk logs.

## Installation

```r
# Install development version from GitHub
# install.packages("remotes")
remotes::install_github("MarcusHarrisUConn/slurmpilot")
```

## Quick Start: Laptop Micro-Pilot to Cluster Execution

```r
library(slurmpilot)

# 1. Define a compute workload and audit globals/closures
args <- lapply(1:16, function(i) list(task_id = i, n = 60, delta = 0.35, reps = 60))
worker <- function(cfg) {
  rejects <- replicate(cfg$reps, {
    stats::t.test(stats::rnorm(cfg$n, cfg$delta), stats::rnorm(cfg$n, 0))$p.value < 0.05
  })
  data.frame(task_id = cfg$task_id, power = mean(rejects))
}
inspect_job_globals(worker, args_list = args)

# 2. Empirically profile 3 replications in isolated child processes
pilot <- pilot_run(worker, args, n_pilot = 3L, sample_method = "stratified", seed = 42L)

# 3. Auto-size optimal SLURM array chunking, --mem, and --time
resources <- estimate_resources(pilot, n_tasks = length(args), max_chunk_size = 4L)

# 4. Run locally on MockSlurmBackend (or switch to slurm_ssh_backend() for HPC)
backend <- mock_slurm_backend(max_workers = 2L)
job <- slurm_submit(backend, worker, args, resources = resources, name = "mc_power", seed = 42L)
status <- slurm_wait(job, progress = TRUE)
results <- slurm_collect(job, simplify = TRUE)
```

Or run the entire pipeline—including automatic adaptive retries on OOM/timeout chunks—in a single call:

```r
run <- slurm_autopilot(
  fun = worker,
  args_list = args,
  backend = mock_slurm_backend(max_workers = 2L),
  n_pilot = 3L,
  max_chunk_size = 4L,
  auto_retry = 1L,
  simplify = TRUE
)
```

## Documentation & Vignettes

- Website: <https://marcusharrisphd.com/slurmpilot/>
- `vignette("getting-started", package = "slurmpilot")`
- `vignette("pilot-to-cluster", package = "slurmpilot")`
- `vignette("apptainer-ssh-shiny", package = "slurmpilot")`
- `vignette("troubleshooting-and-retries", package = "slurmpilot")`
- `vignette("pipelines-and-efficiency", package = "slurmpilot")`
- Architecture & security audit: see `ARCHITECTURE.md` and `SECURITY.md`

## License

MIT (c) 2026 Marcus Harris
