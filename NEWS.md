# slurmpilot 0.5.0

## Security Hardening & Independent Peer Red-Team Remediation
- **Eliminated `cli` Glue `{...}` RCE (`R/globals.R`, `R/efficiency.R`):**
  Audited every `cli::` call package-wide so untrusted dynamic warnings and
  efficiency recommendations are interpolated safely via `{w}` / `{r}` without
  evaluating embedded R expressions.
- **Hardened `#SBATCH`, SSH, SCP, URL & Path Confinement Guards (`R/security.R`, `R/backend_ssh.R`, `R/sbatch.R`, `R/apptainer.R`, `R/env_scan.R`):**
  - Blocked `--wrap`, `--prolog`/`--epilog`, `--output`/`--error`, `--export`,
    quotes, and multi-flag smuggling in `extra_sbatch`, and disallowed spaces
    in SLURM/container paths (`sp_assert_safe_path(allow_spaces = FALSE)`).
  - Blocked dangerous SSH CLI flags (`-F`, `-S`, `-L/-R/-D/-W`, `-A`, `-J`,
    `-i`, plus bundled variants) and directives (`IdentityFile`, `ControlPath`,
    `ProxyJump`, `ForwardAgent`, `SendEnv`, `SetEnv`, etc.) in `ssh_options`,
    and blocked whitespace/shell metacharacters in `build_scp_args()`.
  - Hardened `sp_assert_path_confined()` via ancestor `Sys.readlink()` resolution
    against non-existent `..` paths and dangling external symlinks, and enforced
    root confinement in `scan_project_env()`.
  - Blocked `$VAR` shell expansion in `cran_repo` URLs and omitted empty
    `apt-get` blocks in `build_apptainer_def()`.
- **Ambient Secret Scrubbing & Closure Audit Safety (`R/globals.R`, `R/pilot.R`, `R/backend_mock.R`, `R/shiny_submit.R`, `R/sbatch.R`):**
  - Guarded `inspect_job_globals()` against evaluating active bindings, used
    `serialize()` for accurate nested-environment sizing, and added nested
    credential scanning (`$secret_objects`, `$active_bindings`).
  - Added default `scrub_secrets = TRUE` to `pilot_run()`, `MockSlurmBackend`,
    `mock_slurm_backend()`, and async Shiny pilots (scrubbing ambient credential
    env vars and setting `R_ENVIRON_USER = ""` / `R_PROFILE_USER = ""`),
    forwarded explicit `job_spec$env_vars` to mock workers, warned on secret
    `env_vars` in `render_sbatch_script()`, and applied `0600` permissions to
    written `.sbatch` files.

## Container, Cluster, Pipeline, Parser, Shiny & Performance Fixes
- **Native `rcapsule` Interoperability (`R/container_hook.R`):**
  `use_rcapsule_container()` now natively consumes `rcapsule_apptainer_spec`,
  `rcapsule_apptainer`, `rcapsule_manifest`, `rcapsule_bundle`, and
  `rcapsule_export` objects (`def_content`, `def_sha256`, `bind_paths`,
  `integrity$content_digest`, `specs$apptainer`, directory bundle `.def`
  files) with zero hard dependency.
- **POSIX Tilde Expansion & Apptainer `--cleanenv` Forwarding (`R/sbatch.R`, `R/backend_ssh.R`):**
  - `remote_dir = "~/..."` now expands via `"$HOME"/'...'` across `mkdir`,
    `sbatch`, `WORK_DIR`, and `--bind`, with home-relative `#SBATCH --output` /
    `--error` paths.
  - Exported `APPTAINERENV_*` counterparts for thread caps, `SLURMPILOT_*`, and
    user `env_vars` (including `SLURMPILOT_CONTAINER_DIGEST`) whenever running
    under `apptainer exec --cleanenv`.
- **Scheduler, Pipeline & Efficiency Correctness (`R/backend_ssh.R`, `R/pipeline.R`, `R/efficiency.R`, `R/backend_base.R`):**
  - Preserved per-job `container_binds` in `SlurmSshBackend$retry()` and
    rejected `DRY_RUN` dependencies on live (`dry_run = FALSE`) submissions.
  - Fixed `slurm_pipeline_run()` to reject unsupported `wait = FALSE` DAGs on
    `MockSlurmBackend`, honor `stop_on_failure` and `"SKIPPED"`/`"OUT_OF_MEMORY"`/
    `"TIMEOUT"` in `afterany`/`afternotok`, and gracefully mark 0-task dynamic
    stages `"SKIPPED"`.
  - Hardened `slurm_efficiency_report()` against missing `chunk_id`, `Inf`
    metrics in `plot()`, zero-median straggler ratios (`Inf`), and 100%-failed
    jobs (`classification = "failed"`).
  - Union-aligned heterogeneous data-frame results in `slurm_collect(simplify = TRUE)`.
