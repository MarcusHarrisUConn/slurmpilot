# Define a Stage in a Multi-Stage SLURM Pipeline DAG

Declares one executable node of a dependent HPC workflow assembled with
[`slurm_pipeline()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline.md)
and executed with
[`slurm_pipeline_run()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_run.md).
Upstream stage outputs are passed into downstream stages either via
`args_from_upstream` (a function mapping the named list of upstream
results to a new `args_list`) or automatically as a single fan-in task
`fun(upstream_results)` when both `args_list` and `args_from_upstream`
are `NULL`.

## Usage

``` r
slurm_stage(
  name,
  fun,
  args_list = NULL,
  args_from_upstream = NULL,
  depends_on = character(),
  resources = NULL,
  packages = character(),
  globals = list(),
  seed = NULL,
  container_sif = NULL,
  container_binds = character(),
  modules = character(),
  env_vars = list(),
  dependency_type = c("afterok", "afterany", "afternotok"),
  simplify_upstream = TRUE
)
```

## Arguments

- name:

  Unique stage identifier (letters, digits, `_`, `-`).

- fun:

  Worker function `fun(arg)` executed for each task in this stage.

- args_list:

  Optional list (or vector coercible to list) of task inputs for this
  stage. Required for root stages (stages with empty `depends_on`).

- args_from_upstream:

  Optional function `function(upstream_results)` returning an
  `args_list` built dynamically from collected upstream stage outputs
  (named by upstream stage name).

- depends_on:

  Character vector of upstream stage names that must finish before this
  stage runs. Default
  [`character()`](https://rdrr.io/r/base/character.html).

- resources:

  Optional `slurmpilot_resources` object (from
  [`resource_spec()`](https://marcusharrisphd.com/slurmpilot/reference/resource_spec.md)
  or
  [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md)).
  If `NULL`, a sensible default spec is constructed automatically at
  runtime from `length(stage_args)`.

- packages:

  Character vector of worker packages to attach.

- globals:

  Named list of helper objects/functions bound to `fun`.

- seed:

  Optional integer base seed for independent `L'Ecuyer-CMRG` parallel
  RNG streams.

- container_sif:

  Optional path to Apptainer `.sif` image.

- container_binds:

  Optional character vector of Apptainer `--bind` mounts.

- modules:

  Optional character vector of HPC modules to load.

- env_vars:

  Optional named list/vector of extra environment variables.

- dependency_type:

  SLURM dependency condition: `"afterok"` (default), `"afterany"`, or
  `"afternotok"`.

- simplify_upstream:

  Logical; passed to
  [`slurm_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_collect.md)
  when collecting upstream stage results for this stage. Default `TRUE`.

## Value

An S3 object of class `"slurmpilot_stage"`.

## See also

[`slurm_pipeline()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline.md),
[`slurm_pipeline_run()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_run.md),
[`slurm_pipeline_status()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_status.md),
[`slurm_pipeline_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_collect.md)

## Examples

``` r
s1 <- slurm_stage("simulate", fun = function(x) x^2, args_list = as.list(1:4))
s2 <- slurm_stage("summarize", fun = function(up) sum(up$simulate), depends_on = "simulate")
print(s1)
#> <<slurmpilot_stage>> "simulate" | tasks=4 | deps=none (root)
```
