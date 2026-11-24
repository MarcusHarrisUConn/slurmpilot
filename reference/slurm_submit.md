# Submit a Job to a `slurmpilot` Scheduler Backend

Submits either a pre-built
[`slurm_job_spec()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_job_spec.md)
or a `fun` + `args_list` workload to any
[SlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.md)
(such as
[MockSlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/MockSlurmBackend.md)
or
[SlurmSshBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmSshBackend.md)).

## Usage

``` r
slurm_submit(
  backend,
  fun,
  args_list = NULL,
  resources = NULL,
  name = NULL,
  packages = character(),
  globals = list(),
  seed = NULL,
  ...
)
```

## Arguments

- backend:

  A
  [SlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.md)
  R6 object.

- fun:

  Either a `slurmpilot_job_spec` object OR a worker function `fun(arg)`.

- args_list:

  List of per-task arguments (required when `fun` is a function).

- resources:

  Optional `slurmpilot_resources` object.

- name:

  Optional job name.

- packages:

  Character vector of worker packages.

- globals:

  Named list of worker globals.

- seed:

  Optional integer base seed.

- ...:

  Additional backend-specific arguments forwarded to `backend$submit()`
  (e.g. `fault_injection` for
  [MockSlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/MockSlurmBackend.md)).

## Value

A `slurmpilot_job` handle.

## See also

[`slurm_status()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_status.md),
[`slurm_wait()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_wait.md),
[`slurm_retry()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_retry.md),
[`slurm_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_collect.md)

## Examples

``` r
be <- mock_slurm_backend(max_workers = 1L)
job <- slurm_submit(be, function(x) x + 1, as.list(1:4),
                    resources = resource_spec(4L, chunk_size = 2L))
st <- slurm_wait(job, poll_interval = 0.05)
slurm_collect(job, simplify = TRUE)
#> [1] 2 3 4 5
unlink(be$root_dir, recursive = TRUE)
```
