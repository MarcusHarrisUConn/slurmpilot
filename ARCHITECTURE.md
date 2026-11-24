# slurmpilot Architecture

`slurmpilot` is a CRAN-grade R package that provides an end-to-end
**pilot-to-cluster autopilot** and **non-blocking Shiny compute engine**
for computationally intensive R workloads (Monte Carlo simulations,
Bayesian MCMC, mixed-effects and dynamic structural equation modeling,
and large-scale bootstraps).

------------------------------------------------------------------------

## 1. High-Level Modular Design

The package is organized into four cohesive pillars connected by
explicit, immutable S3 specification objects and an R6 scheduler backend
interface:

``` text
  User workload (fun, args_list, packages, globals)
         │
         ▼
┌──────────────────────────────────────────────────────────┐
│ Pillar 1: Micro-Pilot Auto-Profiler                      │
│   R/pilot.R, R/resources.R                               │
│   pilot_run() ──► slurmpilot_pilot                       │
│   estimate_resources() ──► slurmpilot_resources          │
└───────────────────────────┬──────────────────────────────┘
                            │ (chunk_size, --mem, --time, --array)
         ┌──────────────────┴──────────────────┐
         ▼                                     ▼
┌──────────────────────────────────┐  ┌─────────────────────────────────────────┐
│ Pillar 2: HPC Env & Packager     │  │ Pillar 3: Pluggable Scheduler Backends  │
│   R/env_scan.R, R/apptainer.R,   │  │   R/backend_base.R  (SlurmBackend R6)   │
│   R/sbatch.R                     │  │   R/backend_mock.R  (MockSlurmBackend)  │
│   scan_project_env()             │  │   R/backend_ssh.R   (SlurmSshBackend)   │
│   build_apptainer_def()          │  │   R/job.R           (S3 lifecycle API)  │
│   render_sbatch_script()         │  └────────────────────┬────────────────────┘
│   render_worker_script()         │                       │
└──────────────────────────────────┘                       ▼
                                      ┌─────────────────────────────────────────┐
                                      │ Pillar 4: Non-Blocking Shiny Offload    │
                                      │   R/shiny_submit.R, R/shiny_monitor.R,  │
                                      │   R/shiny_app.R, inst/shiny/demo/app.R  │
                                      │   mod_hpc_submit_ui/server              │
                                      │   mod_hpc_monitor_ui/server             │
                                      └─────────────────────────────────────────┘
```

### Source File Map

