# Security Policy & Hardening Audit (`slurmpilot`)

## Threat Model

`slurmpilot` generates executable shell scripts (`sbatch`), container recipes (Apptainer `.def`), non-interactive remote `ssh`/`scp` invocations, filesystem checkpoints (`.rds`/`.json`), and interactive `Shiny` HTML views. Untrusted or malformed metadata (e.g., user-supplied Shiny inputs, project `renv.lock` files, remote scheduler output, or shared-filesystem corruption) could otherwise lead to:

1. **`#SBATCH` & Shell Command Injection** on HPC login/compute nodes.
2. **SSH / SCP Argument & Option Injection** (`-oProxyCommand=...`, leading-dash host/path smuggling).
3. **Apptainer Definition Section / Code Injection** via untrusted `renv.lock` package names, base image refs, or CRAN URLs.
4. **Path Traversal (`../`) & Workspace Escape** in staging, checkpoint, or log paths.
5. **Silent Checkpoint Corruption / Partial Write Ingestion** on shared HPC filesystems (Lustre/GPFS/NFS).
6. **Shiny HTML/XSS Injection, Unbounded Resource Requests, or Reactive Polling Loops**.
7. **Parallel RNG Stream Collisions** across SLURM array jobs causing correlated Monte Carlo draws.

---

## Findings Identified & Remediated in v0.2.0

All centralized security guards live in `R/security.R` and are enforced across every entry point and template boundary:

| ID | Component | Vulnerability Found in v0.1.0 | Remediation in v0.2.0 |
|---|---|---|---|
| **S1** | `R/sbatch.R`, `R/resources.R` | `partition`, `account`, `qos`, `mail_user`, `mail_type`, and `extra_sbatch` allowed newlines (`\n`/`\r`) and shell metacharacters, permitting `#SBATCH` breakout and inline command execution (including `--wrap`). | Enforced `sp_assert_safe_slurm_token()`, `sp_assert_safe_email()`, `sp_assert_safe_mail_type()`, and `sp_assert_safe_extra_sbatch()` blocking control chars, metacharacters, leading `-` on tokens, and `--wrap`. |
| **S2** | `R/sbatch.R` | `modules` interpolated directly into `module load <m>` without validation. | Enforced `sp_assert_safe_module_name()` restricting module specs to `^[A-Za-z0-9][A-Za-z0-9_./+-]{0,127}$` with zero `..` or shell syntax. |
| **S3** | `R/sbatch.R`, `R/job.R` | `env_vars` keys were unvalidated before `export <KEY>=<VAL>`. | Enforced `sp_assert_safe_env_name()` (`^[A-Za-z_][A-Za-z0-9_]{0,127}$`) and control-char rejection on all values alongside POSIX single-quoting (`sp_sh_quote()`). |
| **S4** | `R/sbatch.R` | `work_dir`, `log_dir`, `worker_script`, `container_sif`, and `container_binds` lacked traversal (`..`), leading-dash, and metacharacter guards. | Enforced `sp_assert_safe_path()`, `sp_assert_safe_relpath()`, and `sp_assert_safe_apptainer_bind()`. |
| **S5** | `R/utils.R`, `R/sbatch.R`, `R/job.R` | `sp_sanitize_name()` permitted leading `-`/`.` edge cases; `job_name` did not reject control/metacharacter payloads upfront. | Hardened `sp_sanitize_name()` to strip leading/trailing `[._-]` and `..`, and explicitly rejected control/shell metacharacters in `slurm_job_spec()` and `render_sbatch_script()`. |
| **S6** | `R/backend_ssh.R` | `build_ssh_args()` and `build_scp_args()` lacked leading-dash guards and `--` end-of-options delimiters, exposing `host`/`user`/`src`/`dest` to CLI flag injection. | Enforced `sp_assert_safe_ssh_host()`, `sp_assert_safe_ssh_user()`, leading-dash/traversal checks on `src`/`dest`, and explicit `"--"` option terminators in `ssh` and `scp`. |
| **S7** | `R/backend_ssh.R` | `ssh_options` allowed arbitrary directives such as `ProxyCommand` or `LocalCommand`. | Enforced `sp_assert_safe_ssh_options()` blocking `ProxyCommand`, `LocalCommand`, `PermitLocalCommand`, `RemoteCommand`, `ProxyUseFdpass`, `KnownHostsCommand`, `Match`, and `Include`. |
| **S8** | `R/backend_ssh.R` | `build_scancel_command()` and `status()` interpolated `slurm_job_id` without enforcing numeric-only format. | Enforced `sp_assert_safe_slurm_job_id()` (`^[0-9]{1,20}$`). |
| **S9** | `R/backend_base.R`, `R/backend_mock.R`, `R/backend_ssh.R` | Job IDs and resolved checkpoint/status paths lacked canonical root confinement checks. | Enforced `sp_assert_safe_id()` and `sp_assert_path_confined()` across staging, checkpointing, and job lookup. |
| **S10** | `R/apptainer.R`, `R/env_scan.R` | Untrusted `base_image`, `r_version`, `cmdstan_version`, `cran_repo`, package names, `apt` names, `labels`, and `extra_post` could break out of Apptainer `.def` sections or inject R/shell code. | Enforced `sp_assert_safe_docker_image()`, `sp_assert_safe_version()`, `sp_assert_safe_url()`, `sp_assert_safe_r_package()`, `sp_assert_safe_apt_package()`, `sp_assert_safe_apptainer_post()`, and strict `%environment` quoting. |
| **S11** | `R/sbatch.R`, `R/backend_base.R`, `R/utils.R` | Checkpoints lacked cryptographic digest verification; atomic writers and ID generator consumed global `.Random.seed`. | Added SHA-256 sidecars (`chunk_XXXX.rds.sha256` + `status/chunk_XXXX.json` digest) verified via `verify_checkpoint()` in `slurm_collect()` and `worker.R`; switched IDs and atomic temp files to RNG-free monotonic entropy. |
| **S12** | `R/shiny_submit.R`, `R/shiny_monitor.R` | Shiny numeric inputs lacked `NA`/upper bounds; monitor lacked retry caps and ANSI/length sanitization on error strings/logs. | Added `sp_clamp_int()`/`sp_clamp_num()`, `max_retries` + 1 TB memory cap, isolated polling guard against reactive loops, and `sp_escape_ui_text()` ensuring safe HTML escaping via `htmltools` (zero raw `HTML()`). |

