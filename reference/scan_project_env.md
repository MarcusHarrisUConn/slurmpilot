# Scan an R Project for Package Dependencies and Compiled HPC Toolchains

Inspects `renv.lock`, `DESCRIPTION`, and R/Rmd/Quarto source scripts to
build a unified manifest of R packages, R version, compiled toolchains
(`Rcpp`, `cmdstanr`, `RTMB`, `TMB`, `rstan`, `JAGS`, `sf`, etc.), and
required Debian/Ubuntu system libraries for container packaging via
[`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md).

## Usage

``` r
scan_project_env(
  path = NULL,
  renv_lock = NULL,
  description = NULL,
  scripts = NULL,
  extra_packages = character(),
  include_suggests = FALSE
)
```

## Arguments

- path:

  Optional project root directory to scan automatically.

- renv_lock:

  Optional explicit path to an `renv.lock` file.

- description:

  Optional explicit path to a `DESCRIPTION` file.

- scripts:

  Optional character vector of `.R`, `.Rmd`, or `.qmd` script paths to
  scan for package imports.

- extra_packages:

  Character vector of additional R packages to include explicitly.

- include_suggests:

  Logical; if `TRUE`, also includes `Suggests` from `DESCRIPTION`.
  Default `FALSE`.

## Value

An S3 object of class `"slurmpilot_env"` containing `r_version`,
`packages` (a tibble), `toolchains`, `apt_packages`, `env_vars`,
`needs_makevars`, `has_renv_lock`, `renv_lock_path`, `sources_scanned`,
and `env_hash`.

## See also

[`toolchain_registry()`](https://marcusharrisphd.com/slurmpilot/reference/toolchain_registry.md),
[`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md)

## Examples

``` r
env <- scan_project_env(extra_packages = c("lme4", "cmdstanr", "Rcpp"))
print(env)
#> 
#> ── slurmpilot HPC Environment Manifest 
#> • R version: 4.6.2 (env hash: a4071f53e82e)
#> • Packages detected: 3 (renv.lock: FALSE)
#> • Compiled toolchains: cpp, cmdstan, linear_algebra
#> • System apt packages (11): build-essential, ca-certificates, cmake, curl, g++,
#>   gfortran, liblapack-dev, libnlopt-dev, ...
```
