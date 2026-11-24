# Construct a Validated Multi-Stage SLURM Pipeline DAG

Assembles two or more (or single)
[`slurm_stage()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_stage.md)
definitions into a directed acyclic graph (DAG), verifying unique stage
names, valid upstream references, and acyclicity via Kahn's topological
sort. Supports linear chains, fan-out, fan-in, and diamond DAGs.

## Usage

``` r
slurm_pipeline(..., stages = NULL, name = "slurmpilot_pipeline")
```

## Arguments

- ...:

  One or more `slurmpilot_stage` objects created by
  [`slurm_stage()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_stage.md).

- stages:

  Optional list of `slurmpilot_stage` objects (alternative to passing
  stages via `...`).

- name:

  Character pipeline name (sanitized for SLURM job prefixes). Default
  `"slurmpilot_pipeline"`.

## Value

An S3 object of class `"slurmpilot_pipeline"` containing `name`,
`stages`, `order` (topological execution order), `levels` (DAG depth per
stage), `roots`, `sinks`, and `edges` (tibble of `from -> to` edges).

## See also

[`slurm_stage()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_stage.md),
[`slurm_pipeline_run()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_run.md),
[`slurm_pipeline_status()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_status.md),
[`slurm_pipeline_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_collect.md)

## Examples

``` r
s1 <- slurm_stage("branch_a", fun = function(x) x + 1, args_list = list(1, 2))
s2 <- slurm_stage("branch_b", fun = function(x) x * 10, args_list = list(1, 2))
s3 <- slurm_stage(
  "combine",
  fun = function(up) sum(up$branch_a) + sum(up$branch_b),
  depends_on = c("branch_a", "branch_b")
)
pipe <- slurm_pipeline(s1, s2, s3, name = "diamond_demo")
print(pipe)
#> 
#> ── slurmpilot Pipeline DAG: diamond_demo 
#> • Stages: 3 | Edges: 2 | Roots: branch_a, branch_b | Sinks: combine
#> • Topological order: branch_a -> branch_b -> combine
```
