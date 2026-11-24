# Changelog

## slurmpilot 0.5.0

### Security Hardening & Independent Peer Red-Team Remediation

- **Eliminated `cli` Glue `{...}` RCE (`R/globals.R`,
  `R/efficiency.R`):** Audited every `cli::` call package-wide so
  untrusted dynamic warnings and efficiency recommendations are
  interpolated safely via `{w}` / `{r}` without evaluating embedded R
  expressions.
- **Hardened `#SBATCH`, SSH, SCP, URL & Path Confinement Guards
  (`R/security.R`, `R/backend_ssh.R`, `R/sbatch.R`, `R/apptainer.R`,
  `R/env_scan.R`):**
  - Blocked `--wrap`, `--prolog`/`--epilog`, `--output`/`--error`,
    `--export`, quotes, and multi-flag smuggling in `extra_sbatch`, and
    disallowed spaces in SLURM/container paths
    (`sp_assert_safe_path(allow_spaces = FALSE)`).
  - Blocked dangerous SSH CLI flags (`-F`, `-S`, `-L/-R/-D/-W`, `-A`,
    `-J`, `-i`, plus bundled variants) and directives (`IdentityFile`,
    `ControlPath`, `ProxyJump`, `ForwardAgent`, `SendEnv`, `SetEnv`,
    etc.) in `ssh_options`, and blocked whitespace/shell metacharacters
    in
    [`build_scp_args()`](https://marcusharrisphd.com/slurmpilot/reference/build_scp_args.md).
  - Hardened `sp_assert_path_confined()` via ancestor
    [`Sys.readlink()`](https://rdrr.io/r/base/Sys.readlink.html)
    resolution against non-existent `..` paths and dangling external
    symlinks, and enforced root confinement in
    [`scan_project_env()`](https://marcusharrisphd.com/slurmpilot/reference/scan_project_env.md).
  - Blocked `$VAR` shell expansion in `cran_repo` URLs and omitted empty
    `apt-get` blocks in
    [`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md).
- **Ambient Secret Scrubbing & Closure Audit Safety (`R/globals.R`,
  `R/pilot.R`, `R/backend_mock.R`, `R/shiny_submit.R`, `R/sbatch.R`):**
  - Guarded
    [`inspect_job_globals()`](https://marcusharrisphd.com/slurmpilot/reference/inspect_job_globals.md)
    against evaluating active bindings, used
    [`serialize()`](https://rdrr.io/r/base/serialize.html) for accurate
    nested-environment sizing, and added nested credential scanning
    (`$secret_objects`, `$active_bindings`).
  - Added default `scrub_secrets = TRUE` to
    [`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md),
    `MockSlurmBackend`,
    [`mock_slurm_backend()`](https://marcusharrisphd.com/slurmpilot/reference/mock_slurm_backend.md),
    and async Shiny pilots (scrubbing ambient credential env vars and
    setting `R_ENVIRON_USER = ""` / `R_PROFILE_USER = ""`), forwarded
    explicit `job_spec$env_vars` to mock workers, warned on secret
    `env_vars` in
    [`render_sbatch_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_sbatch_script.md),
    and applied `0600` permissions to written `.sbatch` files.

### Container, Cluster, Pipeline, Parser, Shiny & Performance Fixes

- **Native `rcapsule` Interoperability (`R/container_hook.R`):**
  [`use_rcapsule_container()`](https://marcusharrisphd.com/slurmpilot/reference/use_rcapsule_container.md)
  now natively consumes `rcapsule_apptainer_spec`, `rcapsule_apptainer`,
  `rcapsule_manifest`, `rcapsule_bundle`, and `rcapsule_export` objects
  (`def_content`, `def_sha256`, `bind_paths`,
  `integrity$content_digest`, `specs$apptainer`, directory bundle `.def`
  files) with zero hard dependency.
- **POSIX Tilde Expansion & Apptainer `--cleanenv` Forwarding
  (`R/sbatch.R`, `R/backend_ssh.R`):**
  - `remote_dir = "~/..."` now expands via `"$HOME"/'...'` across
    `mkdir`, `sbatch`, `WORK_DIR`, and `--bind`, with home-relative
    `#SBATCH --output` / `--error` paths.
  - Exported `APPTAINERENV_*` counterparts for thread caps,
    `SLURMPILOT_*`, and user `env_vars` (including
    `SLURMPILOT_CONTAINER_DIGEST`) whenever running under
    `apptainer exec --cleanenv`.
- **Scheduler, Pipeline & Efficiency Correctness (`R/backend_ssh.R`,
  `R/pipeline.R`, `R/efficiency.R`, `R/backend_base.R`):**
  - Preserved per-job `container_binds` in `SlurmSshBackend$retry()` and
    rejected `DRY_RUN` dependencies on live (`dry_run = FALSE`)
    submissions.
  - Fixed
    [`slurm_pipeline_run()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_run.md)
    to reject unsupported `wait = FALSE` DAGs on `MockSlurmBackend`,
    honor `stop_on_failure` and `"SKIPPED"`/`"OUT_OF_MEMORY"`/
    `"TIMEOUT"` in `afterany`/`afternotok`, and gracefully mark 0-task
    dynamic stages `"SKIPPED"`.
  - Hardened
    [`slurm_efficiency_report()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_efficiency_report.md)
    against missing `chunk_id`, `Inf` metrics in
    [`plot()`](https://rdrr.io/r/graphics/plot.default.html),
    zero-median straggler ratios (`Inf`), and 100%-failed jobs
    (`classification = "failed"`).
  - Union-aligned heterogeneous data-frame results in
    `slurm_collect(simplify = TRUE)`.
- **Parser Safety, Shiny Resilience & LPT Speedup (`R/utils.R`,
  `R/backend_ssh.R`, `R/shiny_submit.R`, `R/resources.R`,
  `R/sbatch.R`):**
  - Added `max_indices = 100000L` bound to
    [`parse_slurm_array_spec()`](https://marcusharrisphd.com/slurmpilot/reference/parse_slurm_array_spec.md),
    vectorized
    [`parse_squeue_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_squeue_output.md)
    to $`O(N)`$, and preserved SLURM signal exit codes (`128 + signal`)
    in
    [`parse_sacct_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_sacct_output.md).
  - Wrapped
    [`mod_hpc_submit_server()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_submit_server.md)
    pilot/submission observers in
    [`tryCatch()`](https://rdrr.io/r/base/conditions.html) so empty or
    failing `args_builder` callbacks surface clean UI alerts instead of
    crashing the Shiny session.
  - Gated `SLURMPILOT_MOCK_FAULT` in `worker.R` strictly to
    `SLURMPILOT_BACKEND=mock`.
  - Accelerated `plan_chunks(..., strategy = "lpt")` via C-level
    [`which.min()`](https://rdrr.io/r/base/which.min.html) plus an
    $`O(N \log M)`$ binary min-heap for `> 2048` chunks and eliminated
    duplicate partitioning in
    [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md)
    and
    [`scale_resources()`](https://marcusharrisphd.com/slurmpilot/reference/scale_resources.md).

## slurmpilot 0.4.0

### New Research-Workflow Capabilities

- **Multi-Stage Dependent HPC Job DAGs
  ([`slurm_stage()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_stage.md),
  [`slurm_pipeline()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline.md),
  [`slurm_pipeline_run()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_run.md),
  [`slurm_pipeline_status()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_status.md),
  [`slurm_pipeline_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_collect.md)):**
  Define linear, fan-out, fan-in, and diamond job DAGs with Kahn
  topological sorting and explicit cycle/self-loop detection. Emits
  validated SLURM `#SBATCH --dependency=afterok:<ids>` flags (`afterok`,
  `afterany`, `afternotok`) on `SlurmSshBackend` and executes full
  multi-stage pipelines locally end-to-end on `MockSlurmBackend` with
  upstream output forwarding.
- **Post-Mortem Resource Efficiency Auditor
  ([`slurm_efficiency_report()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_efficiency_report.md),
  [`plot.slurmpilot_efficiency()`](https://marcusharrisphd.com/slurmpilot/reference/plot.slurmpilot_efficiency.md)):**
  Compares requested `--mem` and `--time` against empirical Peak RSS and
  walltime from `MockSlurmBackend` telemetry or
  [`parse_sacct_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_sacct_output.md)
  tables, quantifying memory waste %, walltime slack %, and straggler
  imbalance ratio, and recommending a concrete tightened (or escalated)
  [`resource_spec()`](https://marcusharrisphd.com/slurmpilot/reference/resource_spec.md)
  for the next run.
- **Zero-Dependency Container Integration Hook
  ([`use_rcapsule_container()`](https://marcusharrisphd.com/slurmpilot/reference/use_rcapsule_container.md)):**
  Accepts `.sif` / `.def` file paths, `slurmpilot_apptainer_def`
  recipes, or duck-typed `rcapsule` specs/manifests (with zero hard
  dependency) to validate paths and bind mounts strictly and attach
  provenance metadata and `SLURMPILOT_CONTAINER_DIGEST` to
  [`slurm_job_spec()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_job_spec.md).

### Coverage-Driven Bug Fixes & Quality

- Fixed subscript-out-of-bounds crash in
  [`verify_checkpoint()`](https://marcusharrisphd.com/slurmpilot/reference/verify_checkpoint.md)
  when a `.sha256` sidecar file is blank or whitespace-only.
- Fixed
  [`parse_sacct_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_sacct_output.md)
  and
  [`parse_squeue_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_squeue_output.md)
  misparsing non-numeric header rows when raw headered scheduler output
  is passed.
- Fixed `MockSlurmBackend$retry()` dropping `container_sif`, `modules`,
  and `env_vars` when regenerating `retry_<k>.sbatch` and carrying over
  previous attempt `peak_rss_mb`.
- Fixed
  [`mod_hpc_monitor_server()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_monitor_server.md)
  wiping collected `results()` on an accidental retry click against an
  already-`COMPLETED` job.
- Added a fifth executable vignette
  (`vignettes/pipelines-and-efficiency.Rmd`) and drove test suite
  coverage above 93% via `covr`.

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
