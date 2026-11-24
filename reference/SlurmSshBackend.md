# Production SSH/SLURM Scheduler Backend

Orchestrates remote SLURM array jobs over SSH/SCP with zero dependency
on ZeroMQ or open worker ports. Stages self-contained bundles
(`payload.rds`, `chunks.rds`, standalone `worker.R`, and
`submit.sbatch`), submits array jobs with `sbatch --parsable`,
reconciles live `squeue` and `sacct` telemetry, performs surgical
retries of failed array indices with optional `--mem` / `--time`
scaling, and retrieves completed checkpoints via `scp`.

Accepts an injectable `command_runner` callback (defaulting to
[`processx::run`](http://processx.r-lib.org/reference/run.md)) and
`dry_run = TRUE` mode so every SSH/SLURM workflow can be verified
offline in contract and snapshot tests.

## Super class

[`SlurmBackend`](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.md)
-\> `SlurmSshBackend`

## Public fields

- `name`:

  Backend identifier (`"slurm_ssh"`).

- `host`:

  Remote SLURM login node hostname.

- `user`:

  Optional SSH username.

- `remote_dir`:

  Base directory on the remote cluster for job workspaces.

- `local_stage_dir`:

  Local staging directory for job bundles and retrieved artifacts.

- `port`:

  SSH port (default `22L`).

- `ssh_key`:

  Optional SSH private key path.

- `ssh_options`:

  Optional extra SSH/SCP flags.

- `partition`:

  Optional default SLURM partition.

- `account`:

  Optional default SLURM account.

- `qos`:

  Optional default SLURM QOS.

- `container_sif`:

  Optional default remote Apptainer `.sif` path.

- `container_binds`:

  Optional Apptainer `--bind` mounts.

- `modules`:

  Optional HPC environment modules loaded in `sbatch`.

- `dry_run`:

  Logical; if `TRUE`, stages bundles locally and records commands
  without executing SSH/SCP.

- `ssh_max_retries`:

  Non-negative integer transient SSH/SCP retry limit (default `2L`).

- `ssh_retry_base_sec`:

  Base delay in seconds for bounded exponential SSH backoff (default
  `0.5`).

- `ssh_retry_max_sec`:

  Maximum backoff delay cap in seconds (default `8.0`).

- `command_runner`:

  Function `(cmd, args)` returning `list(status, stdout, stderr)`.

## Methods

### Public methods

- [`SlurmSshBackend$new()`](#method-SlurmSshBackend-initialize)

- [`SlurmSshBackend$submit()`](#method-SlurmSshBackend-submit)

- [`SlurmSshBackend$status()`](#method-SlurmSshBackend-status)

- [`SlurmSshBackend$retry()`](#method-SlurmSshBackend-retry)

- [`SlurmSshBackend$cancel()`](#method-SlurmSshBackend-cancel)

- [`SlurmSshBackend$logs()`](#method-SlurmSshBackend-logs)

- [`SlurmSshBackend$collect()`](#method-SlurmSshBackend-collect)

- [`SlurmSshBackend$print()`](#method-SlurmSshBackend-print)

- [`SlurmSshBackend$clone()`](#method-SlurmSshBackend-clone)

Inherited methods

- [`SlurmBackend$cleanup()`](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.html#method-cleanup)
- [`SlurmBackend$wait()`](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.html#method-wait)

------------------------------------------------------------------------

### `SlurmSshBackend$new()`

Create a new `SlurmSshBackend`.

#### Usage

    SlurmSshBackend$new(
      host,
      user = NULL,
      remote_dir = "~/slurmpilot_jobs",
      local_stage_dir = NULL,
      port = 22L,
      ssh_key = NULL,
      ssh_options = character(),
      partition = NULL,
      account = NULL,
      qos = NULL,
      container_sif = NULL,
      container_binds = character(),
      modules = character(),
      dry_run = FALSE,
      ssh_max_retries = 2L,
      ssh_retry_base_sec = 0.5,
      ssh_retry_max_sec = 8,
      command_runner = NULL
    )

#### Arguments

- `host`:

  Remote SLURM cluster hostname.

- `user`:

  Optional SSH username.

- `remote_dir`:

  Base remote workspace directory. Default `"~/slurmpilot_jobs"`.

- `local_stage_dir`:

  Local staging directory. Defaults to a temporary directory.

- `port`:

  SSH port integer. Default `22L`.

- `ssh_key`:

  Optional private SSH key path.

- `ssh_options`:

  Optional extra SSH options.

- `partition`:

  Optional default SLURM `--partition`.

- `account`:

  Optional default SLURM `--account`.

- `qos`:

  Optional default SLURM `--qos`.

- `container_sif`:

  Optional remote path to Apptainer `.sif` image.

- `container_binds`:

  Optional character vector of Apptainer bind mounts.

- `modules`:

  Optional character vector of HPC modules to load.

- `dry_run`:

  Logical; record commands without making network calls. Default
  `FALSE`.

- `ssh_max_retries`:

  Non-negative integer retries on transient SSH/SCP transport errors.
  Default `2L`.

- `ssh_retry_base_sec`:

  Base backoff delay in seconds. Default `0.5`.

- `ssh_retry_max_sec`:

  Maximum backoff delay cap in seconds. Default `8.0`.

- `command_runner`:

  Optional runner `function(cmd, args)` overriding
  [`processx::run`](http://processx.r-lib.org/reference/run.md).

------------------------------------------------------------------------

### `SlurmSshBackend$submit()`

Stage and submit a SLURM array job over SSH/SCP.

#### Usage

    SlurmSshBackend$submit(job_spec, ...)

#### Arguments

- `job_spec`:

  A `slurmpilot_job_spec` object.

- `...`:

  Unused.

#### Returns

A `slurmpilot_job` handle.

------------------------------------------------------------------------

### `SlurmSshBackend$status()`

Query `squeue` and `sacct` over SSH and reconcile chunk states.

#### Usage

    SlurmSshBackend$status(job)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

#### Returns

A `slurmpilot_status` object.

------------------------------------------------------------------------

### `SlurmSshBackend$retry()`

Surgically resubmit only failed/OOM/timeout/cancelled array indices.

#### Usage

    SlurmSshBackend$retry(job, chunks = NULL, resources = NULL)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `chunks`:

  Optional integer vector of array indices to retry.

- `resources`:

  Optional updated `slurmpilot_resources` spec.

#### Returns

Updated `slurmpilot_job` handle.

------------------------------------------------------------------------

### `SlurmSshBackend$cancel()`

Cancel active SLURM array job(s) or targeted chunk indices via
`scancel`.

#### Usage

    SlurmSshBackend$cancel(job, chunks = NULL)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `chunks`:

  Optional integer vector of chunk IDs to cancel.

#### Returns

Latest `slurmpilot_status` invisibly.

------------------------------------------------------------------------

### `SlurmSshBackend$logs()`

Retrieve remote stdout/stderr logs via SSH.

#### Usage

    SlurmSshBackend$logs(job, chunk_id = NULL)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `chunk_id`:

  Optional integer chunk ID.

#### Returns

Named list of log records (`chunk_id`, `stdout`, `stderr`).

------------------------------------------------------------------------

### `SlurmSshBackend$collect()`

Retrieve remote chunk checkpoints via SCP and collect ordered task
results.

#### Usage

    SlurmSshBackend$collect(job, simplify = FALSE, allow_partial = FALSE)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `simplify`:

  Logical; simplify homogeneous scalar or data-frame results.

- `allow_partial`:

  Logical; allow collecting incomplete results.

#### Returns

Ordered list (or simplified vector/tibble) of task results.

------------------------------------------------------------------------

### `SlurmSshBackend$print()`

Print concise summary of the SSH/SLURM backend.

#### Usage

    SlurmSshBackend$print()

------------------------------------------------------------------------

### `SlurmSshBackend$clone()`

The objects of this class are cloneable with this method.

#### Usage

    SlurmSshBackend$clone(deep = FALSE)

#### Arguments

- `deep`:

  Whether to make a deep clone.

## Examples

``` r
ssh <- SlurmSshBackend$new(host = "hpc.example.edu", user = "researcher", dry_run = TRUE)
print(ssh)
#> <<SlurmSshBackend>> target=researcher@hpc.example.edu,
#> remote_dir=~/slurmpilot_jobs, dry_run=TRUE
unlink(ssh$local_stage_dir, recursive = TRUE)
```
