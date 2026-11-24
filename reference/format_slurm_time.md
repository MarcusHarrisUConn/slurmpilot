# Format Duration in Seconds as a SLURM Time String

Converts a positive duration in seconds into SLURM's canonical
`HH:MM:SS` or `D-HH:MM:SS` walltime format.

## Usage

``` r
format_slurm_time(seconds)
```

## Arguments

- seconds:

  Numeric scalar duration in seconds (rounded up to whole seconds).

## Value

A length-1 character string formatted for SLURM `--time`.

## Examples

``` r
format_slurm_time(3665)
#> [1] "01:01:05"
format_slurm_time(90000)
#> [1] "1-01:00:00"
```
