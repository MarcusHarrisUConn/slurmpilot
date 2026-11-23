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

- Initial CRAN-grade release featuring empirical micro-pilot profiling (`pilot_run()`, `estimate_resources()`), HPC environment scanning and Apptainer/SLURM generation (`scan_project_env()`, `build_apptainer_def()`, `render_sbatch_script()`, `render_worker_script()`), pluggable scheduler backends (`MockSlurmBackend`, `SlurmSshBackend`), and non-blocking `bslib`/Shiny offload modules (`mod_hpc_submit_*`, `mod_hpc_monitor_*`, `run_demo_app()`).