---

## Statistical & Runtime Hardening in v0.2.0

- **Heavy-Tailed Walltime Scaling (`R/resources.R`):** Upgraded `estimate_resources()` from normal-CLT-only scaling to `max(CLT, Fenton-Wilkinson log-normal sum Q99, nonparametric order-statistic bound)`, plus overflow-safe sub-millisecond chunking and pilot crash/OOM recovery diagnostics.
- **Mathematically Independent Parallel RNG (`R/sbatch.R`, `R/pilot.R`, `R/utils.R`):** Replaced naive `set.seed(seed + task_id)` with hierarchical `L'Ecuyer-CMRG` substreams via `parallel::nextRNGStream()` (per-chunk, $2^{127}$ apart) and `parallel::nextRNGSubStream()` (per-task, $2^{76}$ apart), exposed cleanly via `slurmpilot_rng_stream()`.
- **Deterministic Process Reaping (`R/backend_mock.R`, `R/pilot.R`):** Added `sp_kill_and_reap()` and `MockSlurmBackend$shutdown()` guaranteeing zero zombie or lingering child processes on cancel, timeout, OOM, or garbage collection, plus race-safe `wait()` before reading exit telemetry.

---

## Independent Peer Red-Team Remediation (v0.5.0)

Following an independent adversarial security, correctness, and cross-package audit of `slurmpilot` v0.4.0, all 18 reproduced findings (2 CRITICAL, 6 HIGH, 8 MEDIUM, 2 LOW) were remediated and locked with permanent regression tests in `tests/testthat/test-peer-redteam.R`:

| ID | Severity | Component | Finding in v0.4.0 | Remediation in v0.5.0 |
|---|---|---|---|---|
| **C1** | CRITICAL | `R/globals.R`, `R/efficiency.R` | Dynamic strings passed directly to `cli::cli_bullets()` evaluated `{...}` glue R expressions on `print()`. | Audited every `cli::` call package-wide; wrapped dynamic warning/recommendation strings in literal `{w}` / `{r}` variables. |
| **C2** | CRITICAL | `R/security.R`, `R/sbatch.R` | `sp_assert_safe_extra_sbatch()` permitted spaces, quotes, and multi-flag smuggling (`--comment=ok --wrap='id'`); `sp_assert_safe_path()` allowed whitespace in SLURM paths. | Restricted `extra_sbatch` to single flags without quotes/spaces/metachars and blocked `--wrap`/`--prolog`/`--epilog`/`--output`/`--error`/`--chdir`/`--export`/`--batch`/`--input`; set `allow_spaces = FALSE` by default in `sp_assert_safe_path()`. |
| **H1** | HIGH | `R/security.R`, `R/backend_ssh.R` | `sp_assert_safe_ssh_options()` allowed `-F`, `-S`, `-L/-R/-D/-W`, `-A`, `-J`, `-i`, and `-oIdentityFile`/`ControlPath`/`ProxyJump`; `build_scp_args()` permitted remote shell metacharacters. | Extended `sp_assert_safe_ssh_options()` to block dangerous SSH CLI flags (including bundled short flags) and directives; rejected whitespace and shell metacharacters in `build_scp_args()` `src` and `dest`. |
| **H2** | HIGH | `R/container_hook.R` | `use_rcapsule_container()` did not recognize native `rcapsule` v0.4.0+ classes (`rcapsule_apptainer_spec`, `rcapsule_apptainer`, `rcapsule_manifest`, `rcapsule_bundle`, `rcapsule_export`) or fields (`def_content`, `def_sha256`, `bind_paths`, `integrity$content_digest`, `specs$apptainer`). | Added native zero-dependency compatibility with all `rcapsule` container, manifest, and bundle objects, deriving `.sif`/SHA-256 fallback paths and preserving `def_content` and `bind_paths`. |
| **H3** | HIGH | `R/security.R`, `R/backend_ssh.R`, `R/sbatch.R` | Default `remote_dir = "~/slurmpilot_jobs"` was single-quoted (`'~/...'`), disabling POSIX tilde expansion in `mkdir`, `sbatch`, `WORK_DIR`, and `--output`. | Added `sp_sh_quote_path()` expanding `~/rest` to `"$HOME"/'rest'`; stripped leading `~/` in `#SBATCH --output/--error` and bound `"${WORK_DIR}:${WORK_DIR}"`. |
| **H4** | HIGH | `R/sbatch.R` | `apptainer exec --cleanenv` stripped host `OMP_NUM_THREADS`, `SLURMPILOT_*`, and user `env_vars` (including `SLURMPILOT_CONTAINER_DIGEST`). | Automatically mirrored thread limits, `SLURMPILOT_*`, and user `env_vars` as `APPTAINERENV_*` exports whenever `container_sif` is set. |
| **H5** | HIGH | `R/security.R` | `sp_assert_path_confined()` relied on `normalizePath(mustWork = FALSE)`, missing `..` traversal under non-existent subdirs and dangling external symlinks. | Added `sp_resolve_real_path()` walking existing ancestors via `Sys.readlink()` with cycle caps and explicit raw/resolved `..` rejection. |
| **H6** | HIGH | `R/globals.R`, `R/pilot.R`, `R/backend_mock.R`, `R/shiny_submit.R`, `R/sbatch.R` | `inspect_job_globals()` triggered active bindings, under-counted nested environments, and missed nested credentials; child processes inherited ambient secrets; `.sbatch` lacked `0600` mode. | Guarded `bindingIsActive()`, switched nested-env sizing to `serialize()`, added nested secret scanning, scrubbed ambient credentials via `sp_callr_scrubbed_env()` / `sp_scrub_ambient_env()` (with `R_ENVIRON_USER=""`), forwarded explicit `job_spec$env_vars` in `MockSlurmBackend`, warned on secret `env_vars`, and set `0600` permissions on written `.sbatch` files. |
| **M1** | MEDIUM | `R/backend_ssh.R` | `SlurmSshBackend$retry()` dropped per-job `container_binds`; live `submit()` allowed `afterok:DRY_RUN` attached to `job_spec`. | Merged `self$container_binds` and `rec$job_spec$container_binds` on retry; enforced `sp_assert_safe_slurm_dependency(..., allow_dry_run = isTRUE(self$dry_run))` on all effective dependencies. |
| **M2** | MEDIUM | `R/pipeline.R` | `slurm_pipeline_run(wait = FALSE)` violated DAG ordering on `MockSlurmBackend`; `stop_on_failure = FALSE` skipped downstream stages; `afterany` skipped after `SKIPPED`; 0-task dynamic stages crashed. | Aborted cleanly on `wait = FALSE` with edges on `MockSlurmBackend`; honored `stop_on_failure` and `"SKIPPED"`/`"OUT_OF_MEMORY"`/`"TIMEOUT"` in `sp_dependency_satisfied()`; cleanly marked 0-task dynamic stages `"SKIPPED"`. |
| **M3** | MEDIUM | `R/efficiency.R` | `slurm_efficiency_report()` crashed on missing `chunk_id` or `Inf` metrics in `plot()`, reported `straggler_ratio = 1.0` on zero median, and classified 100%-failed jobs as `"efficient"`. | Synthesized `chunk_id`, sanitized non-finite metrics, returned `Inf` straggler ratio when `wall_med == 0 && wall_max > 0`, and classified all-failed non-OOM/non-TIMEOUT jobs as `"failed"`. |
| **M4** | MEDIUM | `R/security.R`, `R/apptainer.R` | `cran_repo` permitted `$VAR` shell expansion inside double-quoted `%post`; empty `apt_packages` emitted broken trailing backslash syntax. | Rejected `$` in `sp_assert_safe_url()` and omitted the `apt-get` install block when `apt_packages` is empty. |
| **M5** | MEDIUM | `R/utils.R`, `R/backend_ssh.R` | Unbounded `parse_slurm_array_spec()` ranges and $O(N^2)$ `rbind` in `parse_squeue_output()` risked DoS; `parse_sacct_output()` dropped SLURM signal codes (`0:125`). | Added `max_indices = 100000L` bound before `seq.int()`, vectorized `parse_squeue_output()` to $O(N)$, and mapped `0:<sig>` exit codes to `128L + sig`. |
| **M6** | MEDIUM | `R/shiny_submit.R` | Empty or throwing `args_builder` crashed the Shiny session inside `observeEvent()`. | Wrapped pilot, estimation, and submission handlers in `tryCatch()`, resetting state and displaying escaped inline error alerts. |
| **M7** | MEDIUM | `R/env_scan.R` | `scan_project_env()` followed symlinks pointing outside the project root. | Filtered auto-discovered `renv.lock`, `DESCRIPTION`, and scripts through `sp_assert_path_confined(..., root_dir = path)`. |
| **M8** | MEDIUM | `R/backend_base.R` | `slurm_collect(simplify = TRUE)` crashed on heterogeneous data-frame columns. | Union-aligned mismatched data-frame columns with `NA` fill and safe list fallback. |
| **L1** | LOW | `R/sbatch.R`, `R/backend_mock.R` | Standalone `worker.R` honored ambient `SLURMPILOT_MOCK_FAULT` outside mock runs. | Gated `SLURMPILOT_MOCK_FAULT` strictly to `SLURMPILOT_BACKEND == "mock"`. |
| **L2** | LOW | `R/utils.R`, `R/resources.R` | `plan_chunks(..., strategy = "lpt")` scaled as $O(N \cdot M \log M)$ and `estimate_resources()`/`scale_resources()` re-partitioned twice. | Vectorized `round_robin`, replaced LPT `order()` with C-level `which.min()` + $O(N \log M)$ binary min-heap for `> 2048` chunks, and reused precomputed chunks. |

## Reporting a Vulnerability

Please report suspected security issues via GitHub Issues or directly to `marcus.harris.uconn@gmail.com`.