- **Parser Safety, Shiny Resilience & LPT Speedup (`R/utils.R`, `R/backend_ssh.R`, `R/shiny_submit.R`, `R/resources.R`, `R/sbatch.R`):**
  - Added `max_indices = 100000L` bound to `parse_slurm_array_spec()`,
    vectorized `parse_squeue_output()` to $O(N)$, and preserved SLURM signal
    exit codes (`128 + signal`) in `parse_sacct_output()`.
  - Wrapped `mod_hpc_submit_server()` pilot/submission observers in `tryCatch()`
    so empty or failing `args_builder` callbacks surface clean UI alerts instead
    of crashing the Shiny session.
  - Gated `SLURMPILOT_MOCK_FAULT` in `worker.R` strictly to `SLURMPILOT_BACKEND=mock`.
  - Accelerated `plan_chunks(..., strategy = "lpt")` via C-level `which.min()`
    plus an $O(N \log M)$ binary min-heap for `> 2048` chunks and eliminated
    duplicate partitioning in `estimate_resources()` and `scale_resources()`.

# slurmpilot 0.4.0

## New Research-Workflow Capabilities
- **Multi-Stage Dependent HPC Job DAGs (`slurm_stage()`, `slurm_pipeline()`, `slurm_pipeline_run()`, `slurm_pipeline_status()`, `slurm_pipeline_collect()`):**
  Define linear, fan-out, fan-in, and diamond job DAGs with Kahn topological
  sorting and explicit cycle/self-loop detection. Emits validated SLURM
  `#SBATCH --dependency=afterok:<ids>` flags (`afterok`, `afterany`,
  `afternotok`) on `SlurmSshBackend` and executes full multi-stage pipelines
  locally end-to-end on `MockSlurmBackend` with upstream output forwarding.
- **Post-Mortem Resource Efficiency Auditor (`slurm_efficiency_report()`, `plot.slurmpilot_efficiency()`):**
  Compares requested `--mem` and `--time` against empirical Peak RSS and
  walltime from `MockSlurmBackend` telemetry or `parse_sacct_output()` tables,
  quantifying memory waste %, walltime slack %, and straggler imbalance ratio,
  and recommending a concrete tightened (or escalated) `resource_spec()` for
  the next run.
- **Zero-Dependency Container Integration Hook (`use_rcapsule_container()`):**
  Accepts `.sif` / `.def` file paths, `slurmpilot_apptainer_def` recipes, or
  duck-typed `rcapsule` specs/manifests (with zero hard dependency) to validate
  paths and bind mounts strictly and attach provenance metadata and
  `SLURMPILOT_CONTAINER_DIGEST` to `slurm_job_spec()`.

## Coverage-Driven Bug Fixes & Quality
- Fixed subscript-out-of-bounds crash in `verify_checkpoint()` when a `.sha256`
  sidecar file is blank or whitespace-only.
- Fixed `parse_sacct_output()` and `parse_squeue_output()` misparsing non-numeric
  header rows when raw headered scheduler output is passed.
- Fixed `MockSlurmBackend$retry()` dropping `container_sif`, `modules`, and
  `env_vars` when regenerating `retry_<k>.sbatch` and carrying over previous
  attempt `peak_rss_mb`.
- Fixed `mod_hpc_monitor_server()` wiping collected `results()` on an accidental
  retry click against an already-`COMPLETED` job.
- Added a fifth executable vignette (`vignettes/pipelines-and-efficiency.Rmd`) and
  drove test suite coverage above 93% via `covr`.

# slurmpilot 0.3.0

## Workflow Hardening & New Capabilities
- **Adaptive Retry Escalation (`slurm_retry()`, `slurm_retry_history()`):**
  Automatically escalates `--mem` (default `1.5x`, capped at `max_mem_mb`) on
  `OUT_OF_MEMORY` chunks and `--time` (default `1.5x`, capped at
  `max_time_minutes`) on `TIMEOUT` chunks, while persisting per-chunk retry
  provenance to `job$retry_history` and `retry_history.json`.
- **Heterogeneous Task Load Balancing (`plan_chunks()`, `resource_spec()`, `estimate_resources()`):**
  Added `strategy = c("contiguous", "round_robin", "lpt")` supporting Graham's
  Longest Processing Time first greedy load balancing (with explicit
  `task_weights` or pilot-interpolated weights) so straggler chunks do not
  stall heterogeneous SLURM arrays.
