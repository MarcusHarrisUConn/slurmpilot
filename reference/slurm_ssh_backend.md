# Create an SSH/SLURM Scheduler Backend

Convenience constructor wrapping
[SlurmSshBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmSshBackend.md)`$new(...)`.

## Usage

``` r
slurm_ssh_backend(
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
```

## Arguments

- host:

  Remote SLURM cluster hostname.

- user:

  Optional SSH username.

- remote_dir:

  Base remote workspace directory. Default `"~/slurmpilot_jobs"`.

- local_stage_dir:

  Local staging directory. Defaults to a temporary directory.

- port:

  SSH port integer. Default `22L`.

- ssh_key:

  Optional private SSH key path.

- ssh_options:

  Optional extra SSH options.

- partition:

  Optional default SLURM `--partition`.

- account:

  Optional default SLURM `--account`.

- qos:

  Optional default SLURM `--qos`.

- container_sif:

  Optional remote path to Apptainer `.sif` image.

- container_binds:

  Optional character vector of Apptainer bind mounts.

- modules:

  Optional character vector of HPC modules to load.

- dry_run:

  Logical; record commands without making network calls. Default
  `FALSE`.

- ssh_max_retries:

  Non-negative integer retries on transient SSH/SCP transport errors.
  Default `2L`.

- ssh_retry_base_sec:

  Base backoff delay in seconds. Default `0.5`.

- ssh_retry_max_sec:

  Maximum backoff delay cap in seconds. Default `8.0`.

- command_runner:

  Optional runner `function(cmd, args)` overriding
  [`processx::run`](http://processx.r-lib.org/reference/run.md).

## Value

A
[SlurmSshBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmSshBackend.md)
R6 object.

## Examples

``` r
ssh_be <- slurm_ssh_backend(host = "hpc.example.edu", user = "researcher", dry_run = TRUE)
print(ssh_be)
#> <<SlurmSshBackend>> target=researcher@hpc.example.edu,
#> remote_dir=~/slurmpilot_jobs, dry_run=TRUE
unlink(ssh_be$local_stage_dir, recursive = TRUE)
```
