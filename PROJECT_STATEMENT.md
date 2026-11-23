## Project 1: `slurmpilot` — Auto-Profiling Laptop-to-HPC & Async Shiny Compute Engine

**Suggested GitHub Repo:** `slurmpilot`  
**GitHub One-Liner:** *Auto-profiling SLURM HPC job orchestration, Apptainer packaging, and non-blocking Shiny compute offloading for compute-heavy R workflows.*  
**Topics:** `r-package`, `hpc`, `slurm`, `apptainer`, `shiny`, `monte-carlo`, `parallel-computing`, `computational-statistics`

### Project Statement
Modern statistical workflows in R—Bayesian MCMC, dynamic structural equation modeling (DSEM), large-scale Monte Carlo power studies, and multilevel bootstraps—routinely exceed laptop memory and CPU budgets and freeze interactive Shiny servers. Although most universities and cloud platforms offer high-performance computing (HPC) clusters running SLURM, actually using them from R remains a high-friction DevOps exercise: researchers must hand-write batch scripts, guess memory and walltime limits blind (risking silent out-of-memory kills or multi-day queue waits), reconcile missing compiled toolchains (`CmdStan`, C++, `TMB`) inside Apptainer containers, and manually recover partially failed array jobs.

`slurmpilot` eliminates this barrier by providing an end-to-end **pilot-to-cluster autopilot** native to R and Shiny. Before submitting a large workload, `slurmpilot` executes a brief local micro-pilot to empirically measure peak RAM, runtime distribution, and parallel efficiency, then automatically computes optimal SLURM array chunking, memory allocations, and walltime limits. It packages project environments into HPC-compliant Apptainer recipes, manages remote submission, checkpointing, and surgical retry of failed chunks over SSH, and exposes drop-in asynchronous Shiny modules so web applications can offload compute-heavy jobs without ever blocking the user interface.

### Why Existing R Tools Aren't Enough
- `batchtools`, `future.batchtools`, and `crew.cluster` provide low-level scheduler backends, but still force users to manually guess `--mem`/`--time`, write SLURM templates, handle Apptainer builds separately, and wire up their own Shiny async UI layer.
- `clustermq` relies on ZeroMQ networking that is frequently blocked by university HPC firewalls.
- None provide **empirical micro-pilot auto-sizing** paired with **non-blocking Shiny telemetry modules** and a **local mock SLURM simulator** for zero-cluster development and testing.

### Core Architectural Pillars
1. **Micro-Pilot Auto-Profiler:** Runs a controlled sample slice (e.g., 3–5 replications), profiles peak RSS memory and runtime quantiles, fits a resource scaling estimate, and recommends optimal chunk sizes and SLURM flags with configurable safety margins.
2. **HPC Environment & Apptainer Packager:** Scans `renv.lock` and compiled dependencies (`Rcpp`, `cmdstanr`, `RTMB`) to generate reproducible Apptainer/Singularity `.def` recipes and self-contained SLURM array submission scripts.
3. **Pluggable Scheduler Backend + Local Mock SLURM:** Clean S3/R6 backend interface implementing both a real SSH/SLURM adapter (checkpointing, chunk-level retry, artifact staging/retrieval) and a **full Local Mock SLURM Scheduler** running in background R processes so every workflow is 100% runnable and testable on a laptop.
4. **Non-Blocking Shiny Offload Modules:** Ready-made `bslib`/Shiny modules (`mod_hpc_submit`, `mod_hpc_monitor`) using asynchronous polling to display live chunk status, failure retries, resource gauges, and cancel/resume controls while keeping the Shiny session responsive.

### v1 Definition of Done
- Working pilot profiler → resource estimator → mock-SLURM submit/monitor/retry/collect lifecycle verified end-to-end on macOS.
- Real SLURM/SSH command generator and Apptainer `.def` builder covered by snapshot and contract tests.
- Working demo Shiny app showing non-blocking background cluster offload.
- Complete `testthat` suite, `roxygen2` documentation, 2+ Quarto vignettes, and `0 errors | 0 warnings | 0 notes` on `R CMD check`.

### New-Conversation Handoff Block
```text
We are starting a new flagship, CRAN-grade R package in this repository: `slurmpilot` — an auto-profiling Laptop-to-HPC compute engine and async Shiny offloading package for R.

Project mission: Eliminate manual SLURM scripting, blind RAM/walltime guessing, and Shiny server freezes for compute-heavy R workflows (Monte Carlo sims, MCMC, DSEM, bootstraps) via:
1. A micro-pilot resource auto-profiler that empirically measures peak RAM & runtime and computes optimal SLURM array chunking, memory, and walltime.
2. An HPC environment packager generating Apptainer/Singularity `.def` recipes and SLURM array scripts (handling `renv`, C++, `CmdStan`, `RTMB`).
3. A clean scheduler backend abstraction with both a real SSH/SLURM adapter (checkpointing, partial chunk retry, result collection) and a full Local Mock SLURM Scheduler running in background R processes so the entire lifecycle is 100% testable locally without a live cluster.
4. Drop-in non-blocking Shiny modules (`bslib`) with live chunk progress, retry controls, and telemetry, plus a runnable demo app.

Please start by inspecting this repo, proposing a clean modular package architecture (`ARCHITECTURE.md`) and phased implementation plan, and then we will build iteratively to a full `testthat` suite, vignettes, and clean `R CMD check`.
```
