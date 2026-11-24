# Security Policy & v0.2.0 Hardening Audit (slurmpilot)

## Threat Model

`slurmpilot` generates executable shell scripts (`sbatch`), container
recipes (Apptainer `.def`), non-interactive remote `ssh`/`scp`
invocations, filesystem checkpoints (`.rds`/`.json`), and interactive
`Shiny` HTML views. Untrusted or malformed metadata (e.g., user-supplied
Shiny inputs, project `renv.lock` files, remote scheduler output, or
shared-filesystem corruption) could otherwise lead to:

1.  **`#SBATCH` & Shell Command Injection** on HPC login/compute nodes.
2.  **SSH / SCP Argument & Option Injection** (`-oProxyCommand=...`,
    leading-dash host/path smuggling).
3.  **Apptainer Definition Section / Code Injection** via untrusted
    `renv.lock` package names, base image refs, or CRAN URLs.
4.  **Path Traversal (`../`) & Workspace Escape** in staging,
    checkpoint, or log paths.
5.  **Silent Checkpoint Corruption / Partial Write Ingestion** on shared
    HPC filesystems (Lustre/GPFS/NFS).
6.  **Shiny HTML/XSS Injection, Unbounded Resource Requests, or Reactive
    Polling Loops**.
7.  **Parallel RNG Stream Collisions** across SLURM array jobs causing
    correlated Monte Carlo draws.

------------------------------------------------------------------------

## Findings Identified & Remediated in v0.2.0

All centralized security guards live in `R/security.R` and are enforced
across every entry point and template boundary:

