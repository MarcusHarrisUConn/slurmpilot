# Changelog

## slurmpilot 0.3.0

### Workflow Hardening & New Capabilities

- **Adaptive Retry Escalation
  ([`slurm_retry()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_retry.md),
  [`slurm_retry_history()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_retry_history.md)):**
  Automatically escalates `--mem` (default `1.5x`, capped at
  `max_mem_mb`) on `OUT_OF_MEMORY` chunks and `--time` (default `1.5x`,
  capped at `max_time_minutes`) on `TIMEOUT` chunks, while persisting
  per-chunk retry provenance to `job$retry_history` and
  `retry_history.json`.
- **Heterogeneous Task Load Balancing
  ([`plan_chunks()`](https://marcusharrisphd.com/slurmpilot/reference/plan_chunks.md),
  [`resource_spec()`](https://marcusharrisphd.com/slurmpilot/reference/resource_spec.md),
  [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md)):**
  Added `strategy = c("contiguous", "round_robin", "lpt")` supporting
  Graham’s Longest Processing Time first greedy load balancing (with
  explicit `task_weights` or pilot-interpolated weights) so straggler
  chunks do not stall heterogeneous SLURM arrays.
- **Pre-Submit Closure & Globals Audit
  ([`inspect_job_globals()`](https://marcusharrisphd.com/slurmpilot/reference/inspect_job_globals.md)):**
  Detects accidentally captured large closure objects
  (`>= size_warn_mb`), unresolved free variables, and unexported helper
  functions before staging, with automatic bundle-size warnings in
  [`slurm_job_spec()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_job_spec.md).
- **Hardened SLURM Parsers & Transient SSH Backoff:** Extended
  [`parse_slurm_mem()`](https://marcusharrisphd.com/slurmpilot/reference/parse_slurm_mem.md)
  for SLURM per-CPU/per-node (`100Mc`, `200Mn`, `4Gc`) and IEC suffixes,
  extended
  [`parse_slurm_time()`](https://marcusharrisphd.com/slurmpilot/reference/parse_slurm_time.md)
  for fractional seconds and `D-HH` formats, exported
  [`parse_slurm_array_spec()`](https://marcusharrisphd.com/slurmpilot/reference/parse_slurm_array_spec.md)
  (including stepped ranges `1-100:2` and `%limit` caps), hardened
  [`parse_sacct_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_sacct_output.md)
  /
  [`parse_squeue_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_squeue_output.md),
  and added bounded exponential backoff retries for transient SSH/SCP
  network errors in `SlurmSshBackend`.

### CRAN Readiness, Documentation & Website

- Migrated vignettes to CRAN-universal `VignetteBuilder: knitr`
  (`knitr::rmarkdown`) and expanded to 4 executable vignettes
  (`getting-started`, `pilot-to-cluster`, `apptainer-ssh-shiny`,
  `troubleshooting-and-retries`).
- Added `inst/CITATION`, runnable example scripts in `inst/examples/`,
  `inst/WORDLIST` (0 spelling warnings), `cran-comments.md`, and GitHub
  Actions workflows (`R-CMD-check.yaml`, `pkgdown.yaml`).
- Added `_pkgdown.yml` website configuration and standalone PDF Field
  Guide source (`inst/guides/slurmpilot-guide.Rmd`).
- Audited all examples, tests, and vignettes for strict `<= 2` core
  limits, clean [`tempdir()`](https://rdrr.io/r/base/tempfile.html)
  cleanup, and zero global-state mutation.

## slurmpilot 0.2.0

### Security Hardening

- Added centralized injection-defense and path-confinement module
  (`R/security.R`) and documented threat model & audit remediations in
  `SECURITY.md`.
- Hardened
  [`render_sbatch_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_sbatch_script.md),
  [`resource_spec()`](https://marcusharrisphd.com/slurmpilot/reference/resource_spec.md),
  [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md),
  and
  [`slurm_job_spec()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_job_spec.md)
  against `#SBATCH` newline/control-char injection, shell
  metacharacters, `--wrap` smuggling, unsafe module/env names, and path
  traversal (`..`).
- Hardened
  [`build_ssh_args()`](https://marcusharrisphd.com/slurmpilot/reference/build_ssh_args.md),
  [`build_scp_args()`](https://marcusharrisphd.com/slurmpilot/reference/build_scp_args.md),
  [`build_scancel_command()`](https://marcusharrisphd.com/slurmpilot/reference/build_scancel_command.md),
  and `SlurmSshBackend` with strict host/user/path/job-ID validation,
  explicit `--` option delimiters, and a denylist blocking dangerous SSH
  execution directives (`ProxyCommand`, `LocalCommand`, `RemoteCommand`,
  `Include`, `Match`).
- Hardened
  [`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md)
  and
  [`scan_project_env()`](https://marcusharrisphd.com/slurmpilot/reference/scan_project_env.md)
  against container base-image, R/apt package name, CRAN URL, version
  string, label, and `%post` section-breakout injection.
- Added atomic SHA-256 checkpoint sidecars (`chunk_XXXX.rds.sha256`) and
  exported
  [`verify_checkpoint()`](https://marcusharrisphd.com/slurmpilot/reference/verify_checkpoint.md),
  enforced automatically by
  [`slurm_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_collect.md)
  and `worker.R` idempotent resume checks.
- Eliminated `.Random.seed` mutation from job ID generation and atomic
  file writers.
- Hardened Shiny modules (`mod_hpc_submit_*`, `mod_hpc_monitor_*`) with
  finite input clamping, retry caps, memory ceilings, isolated zero-loop
  polling, and ANSI/XSS-safe text sanitization (`sp_escape_ui_text()`).

### Profiling Accuracy, Parallel RNG & Process Lifecycle

- Upgraded
  [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md)
  walltime estimation with a robust heavy-tail envelope combining normal
  CLT, Fenton-Wilkinson log-normal sum quantiles, and nonparametric
  order-statistic bounds, plus overflow-safe sub-millisecond task sizing
  and pilot failure/OOM diagnostics.
- Switched `worker.R` and
  [`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md)
  from consecutive integer seeds to independent hierarchical
  `L'Ecuyer-CMRG` streams
  ([`parallel::nextRNGStream()`](https://rdrr.io/r/parallel/RngStream.html) +
  [`parallel::nextRNGSubStream()`](https://rdrr.io/r/parallel/RngStream.html))
  and exported
  [`slurmpilot_rng_stream()`](https://marcusharrisphd.com/slurmpilot/reference/slurmpilot_rng_stream.md).
- Added `sp_kill_and_reap()` and `MockSlurmBackend$shutdown()` for
  guaranteed child-process reaping and race-safe status transitions on
  cancel, OOM, timeout, and completion.

## slurmpilot 0.1.0

- Initial release featuring empirical micro-pilot profiling
  ([`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md),
  [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md)),
  HPC environment scanning and Apptainer/SLURM generation
  ([`scan_project_env()`](https://marcusharrisphd.com/slurmpilot/reference/scan_project_env.md),
  [`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md),
  [`render_sbatch_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_sbatch_script.md),
  [`render_worker_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_worker_script.md)),
  pluggable scheduler backends (`MockSlurmBackend`, `SlurmSshBackend`),
  and non-blocking `bslib`/Shiny offload modules (`mod_hpc_submit_*`,
  `mod_hpc_monitor_*`,
  [`run_demo_app()`](https://marcusharrisphd.com/slurmpilot/reference/run_demo_app.md)).
