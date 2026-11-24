# Parse SLURM `sbatch` Output to Extract Job ID

Parses both standard (`"Submitted batch job 123456"`) and `--parsable`
(`"123456"` or `"123456;cluster_name"`) output from `sbatch`.

## Usage

``` r
parse_sbatch_output(stdout)
```

## Arguments

- stdout:

  Character scalar or vector captured from `sbatch` stdout.

## Value

Character scalar SLURM job ID.

## Examples

``` r
parse_sbatch_output("Submitted batch job 482910\n")
#> [1] "482910"
parse_sbatch_output("482910;hpc_prod")
#> [1] "482910"
```