| ID | Component | Vulnerability Found in v0.1.0 | Remediation in v0.2.0 |
|----|----|----|----|
| **S1** | `R/sbatch.R`, `R/resources.R` | `partition`, `account`, `qos`, `mail_user`, `mail_type`, and `extra_sbatch` allowed newlines (`\n`/`\r`) and shell metacharacters, permitting `#SBATCH` breakout and inline command execution (including `--wrap`). | Enforced `sp_assert_safe_slurm_token()`, `sp_assert_safe_email()`, `sp_assert_safe_mail_type()`, and `sp_assert_safe_extra_sbatch()` blocking control chars, metacharacters, leading `-` on tokens, and `--wrap`. |
| **S2** | `R/sbatch.R` | `modules` interpolated directly into `module load <m>` without validation. | Enforced `sp_assert_safe_module_name()` restricting module specs to `^[A-Za-z0-9][A-Za-z0-9_./+-]{0,127}$` with zero `..` or shell syntax. |
| **S3** | `R/sbatch.R`, `R/job.R` | `env_vars` keys were unvalidated before `export <KEY>=<VAL>`. | Enforced `sp_assert_safe_env_name()` (`^[A-Za-z_][A-Za-z0-9_]{0,127}$`) and control-char rejection on all values alongside POSIX single-quoting (`sp_sh_quote()`). |
| **S4** | `R/sbatch.R` | `work_dir`, `log_dir`, `worker_script`, `container_sif`, and `container_binds` lacked traversal (`..`), leading-dash, and metacharacter guards. | Enforced `sp_assert_safe_path()`, `sp_assert_safe_relpath()`, and `sp_assert_safe_apptainer_bind()`. |
| **S5** | `R/utils.R`, `R/sbatch.R`, `R/job.R` | `sp_sanitize_name()` permitted leading `-`/`.` edge cases; `job_name` did not reject control/metacharacter payloads upfront. | Hardened `sp_sanitize_name()` to strip leading/trailing `[._-]` and `..`, and explicitly rejected control/shell metacharacters in [`slurm_job_spec()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_job_spec.md) and [`render_sbatch_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_sbatch_script.md). |
| **S6** | `R/backend_ssh.R` | [`build_ssh_args()`](https://marcusharrisphd.com/slurmpilot/reference/build_ssh_args.md) and [`build_scp_args()`](https://marcusharrisphd.com/slurmpilot/reference/build_scp_args.md) lacked leading-dash guards and `--` end-of-options delimiters, exposing `host`/`user`/`src`/`dest` to CLI flag injection. | Enforced `sp_assert_safe_ssh_host()`, `sp_assert_safe_ssh_user()`, leading-dash/traversal checks on `src`/`dest`, and explicit `"--"` option terminators in `ssh` and `scp`. |
| **S7** | `R/backend_ssh.R` | `ssh_options` allowed arbitrary directives such as `ProxyCommand` or `LocalCommand`. | Enforced `sp_assert_safe_ssh_options()` blocking `ProxyCommand`, `LocalCommand`, `PermitLocalCommand`, `RemoteCommand`, `ProxyUseFdpass`, `KnownHostsCommand`, `Match`, and `Include`. |
| **S8** | `R/backend_ssh.R` | [`build_scancel_command()`](https://marcusharrisphd.com/slurmpilot/reference/build_scancel_command.md) and `status()` interpolated `slurm_job_id` without enforcing numeric-only format. | Enforced `sp_assert_safe_slurm_job_id()` (`^[0-9]{1,20}$`). |
| **S9** | `R/backend_base.R`, `R/backend_mock.R`, `R/backend_ssh.R` | Job IDs and resolved checkpoint/status paths lacked canonical root confinement checks. | Enforced `sp_assert_safe_id()` and `sp_assert_path_confined()` across staging, checkpointing, and job lookup. |
| **S10** | `R/apptainer.R`, `R/env_scan.R` | Untrusted `base_image`, `r_version`, `cmdstan_version`, `cran_repo`, package names, `apt` names, `labels`, and `extra_post` could break out of Apptainer `.def` sections or inject R/shell code. | Enforced `sp_assert_safe_docker_image()`, `sp_assert_safe_version()`, `sp_assert_safe_url()`, `sp_assert_safe_r_package()`, `sp_assert_safe_apt_package()`, `sp_assert_safe_apptainer_post()`, and strict `%environment` quoting. |
| **S11** | `R/sbatch.R`, `R/backend_base.R`, `R/utils.R` | Checkpoints lacked cryptographic digest verification; atomic writers and ID generator consumed global `.Random.seed`. | Added SHA-256 sidecars (`chunk_XXXX.rds.sha256` + `status/chunk_XXXX.json` digest) verified via [`verify_checkpoint()`](https://marcusharrisphd.com/slurmpilot/reference/verify_checkpoint.md) in [`slurm_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_collect.md) and `worker.R`; switched IDs and atomic temp files to RNG-free monotonic entropy. |
| **S12** | `R/shiny_submit.R`, `R/shiny_monitor.R` | Shiny numeric inputs lacked `NA`/upper bounds; monitor lacked retry caps and ANSI/length sanitization on error strings/logs. | Added `sp_clamp_int()`/`sp_clamp_num()`, `max_retries` + 1 TB memory cap, isolated polling guard against reactive loops, and `sp_escape_ui_text()` ensuring safe HTML escaping via `htmltools` (zero raw `HTML()`). |

------------------------------------------------------------------------

## Statistical & Runtime Hardening in v0.2.0

- **Heavy-Tailed Walltime Scaling (`R/resources.R`):** Upgraded
  [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md)
  from normal-CLT-only scaling to
  `max(CLT, Fenton-Wilkinson log-normal sum Q99, nonparametric order-statistic bound)`,
  plus overflow-safe sub-millisecond chunking and pilot crash/OOM
  recovery diagnostics.
- **Mathematically Independent Parallel RNG (`R/sbatch.R`, `R/pilot.R`,
  `R/utils.R`):** Replaced naive `set.seed(seed + task_id)` with
  hierarchical `L'Ecuyer-CMRG` substreams via
  [`parallel::nextRNGStream()`](https://rdrr.io/r/parallel/RngStream.html)
  (per-chunk, $`2^{127}`$ apart) and
  [`parallel::nextRNGSubStream()`](https://rdrr.io/r/parallel/RngStream.html)
  (per-task, $`2^{76}`$ apart), exposed cleanly via
  [`slurmpilot_rng_stream()`](https://marcusharrisphd.com/slurmpilot/reference/slurmpilot_rng_stream.md).
- **Deterministic Process Reaping (`R/backend_mock.R`, `R/pilot.R`):**
  Added `sp_kill_and_reap()` and `MockSlurmBackend$shutdown()`
  guaranteeing zero zombie or lingering child processes on cancel,
  timeout, OOM, or garbage collection, plus race-safe `wait()` before
  reading exit telemetry.

## Reporting a Vulnerability

Please report suspected security issues via GitHub Issues or directly to
`marcus.harris.uconn@gmail.com`.
