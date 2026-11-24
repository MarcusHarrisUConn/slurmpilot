# Attach a Validated Apptainer or `rcapsule` Container to a SLURM Job Spec

Provides a zero-hard-dependency handoff between reproducible container
builders (such as `rcapsule` manifests/specs,
[`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md)
recipes, or pre-built `.sif` / `.def` file paths) and
[`slurm_job_spec()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_job_spec.md).
Strictly validates all container paths and `--bind` mounts against
traversal and shell/option injection, records provenance metadata
(`digest`, `r_version`, `def_path`, `source`), and injects
`SLURMPILOT_CONTAINER_DIGEST` into the job environment when a
cryptographic digest is supplied.

## Usage

``` r
use_rcapsule_container(
  spec = NULL,
  container,
  binds = character(),
  check_exists = FALSE
)
```

## Arguments

- spec:

  Optional `slurmpilot_job_spec` object to update. When `NULL`, returns
  a standalone validated `"slurmpilot_container_spec"` object.

- container:

  Container descriptor: either (a) a character path to an Apptainer
  `.sif` image or `.def` recipe, (b) a `slurmpilot_apptainer_def` object
  from
  [`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md),
  or (c) a duck-typed `rcapsule` spec or manifest list containing fields
  such as `apptainer_sif` / `sif_path` / `image`, `apptainer_def` /
  `def_path` / `recipe_path`, `content_digest` / `capsule_hash` /
  `env_hash`, `r_version`, `binds`, or nested `targets$apptainer` /
  `manifest`.

- binds:

  Optional character vector of extra Apptainer `--bind` mounts (e.g.
  `"/data:/data:ro"`).

- check_exists:

  Logical; if `TRUE`, asserts that any resolved local `.sif` or `.def`
  path exists on disk. Default `FALSE` (cluster paths often exist only
  on the remote HPC filesystem).

## Value

Updated `slurmpilot_job_spec` (when `spec` is supplied) or a
`"slurmpilot_container_spec"` object (when `spec` is `NULL`).

## See also

[`slurm_job_spec()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_job_spec.md),
[`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md),
[`render_sbatch_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_sbatch_script.md)

## Examples

``` r
spec <- slurm_job_spec(
  fun = function(x) x + 1,
  args_list = list(1, 2),
  resources = resource_spec(2L)
)
capsule <- list(
  sif_path = "/scratch/containers/analysis.sif",
  def_path = "/scratch/containers/analysis.def",
  content_digest = "a1b2c3d4e5f6",
  r_version = "4.4.1",
  binds = c("/scratch/data:/data:ro")
)
spec2 <- use_rcapsule_container(spec, capsule)
spec2$container_sif
#> [1] "/scratch/containers/analysis.sif"
```
