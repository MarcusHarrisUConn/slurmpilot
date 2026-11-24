# Build a Reproducible Apptainer/Singularity `.def` Recipe

Generates an HPC-ready Apptainer (formerly Singularity) container
definition file from a
[`scan_project_env()`](https://marcusharrisphd.com/slurmpilot/reference/scan_project_env.md)
manifest (or project directory path). Automatically includes minimal
Debian/Ubuntu system libraries for detected compiled toolchains (`Rcpp`,
`cmdstanr`, `RTMB`, `TMB`, `JAGS`, `sf`, etc.), thread-safe BLAS/OpenMP
defaults, `renv::restore()` or pinned CRAN installs, optional CmdStan
installation, and container smoke tests (`%test`).

## Usage

``` r
build_apptainer_def(
  env,
  base_image = NULL,
  r_version = NULL,
  output_path = NULL,
  install_cmdstan = NULL,
  cmdstan_version = "2.35.0",
  renv_restore = NULL,
  cran_repo = "https://packagemanager.posit.co/cran/__linux__/jammy/latest",
  image_name = "slurmpilot_env.sif",
  labels = list(),
  extra_apt = character(),
  extra_post = character()
)
```

## Arguments

- env:

  A `slurmpilot_env` object from
  [`scan_project_env()`](https://marcusharrisphd.com/slurmpilot/reference/scan_project_env.md),
  or a path to a project directory to scan automatically.

- base_image:

  Optional Docker base image (defaults to `"rocker/r-ver:<r_version>"`).

- r_version:

  Optional R version string overriding `env$r_version`.

- output_path:

  Optional file path to write the `.def` recipe to disk.

- install_cmdstan:

  Optional logical controlling whether to build CmdStan inside
  `/opt/cmdstan`. Defaults to `"cmdstan" %in% env$toolchains`.

- cmdstan_version:

  Character CmdStan version when `install_cmdstan` is `TRUE`. Default
  `"2.35.0"`.

- renv_restore:

  Optional logical; if `TRUE`, copies `renv.lock` via `%files` and runs
  `renv::restore()`. Defaults to `env$has_renv_lock`.

- cran_repo:

  CRAN/Posit Package Manager repository URL used inside `%post`.

- image_name:

  Target `.sif` filename used in the suggested build command. Default
  `"slurmpilot_env.sif"`.

- labels:

  Optional named list of extra `%labels` entries.

- extra_apt:

  Optional character vector of extra Debian/Ubuntu apt packages.

- extra_post:

  Optional character vector of extra shell lines appended to `%post`
  before apt cache cleanup.

## Value

An S3 object of class `"slurmpilot_apptainer_def"` containing `recipe`
(character vector of lines), `text` (single string), `path`,
`base_image`, `image_name`, `build_command`, and `env`.

## See also

[`scan_project_env()`](https://marcusharrisphd.com/slurmpilot/reference/scan_project_env.md),
[`render_sbatch_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_sbatch_script.md)

## Examples

``` r
env <- scan_project_env(extra_packages = c("lme4", "Rcpp", "RTMB"))
def <- build_apptainer_def(env)
cat(def$text)
#> Bootstrap: docker
#> From: rocker/r-ver:4.6.2
#> 
#> %labels
#>     GeneratedBy slurmpilot
#>     RVersion 4.6.2
#>     Toolchains cpp,tmb,linear_algebra
#>     EnvHash a58a0203d04b
#> 
#> %environment
#>     export LC_ALL=C.UTF-8
#>     export LANG=C.UTF-8
#>     export OMP_NUM_THREADS=1
#>     export OPENBLAS_NUM_THREADS=1
#>     export MKL_NUM_THREADS=1
#>     export R_REMOTES_NO_ERRORS_FROM_WARNINGS=true
#> 
#> %post
#>     set -eu
#>     export DEBIAN_FRONTEND=noninteractive
#>     apt-get update && apt-get install -y --no-install-recommends \
#>         build-essential \
#>         ca-certificates \
#>         cmake \
#>         g++ \
#>         gfortran \
#>         liblapack-dev \
#>         libnlopt-dev \
#>         libopenblas-dev \
#>         make
#> 
#>     mkdir -p /root/.R
#>     cat <<'EOF' > /root/.R/Makevars
#> CXX17 = g++
#> CXX17FLAGS = -O3 -fPIC
#> CXX17STD = -std=c++17
#> EOF
#> 
#>     Rscript -e "install.packages(c('RTMB', 'Rcpp', 'lme4'), repos = 'https://packagemanager.posit.co/cran/__linux__/jammy/latest', Ncpus = max(1L, parallel::detectCores() - 1L))"
#> 
#>     apt-get clean
#>     rm -rf /var/lib/apt/lists/*
#> 
#> %test
#>     Rscript -e "cat('R:', R.version.string, '\n')"
#>     Rscript -e "stopifnot(all(vapply(c('RTMB', 'Rcpp', 'lme4'), requireNamespace, logical(1L), quietly = TRUE)))"
#> 
#> %runscript
#>     exec Rscript "$@"
```
