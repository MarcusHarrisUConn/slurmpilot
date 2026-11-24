# Built-In Compiled Toolchain and System Dependency Registry

Returns the curated mapping of R packages to compiled toolchains (`cpp`,
`cmdstan`, `rstan`, `tmb`, `jags`, `linear_algebra`, `spatial`,
`http_ssl`, `graphics`, `arrow`), Debian/Ubuntu `apt` system packages,
and container environment variables used by
[`scan_project_env()`](https://marcusharrisphd.com/slurmpilot/reference/scan_project_env.md)
and
[`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md).

## Usage

``` r
toolchain_registry()
```

## Value

A named list of toolchain specification entries.

## Examples

``` r
reg <- toolchain_registry()
names(reg)
#>  [1] "cpp"            "cmdstan"        "rstan"          "tmb"           
#>  [5] "jags"           "linear_algebra" "spatial"        "http_ssl"      
#>  [9] "graphics"       "arrow"         
```
