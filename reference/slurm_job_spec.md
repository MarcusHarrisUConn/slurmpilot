# Construct a SLURM Array Job Specification

Bundles a worker function, argument list, resource plan, packages,
globals, and optional Apptainer/module metadata into a validated
`slurmpilot_job_spec` ready for
[`slurm_submit()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_submit.md).

## Usage

``` r
slurm_job_spec(
  fun,
  args_list,
  resources = NULL,
  name = NULL,
  packages = character(),
  globals = list(),
  seed = NULL,
  continue_on_error = FALSE,
  container_sif = NULL,
  container_binds = character(),
  modules = character(),
  env_vars = list(),
  dependency = NULL,
  warn_bundle_mb = 50
)
```

## Arguments

- fun:

  Function accepting a single element of `args_list` (`fun(arg)`).

- args_list:

  Non-empty list (or vector coercible to list) of task inputs.

- resources:

  Optional `slurmpilot_resources` object from
  [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md)
  or
  [`resource_spec()`](https://marcusharrisphd.com/slurmpilot/reference/resource_spec.md).
  If `NULL`, creates a sensible default
  `resource_spec(n_tasks = length(args_list))`.

- name:

  Optional job name (sanitized for SLURM `--job-name`).

- packages:

  Character vector of packages to load on workers.

- globals:

  Named list of helper objects/functions bound to `fun`.

- seed:

  Optional integer base seed (task `i` uses `seed + i`).

- continue_on_error:

  Logical; if `TRUE`, writes partial chunk checkpoints even if
  individual tasks error. Default `FALSE`.

- container_sif:

  Optional path to Apptainer `.sif` image.

- container_binds:

  Optional character vector of Apptainer `--bind` mounts.

- modules:

  Optional character vector of HPC modules to load.

- env_vars:

  Optional named list/vector of extra environment variables.

- dependency:

  Optional SLURM `--dependency` string (e.g. `"afterok:12345"`).

- warn_bundle_mb:

  Optional numeric size threshold in MB (default `50`); emits a
  diagnostic warning if the serialized payload (`fun`, closure,
  `args_list`, `globals`) exceeds this threshold. Set `Inf` to disable.

## Value

An S3 object of class `"slurmpilot_job_spec"`.

## See also

[`slurm_submit()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_submit.md),
[`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md),
[`inspect_job_globals()`](https://marcusharrisphd.com/slurmpilot/reference/inspect_job_globals.md),
[`use_rcapsule_container()`](https://marcusharrisphd.com/slurmpilot/reference/use_rcapsule_container.md)

## Examples

``` r
spec <- slurm_job_spec(
  fun = function(x) x^2,
  args_list = as.list(1:10),
  resources = resource_spec(n_tasks = 10, chunk_size = 5),
  name = "squares"
)
print(spec)
#> 
#> ── slurmpilot Job Specification (squares) 
#> • Tasks: 10 across 2 chunks (5 tasks/chunk)
#> • Resources: --array=1-2 --cpus-per-task=1 --mem=1G --time=00:15:00
#> • Packages: none
```
