# Derive an Independent `L'Ecuyer-CMRG` Parallel RNG Stream

Computes the deterministic 7-integer `L'Ecuyer-CMRG` `.Random.seed`
vector for a given `(seed, chunk_id, task_pos)` tuple using base
[`parallel::nextRNGStream()`](https://rdrr.io/r/parallel/RngStream.html)
(spacing chunks \\2^{127}\\ draws apart) and
[`parallel::nextRNGSubStream()`](https://rdrr.io/r/parallel/RngStream.html)
(spacing tasks within a chunk \\2^{76}\\ draws apart). Restores the
caller's `.Random.seed` and
[`RNGkind()`](https://rdrr.io/r/base/Random.html) on exit so calling
this function has zero global RNG side effects.

## Usage

``` r
slurmpilot_rng_stream(seed, chunk_id = 1L, task_pos = 1L)
```

## Arguments

- seed:

  Integer master seed.

- chunk_id:

  Positive integer array chunk index. Default `1L`.

- task_pos:

  Positive integer 1-based task position within the chunk. Default `1L`.

## Value

An integer vector of length 7 representing a valid `L'Ecuyer-CMRG`
`.Random.seed` state.

## Examples

``` r
s1 <- slurmpilot_rng_stream(42L, chunk_id = 1L, task_pos = 1L)
s2 <- slurmpilot_rng_stream(42L, chunk_id = 2L, task_pos = 1L)
!identical(s1, s2)
#> [1] TRUE
```