| File | Responsibility |
|----|----|
| `R/slurmpilot-package.R` | Package documentation, `@importFrom` declarations, global variable registrations |
| `R/utils.R` | Internal helpers: SLURM time/memory parsers & formatters, array range compression, atomic file I/O, chunk partitioning, shell quoting |
| `R/pilot.R` | [`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md) empirically profiles sample replications in isolated [`callr::r_bg`](https://callr.r-lib.org/reference/r_bg.html) child processes with `ps` RSS polling; `print`/`summary`/`plot` methods |
| `R/resources.R` | [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md), [`resource_spec()`](https://marcusharrisphd.com/slurmpilot/reference/resource_spec.md), [`as_slurm_flags()`](https://marcusharrisphd.com/slurmpilot/reference/as_slurm_flags.md), chunk sizing & scaling math; `print` method |
| `R/env_scan.R` | [`scan_project_env()`](https://marcusharrisphd.com/slurmpilot/reference/scan_project_env.md), [`toolchain_registry()`](https://marcusharrisphd.com/slurmpilot/reference/toolchain_registry.md) scanning `renv.lock`, `DESCRIPTION`, and scripts to detect compiled toolchains and Debian/Ubuntu apt dependencies |
| `R/apptainer.R` | [`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md) generating reproducible Apptainer/Singularity `.def` recipes with pinned base images, toolchains, `renv` restore, `%environment`, and `%test` |
| `R/sbatch.R` | [`render_sbatch_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_sbatch_script.md) and [`render_worker_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_worker_script.md) emitting self-contained SLURM array submission scripts and standalone zero-dependency base-R cluster worker runners |
| `R/backend_base.R` | Abstract R6 class `SlurmBackend` defining the scheduler contract and shared job staging helpers |
| `R/backend_mock.R` | `MockSlurmBackend`: local parallel background-process SLURM simulator using [`callr::r_bg`](https://callr.r-lib.org/reference/r_bg.html) + `ps`, disk checkpoints, queue limits, simulated OOM/TIMEOUT/FAIL faults, surgical retry, cancellation, and log capture |
| `R/backend_ssh.R` | `SlurmSshBackend` + pure command/parser functions (`build_ssh_args`, `build_scp_args`, `parse_sbatch_output`, `parse_squeue_output`, `parse_sacct_output`, `build_scancel_command`) with injectable `command_runner` for deterministic contract testing |
| `R/job.R` | User-facing S3 constructors and lifecycle API (`slurm_job_spec`, `slurm_submit`, `slurm_status`, `slurm_retry`, `slurm_cancel`, `slurm_logs`, `slurm_collect`, `slurm_wait`, `slurm_autopilot`) |
| `R/shiny_submit.R` | [`mod_hpc_submit_ui()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_submit_ui.md) & [`mod_hpc_submit_server()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_submit_server.md): non-blocking micro-pilot + cluster submission module |
| `R/shiny_monitor.R` | [`mod_hpc_monitor_ui()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_monitor_ui.md) & [`mod_hpc_monitor_server()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_monitor_server.md): live `bslib` telemetry dashboard with chunk progress bar, resource gauges, surgical retry, cancel, pause/resume, and log viewer |
| `R/shiny_app.R` | [`run_demo_app()`](https://marcusharrisphd.com/slurmpilot/reference/run_demo_app.md) launcher for the bundled Monte Carlo simulation demo under `inst/shiny/demo/app.R` |

------------------------------------------------------------------------

## 2. Micro-Pilot Profiling & Resource Scaling Mathematics

### 2.1 Empirical Measurement Protocol

Naive profiling inside the main R session via
[`system.time()`](https://rdrr.io/r/base/system.time.html) and
[`gc()`](https://rdrr.io/r/base/gc.html) systematically underestimates
true cluster resource demand because: 1.
[`gc()`](https://rdrr.io/r/base/gc.html) only sees R’s managed heap,
missing C++/Stan/TMB/BLAS/OpenMP native allocations and shared
libraries. 2. In-process timing omits cold R startup and package-loading
overhead incurred by every SLURM array task.

[`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md)
solves both by launching each pilot trial
$`i \in \{1, \dots, n_{\text{pilot}}\}`$ inside an isolated background
child R process via
[`callr::r_bg()`](https://callr.r-lib.org/reference/r_bg.html) and
polling the OS process tree
([`ps::ps_memory_info()`](https://ps.r-lib.org/reference/ps_memory_info.html)
summed across the worker PID and recursive children) at
`sample_interval` seconds (default `0.05s`).

Each child emits high-resolution internal checkpoints: -
$`t_{\text{spawn}}`$: parent launches child process. -
$`t_{\text{ready}}`$: child R starts, loads requested `packages`, and
reads the serialized payload. - $`t_{\text{start}}, t_{\text{end}}`$:
task function invocation boundaries.

From these checkpoints and OS samples we obtain per trial $`i`$: -
**Startup overhead:**
$`t_{0,i} = t_{\text{ready},i} - t_{\text{spawn},i}`$ - **Task execution
time:** $`t_{1,i} = t_{\text{end},i} - t_{\text{start},i}`$ - **Baseline
RSS ($`m_{0,i}`$):** RSS sampled at worker readiness (R runtime + loaded
packages). - **Peak RSS ($`m_{\text{peak},i}`$):** Maximum total RSS
observed across the worker process tree during trial $`i`$. - **Net
working-set RSS ($`m_{\text{net},i}`$):**
$`\max(0,\; m_{\text{peak},i} - m_{0,i})`$.

### 2.2 Scaling Model & Optimal Chunking (`estimate_resources()`)

Given $`N`$ total tasks (`n_tasks`) and successful pilot measurements:

1.  **Startup & Per-Task Time Parameters:**

    - $`\hat{t}_0 = \text{median}(t_{0,i})`$ (fixed per-chunk startup
      cost).
    - $`\hat{\mu}_t = \text{mean}(t_{1,i})`$ (expected per-task
      execution time).
    - $`\hat{\sigma}_t = \text{sd}(t_{1,i})`$ (if $`n_{\text{ok}} < 2`$
      or $`\hat{\sigma}_t = 0`$, fallback to $`0.25\,\hat{\mu}_t`$ to
      preserve a nonzero uncertainty buffer).
    - $`\hat{q}_{90}`$: empirical 90th percentile of $`t_{1,i}`$.

2.  **CPU Scaling (Amdahl’s Law):** If the pilot ran with $`c_0`$ CPUs
    and the target requests $`c`$ CPUs with parallel efficiency
    $`\eta \in (0, 1]`$, the relative speedup factor is:
    ``` math
    S(c_0 \to c) = \frac{(1 - \eta) + \eta / c_0}{(1 - \eta) + \eta / c}
    ```
    Notice $`S(c_0 \to c_0) = 1`$ identically, and effective per-task
    time parameters scale as $`\tilde{\mu}_t = \hat{\mu}_t / S`$,
    $`\tilde{\sigma}_t = \hat{\sigma}_t / S`$,
    $`\tilde{q}_{90} = \hat{q}_{90} / S`$.

3.  **Optimal Array Chunk Size ($`k^*`$):** Let
    $`T_{\text{target}} = 60 \cdot \text{target\_chunk\_minutes}`$ be
    the target walltime per SLURM array task (default 15 minutes).

    - Time-targeted chunk size:
      ``` math
      k_{\text{time}} = \max\!\left(1,\; \left\lfloor \frac{\max(1,\; T_{\text{target}} - \hat{t}_0)}{\max(\tilde{\mu}_t,\; 10^{-3})} \right\rfloor\right)
      ```
    - Array-limit lower bound (respecting SLURM `MaxArraySize`, default
      1000):
      ``` math
      k_{\text{cap}} = \left\lceil \frac{N}{\text{max\_array\_size}} \right\rceil
      ```
    - Chosen chunk size:
      ``` math
      k^* = \text{clamp}\!\left(\max(k_{\text{time}}, k_{\text{cap}}),\; k_{\min},\; \min(N, k_{\max})\right)
      ```
    - Number of SLURM array tasks:
      ``` math
      M = \left\lceil \frac{N}{k^*} \right\rceil
      ```
    - Amortized startup overhead ratio:
      ``` math
      \rho_{\text{overhead}} = \frac{\hat{t}_0}{\hat{t}_0 + k^* \tilde{\mu}_t}
      ```

4.  **Conservative Walltime Limit (`--time`):** Across $`k^*`$
    independent sequential replications inside one chunk, the sum’s
    standard deviation grows as $`\sqrt{k^*}\,\tilde{\sigma}_t`$. Using
    small-sample $`t`$-quantile
    $`z_{\text{tail}} = t_{0.99,\; \text{df} = \max(1, n_{\text{ok}} - 1)}`$
    capped at $`3.5`$ (and floored at $`2.326`$ for large $`n`$):
    ``` math
    T_{\text{pred}}(k^*) = \max\!\left(\hat{t}_0 + k^*\tilde{\mu}_t + z_{\text{tail}}\sqrt{k^*}\,\tilde{\sigma}_t,\; \hat{t}_0 + k^*\tilde{q}_{90}\right)
    ```
    ``` math
    T_{\text{req}} = \text{ceil\_to}\!\left(\max\!\left(T_{\min},\; \gamma_{\text{time}} \cdot T_{\text{pred}}(k^*)\right),\; \Delta_T\right)
    ```
    where $`\gamma_{\text{time}} = \text{time\_safety}`$ (default
    `1.50`) and $`\Delta_T = \text{time\_round\_minutes}`$ (default `5`
    minutes).

5.  **Conservative Memory Limit (`--mem`):** Sequential tasks reuse the
    R heap, but long-running chunks exhibit modest memory fragmentation
    modeled logarithmically in $`k^*`$:
    ``` math
    M_{\text{base}} = \max\!\left(\max_i m_{\text{peak},i},\; \text{median}(m_{0,i}) + \max_i m_{\text{net},i}\right)
    ```
    ``` math
    M_{\text{pred}} = M_{\text{base}} \cdot \left(1 + 0.05 \log_2(\max(1, k^*))\right) \cdot \left(1 + 0.15 \cdot \max(0, c - c_0)\right)
    ```
    ``` math
    M_{\text{req}} = \text{ceil\_to}\!\left(\max\!\left(M_{\min},\; \gamma_{\text{mem}} \cdot M_{\text{pred}}\right),\; \Delta_M\right)
    ```
    where $`\gamma_{\text{mem}} = \text{mem\_safety}`$ (default `1.35`),
    $`M_{\min} = 512\text{ MB}`$, and $`\Delta_M = 256\text{ MB}`$.

------------------------------------------------------------------------

## 3. HPC Environment, Apptainer & SLURM Contract

### 3.1 Toolchain & Dependency Scanning (`scan_project_env()`)

Scans three complementary sources in a project directory: 1. `renv.lock`
(JSON) — pins R version, package versions, and repositories. 2.
`DESCRIPTION` (DCF) — extracts `Depends`, `Imports`, and optionally
`Suggests`. 3. Project `.R`, `.Rmd`, and `.qmd` source files — parses
[`library()`](https://rdrr.io/r/base/library.html),
[`require()`](https://rdrr.io/r/base/library.html),
[`requireNamespace()`](https://rdrr.io/r/base/ns-load.html), and
`pkg::fn` references.

Detected packages are matched against
[`toolchain_registry()`](https://marcusharrisphd.com/slurmpilot/reference/toolchain_registry.md)
to infer compiled toolchains (`cpp`, `cmdstan`, `rstan`, `tmb`, `jags`,
`spatial`, `http_ssl`, `linear_algebra`, `graphics`, `arrow`) and the
exact minimal Debian/Ubuntu `apt-get` system packages required inside a
`rocker/r-ver:<R_version>` container.

### 3.2 Apptainer `.def` Contract (`build_apptainer_def()`)

Produces deterministic, reproducible Apptainer/Singularity definition
files: - `Bootstrap: docker` / `From: rocker/r-ver:<r_version>` -
`%labels`: provenance tags (`GeneratedBy slurmpilot`, `RVersion`,
`Toolchains`, deterministic `EnvHash`) - `%files`: copies `renv.lock`
when `renv_restore = TRUE` - `%environment`: pins UTF-8 locale,
single-threaded BLAS/OpenMP defaults (`OMP_NUM_THREADS=1`,
`OPENBLAS_NUM_THREADS=1`) to prevent oversubscription across SLURM array
jobs, and `CMDSTAN=/opt/cmdstan` when `cmdstanr` is active - `%post`:
non-interactive `apt-get install --no-install-recommends`,
`~/.R/Makevars` optimization flags for compiled toolchains,
`renv::restore()` (or explicit
[`install.packages()`](https://rdrr.io/r/utils/install.packages.html)
from Posit Package Manager binaries), optional CmdStan build, and apt
cache cleanup - `%test`: smoke-tests package loading and CmdStan
availability during `apptainer build` - `%runscript`:
`exec Rscript "$@"`

### 3.3 Job Staging Directory & Standalone Worker Contract

Every job submitted by either `MockSlurmBackend` or `SlurmSshBackend`
uses the exact same deterministic workspace layout:

``` text
<job_dir>/
├── payload.rds            # Serialized list: fun, args_list, packages, globals, seed
├── chunks.json            # Array index -> task index mapping & resource spec
├── worker.R               # Standalone base-R runner (requires ZERO slurmpilot install on HPC!)
├── submit.sbatch          # Primary SLURM array submission script
├── retry_<k>.sbatch       # Surgical retry script for failed array indices only
├── state.json             # Job metadata, backend job IDs, attempt history
├── status/
│   └── chunk_<id>.json    # Per-chunk machine-readable telemetry & terminal state
├── results/
│   └── chunk_<id>.rds     # Atomic checkpoint of task outputs for chunk <id>
└── logs/
    ├── chunk_<id>.out     # Stdout log
    └── chunk_<id>.err     # Stderr log
```

**Atomic Checkpointing Rule:** `worker.R` writes each chunk’s result to
`results/.chunk_<id>.rds.tmp.<pid>` and atomically renames it to
`results/chunk_<id>.rds` via
[`file.rename()`](https://rdrr.io/r/base/files.html). Therefore, a
mid-write OOM kill or node preemption can never leave a half-written
corrupt `.rds` artifact. On surgical retry, completed chunks with valid
`results/chunk_<id>.rds` are untouched and never re-executed.

------------------------------------------------------------------------

## 4. Pluggable Scheduler Backend Interface

### 4.1 `SlurmBackend` R6 Abstract Contract

All scheduler implementations inherit from `SlurmBackend` and
implement: - `submit(job_spec)` → `slurmpilot_job` - `status(job)` →
`slurmpilot_status` - `retry(job, chunks = NULL, resources = NULL)` →
updated `slurmpilot_job` - `cancel(job, chunks = NULL)` →
`slurmpilot_status` (invisibly) - `logs(job, chunk_id = NULL)` → named
character vector / list of stdout & stderr logs -
`collect(job, simplify = FALSE, allow_partial = FALSE)` → ordered list
(or simplified vector/tibble) of task results -
`wait(job, timeout = Inf, poll_interval = 0.25, progress = FALSE)` →
terminal `slurmpilot_status`

### 4.2 Chunk State Machine

``` text
                submit() / retry()
  [NEW] ───────────────────────────────► PENDING
                                            │ slot available
                                            ▼
                                         RUNNING ──► cancel() ──► CANCELLED
                                        ╱   │   ╲
                      exit == 0        ╱    │    ╲  RSS > mem / wall > time / exit != 0
                                      ▼     │     ▼
                                COMPLETED   │   FAILED / OUT_OF_MEMORY / TIMEOUT
                                            │                │
                                            └────────────────┴──► retry(chunks) ──► PENDING
```

Job-level aggregate state is derived deterministically from chunk
states: - Any `RUNNING` → `RUNNING` - Else any `PENDING` → `PENDING` -
Else all `COMPLETED` → `COMPLETED` - Else all `CANCELLED` →
`CANCELLED` - Else some `COMPLETED` and some
failed/OOM/timeout/cancelled → `PARTIAL_FAILURE` - Else → `FAILED`

### 4.3 `MockSlurmBackend` vs `SlurmSshBackend`

- **`MockSlurmBackend`**: Runs real isolated background R worker
  processes via
  [`callr::r_bg()`](https://callr.r-lib.org/reference/r_bg.html)
  executing the exact same `worker.R` script and disk checkpoint layout
  as real SLURM, throttled by `max_workers` concurrent slots.
  Continuously polls OS RSS via `ps`, enforces simulated memory
  (`OUT_OF_MEMORY`) and walltime (`TIMEOUT`) limits, supports
  deterministic per-chunk fault injection (`fail_chunks`, `oom_chunks`,
  `timeout_chunks`, `fail_once`), and cleans up child processes on
  `cancel()` and object finalization.
- **`SlurmSshBackend`**: Executes `ssh` and `scp` commands via
  [`processx::run`](http://processx.r-lib.org/reference/run.md) (or an
  injectable `command_runner` callback for deterministic offline
  contract testing). Uses `BatchMode=yes`, strict shell quoting,
  `--parsable` `sbatch` submission, combined `squeue` + `sacct` status
  reconciliation (normalizing `.batch`/`.extern` job steps and `K/M/G/T`
  MaxRSS values), range-compressed surgical retry (`--array=2-4,7`), and
  `scp` artifact retrieval.

------------------------------------------------------------------------

## 5. Non-Blocking Shiny Async Architecture

Shiny runs a single-threaded R event loop per session. Running long
statistical workloads synchronously inside an `observeEvent()` freezes
all UI controls, tabs, and WebSocket heartbeats.

`slurmpilot` keeps the Shiny session 100% responsive by delegating all
compute to background OS processes (via
[`callr::r_bg`](https://callr.r-lib.org/reference/r_bg.html) for
micro-piloting and `SlurmBackend` for cluster execution) and driving UI
updates through lightweight non-blocking polling:

``` text
  Browser UI (bslib cards, value boxes, controls)
       ▲  WebSocket updates (non-blocking)          │ user events (pilot/submit/retry/cancel)
       │                                            ▼
  mod_hpc_monitor_server                    mod_hpc_submit_server
   ├── reactiveTimer(poll_ms)                ├── launches pilot via callr::r_bg()
   │    └── calls slurm_status(job)          ├── polls pilot process non-blockingly
   ├── renders KPIs, multi-segment bar,      ├── computes estimate_resources()
   │   chunk table, and log viewer           └── calls slurm_submit() ──► returns job reactive
   └── handles retry / cancel / collect
```

Key design invariants: 1. **Zero blocking calls in reactive observers:**
Both `pilot_run` in `mod_hpc_submit_server` and worker chunks in
`MockSlurmBackend` execute in separate OS processes. 2.
**Self-throttling polling:** `reactiveTimer(poll_ms)` only triggers
backend queries when polling is unpaused and a job is in a non-terminal
state (`PENDING` or `RUNNING`), automatically going idle on terminal
completion and resuming cleanly on `retry()`. 3. **Decoupled module
interface:**
[`mod_hpc_submit_server()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_submit_server.md)
returns reactive getters (`job`, `pilot`, `resources`, `is_piloting`)
which plug directly into `mod_hpc_monitor_server(id, job = submit$job)`.
Both modules accept any `SlurmBackend` (`MockSlurmBackend` locally or
`SlurmSshBackend` in production) with zero UI code changes.
