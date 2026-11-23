# slurmpilot

> **Auto-profiling SLURM HPC job orchestration, Apptainer packaging, and non-blocking Shiny compute offloading for compute-heavy R workflows.**

`slurmpilot` eliminates manual SLURM scripting, blind `--mem`/`--time` guessing, fragile container builds, and frozen Shiny servers for computational statistics workflows (Monte Carlo power studies, Bayesian MCMC, mixed-effects/DSEM models, and large-scale bootstraps).

## Four Core Pillars

1. **Empirical Micro-Pilot Auto-Profiler (`pilot_run()`, `estimate_resources()`):**
   Runs a controlled sample slice in isolated child R processes (`callr`) while continuously sampling OS-level process-tree Resident Set Size (RSS) via `ps`. Separates cold startup overhead from marginal per-task runtime, fits a tail-aware scaling model, and outputs optimal SLURM array chunking (`--array`), `--mem`, `--time`, and `--cpus-per-task` with configurable safety margins.
2. **HPC Environment & Apptainer Packager (`scan_project_env()`, `build_apptainer_def()`, `render_sbatch_script()`):**
   Scans `renv.lock`, `DESCRIPTION`, and R/Quarto scripts, detects compiled toolchains (`Rcpp`, `cmdstanr`, `RTMB`, `TMB`, `rstan`, `JAGS`, `sf`, `lme4`, `arrow`), and generates reproducible Apptainer/Singularity `.def` recipes, self-contained SLURM array `sbatch` scripts, and a zero-dependency base-R `worker.R` runner.
3. **Pluggable Scheduler Backend + Local Mock SLURM (`MockSlurmBackend`, `SlurmSshBackend`):**
   Develop and test the entire cluster lifecycle locally on macOS/Linux via `MockSlurmBackend` (real parallel background R workers via `processx`, queue slot throttling, live RSS/timeout enforcement, disk checkpoints, fault injection, and surgical retry of failed chunks), then switch to `SlurmSshBackend` for production SSH/SLURM clusters with zero workflow changes.
4. **Non-Blocking Shiny Offload Modules (`mod_hpc_submit_*`, `mod_hpc_monitor_*`, `run_demo_app()`):**
   Drop-in `bslib`/Shiny modules that execute both micro-piloting and cluster submission asynchronously without freezing the Shiny session, displaying live KPI value boxes, multi-segment chunk progress bars, peak RSS gauges, surgical retry buttons, cancellation controls, and chunk logs.

## Installation

```r
# Install development version from GitHub
# install.packages("remotes")
remotes::install_github("MarcusHarrisUConn/slurmpilot")
```

## Quick Start: Laptop Micro-Pilot to Cluster Execution

```r
library(slurmpilot)

# 1. Define a compute workload (e.g., Monte Carlo power study)
args <- lapply(1:20, function(i) list(task_id = i, n = 80, delta = 0.35, reps = 100))
worker <- function(cfg) {
  rejects <- replicate(cfg$reps, {
    t.test(rnorm(cfg$n, cfg$delta), rnorm(cfg$n, 0))$p.value < 0.05
  })
  data.frame(task_id = cfg$task_id, power = mean(rejects))
}

# 2. Empirically profile 3 replications in isolated child processes
pilot <- pilot_run(worker, args, n_pilot = 3L, seed = 42L)
print(pilot)

# 3. Auto-size optimal SLURM array chunking, --mem, and --time
resources <- estimate_resources(pilot, n_tasks = length(args), max_chunk_size = 5L)
print(resources)

# 4. Run locally on MockSlurmBackend (or switch to slurm_ssh_backend() for HPC)
backend <- mock_slurm_backend(max_workers = 2L)
job <- slurm_submit(backend, worker, args, resources = resources, name = "mc_power")
status <- slurm_wait(job, progress = TRUE)
results <- slurm_collect(job, simplify = TRUE)
```

Or run the entire pipeline—including automatic surgical retries on failed/OOM chunks—in a single call:

```r
run <- slurm_autopilot(
  fun = worker,
  args_list = args,
  backend = mock_slurm_backend(max_workers = 2L),
  n_pilot = 3L,
  max_chunk_size = 5L,
  auto_retry = 1L,
  simplify = TRUE
)
```

## Reproducible Apptainer & SLURM Export

```r
env <- scan_project_env(extra_packages = c("lme4", "Rcpp", "cmdstanr", "RTMB"))
def <- build_apptainer_def(env, output_path = "slurmpilot_env.def")
sb  <- render_sbatch_script(
  job_name = "mc_power",
  resources = resources,
  work_dir = "/scratch/user/mc_power",
  container_sif = "/scratch/containers/slurmpilot_env.sif"
)
```

## Non-Blocking Shiny Demo

Launch the bundled Monte Carlo studio demonstrating non-blocking background cluster offload, live UI responsiveness, and surgical retry:

```r
slurmpilot::run_demo_app()
```

## Documentation

- Architecture & scaling mathematics: see `ARCHITECTURE.md`
- Vignette 1: `vignette("pilot-to-cluster", package = "slurmpilot")`
- Vignette 2: `vignette("apptainer-ssh-shiny", package = "slurmpilot")`

## License

MIT © 2026 Marcus Harris