- **Pre-Submit Closure & Globals Audit (`inspect_job_globals()`):**
  Detects accidentally captured large closure objects (`>= size_warn_mb`),
  unresolved free variables, and unexported helper functions before staging,
  with automatic bundle-size warnings in `slurm_job_spec()`.
- **Hardened SLURM Parsers & Transient SSH Backoff:**
  Extended `parse_slurm_mem()` for SLURM per-CPU/per-node (`100Mc`, `200Mn`,
  `4Gc`) and IEC suffixes, extended `parse_slurm_time()` for fractional seconds
  and `D-HH` formats, exported `parse_slurm_array_spec()` (including stepped
  ranges `1-100:2` and `%limit` caps), hardened `parse_sacct_output()` /
  `parse_squeue_output()`, and added bounded exponential backoff retries for
  transient SSH/SCP network errors in `SlurmSshBackend`.

## CRAN Readiness, Documentation & Website
- Migrated vignettes to CRAN-universal `VignetteBuilder: knitr` (`knitr::rmarkdown`)
  and expanded to 4 executable vignettes (`getting-started`,
  `pilot-to-cluster`, `apptainer-ssh-shiny`, `troubleshooting-and-retries`).
- Added `inst/CITATION`, runnable example scripts in `inst/examples/`,
  `inst/WORDLIST` (0 spelling warnings), `cran-comments.md`, and GitHub Actions
  workflows (`R-CMD-check.yaml`, `pkgdown.yaml`).
- Added `_pkgdown.yml` website configuration and standalone PDF Field Guide
  source (`inst/guides/slurmpilot-guide.Rmd`).
- Audited all examples, tests, and vignettes for strict `<= 2` core limits,
  clean `tempdir()` cleanup, and zero global-state mutation.

# slurmpilot 0.2.0

## Security Hardening
- Added centralized injection-defense and path-confinement module (`R/security.R`) and documented threat model & audit remediations in `SECURITY.md`.
- Hardened `render_sbatch_script()`, `resource_spec()`, `estimate_resources()`, and `slurm_job_spec()` against `#SBATCH` newline/control-char injection, shell metacharacters, `--wrap` smuggling, unsafe module/env names, and path traversal (`..`).
- Hardened `build_ssh_args()`, `build_scp_args()`, `build_scancel_command()`, and `SlurmSshBackend` with strict host/user/path/job-ID validation, explicit `--` option delimiters, and a denylist blocking dangerous SSH execution directives (`ProxyCommand`, `LocalCommand`, `RemoteCommand`, `Include`, `Match`).
- Hardened `build_apptainer_def()` and `scan_project_env()` against container base-image, R/apt package name, CRAN URL, version string, label, and `%post` section-breakout injection.
- Added atomic SHA-256 checkpoint sidecars (`chunk_XXXX.rds.sha256`) and exported `verify_checkpoint()`, enforced automatically by `slurm_collect()` and `worker.R` idempotent resume checks.
- Eliminated `.Random.seed` mutation from job ID generation and atomic file writers.
- Hardened Shiny modules (`mod_hpc_submit_*`, `mod_hpc_monitor_*`) with finite input clamping, retry caps, memory ceilings, isolated zero-loop polling, and ANSI/XSS-safe text sanitization (`sp_escape_ui_text()`).

## Profiling Accuracy, Parallel RNG & Process Lifecycle
- Upgraded `estimate_resources()` walltime estimation with a robust heavy-tail envelope combining normal CLT, Fenton-Wilkinson log-normal sum quantiles, and nonparametric order-statistic bounds, plus overflow-safe sub-millisecond task sizing and pilot failure/OOM diagnostics.
- Switched `worker.R` and `pilot_run()` from consecutive integer seeds to independent hierarchical `L'Ecuyer-CMRG` streams (`parallel::nextRNGStream()` + `parallel::nextRNGSubStream()`) and exported `slurmpilot_rng_stream()`.
- Added `sp_kill_and_reap()` and `MockSlurmBackend$shutdown()` for guaranteed child-process reaping and race-safe status transitions on cancel, OOM, timeout, and completion.

# slurmpilot 0.1.0

- Initial release featuring empirical micro-pilot profiling (`pilot_run()`, `estimate_resources()`), HPC environment scanning and Apptainer/SLURM generation (`scan_project_env()`, `build_apptainer_def()`, `render_sbatch_script()`, `render_worker_script()`), pluggable scheduler backends (`MockSlurmBackend`, `SlurmSshBackend`), and non-blocking `bslib`/Shiny offload modules (`mod_hpc_submit_*`, `mod_hpc_monitor_*`, `run_demo_app()`).
