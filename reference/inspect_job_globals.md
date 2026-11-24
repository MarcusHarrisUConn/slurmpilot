# Inspect Worker Function Closures, Globals, and Serialization Bundle Size

Performs a pre-submission static and memory audit of a worker function
`fun`, its lexical closure environment, explicit `globals`, `packages`,
and optional `args_list`. Detects two common HPC failure modes before
staging:

1.  **Accidental closure bloat:** A function defined inside another
    function silently captures large local objects (such as raw datasets
    \>50 MB) in its enclosing frame, inflating `payload.rds` for every
    SLURM array task.

2.  **Missing or unexported globals:** Free variables or local helper
    functions referenced inside `fun` that are neither exported by
    `packages` nor explicitly listed in `globals`, which would fail on
    isolated cluster workers.

## Usage

``` r
inspect_job_globals(
  fun,
  args_list = NULL,
  globals = list(),
  packages = character(),
  size_warn_mb = 50
)
```

## Arguments

- fun:

  Worker function `fun(arg)` to inspect.

- args_list:

  Optional list of task arguments included in bundle size estimation.

- globals:

  Optional named list of explicit worker globals.

- packages:

  Character vector of packages declared for worker nodes.

- size_warn_mb:

  Numeric threshold in MB above which captured closure objects or total
  estimated bundle size trigger a diagnostic warning. Default `50`.

## Value

An S3 object of class `"slurmpilot_globals_report"` containing:

- `ok`: logical (`TRUE` when zero warnings are emitted).

- `warnings`: character vector of actionable pre-submit warnings.

- `estimated_bundle_mb`: total estimated serialization size in MB.

- `fun_size_mb`, `args_size_mb`, `globals_size_mb`: component sizes in
  MB.

- `closure_objects`: tibble of objects captured in non-global enclosing
  frames (`name`, `class`, `size_mb`, `env_name`).

- `globals_table`: tibble of explicit `globals` (`name`, `class`,
  `size_mb`).

- `missing_variables`: character vector of unresolved free variables.

- `unexported_functions`: character vector of referenced functions not
  found in base/declared `packages` or `globals`.

## See also

[`slurm_job_spec()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_job_spec.md),
[`slurm_submit()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_submit.md)

## Examples

``` r
make_worker <- function() {
  local_offset <- 10
  function(x) x + local_offset
}
rep <- inspect_job_globals(make_worker(), args_list = as.list(1:5))
print(rep)
#> 
#> ── slurmpilot Pre-Submit Globals & Bundle Audit [OK] 
#> • Estimated payload size: 0.00 MB (closure=0.00 MB, globals=0.00 MB, args=0.00
#>   MB)
#> • Captured local closure objects: 4 | Explicit globals: 0
#> • Unresolved variables: 0 | Unexported functions: 0
```
