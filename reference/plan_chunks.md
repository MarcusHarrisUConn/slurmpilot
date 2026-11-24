# Plan Load-Balanced SLURM Array Chunk Assignments

Partitions `n_tasks` tasks across `ceiling(n_tasks / chunk_size)` SLURM
array chunks using one of three strategies:

- `"contiguous"`: sequential contiguous slices (default).

- `"round_robin"`: interleaved modulo assignment, useful when tasks are
  ordered monotonically by problem size.

- `"lpt"`: Longest Processing Time first greedy load balancing using
  `task_weights` to minimize maximum chunk runtime (makespan) when tasks
  exhibit strong heterogeneity.

## Usage

``` r
plan_chunks(
  n_tasks,
  chunk_size,
  strategy = c("contiguous", "round_robin", "lpt"),
  task_weights = NULL
)
```

## Arguments

- n_tasks:

  Positive integer total number of tasks.

- chunk_size:

  Positive integer target tasks per chunk (sets total chunk count
  `n_chunks = ceiling(n_tasks / chunk_size)`).

- strategy:

  Chunking strategy: `"contiguous"`, `"round_robin"`, or `"lpt"`.

- task_weights:

  Optional positive numeric vector of length `n_tasks` representing
  relative per-task cost or runtime (required for `"lpt"`).

## Value

A
[`tibble::tibble()`](https://tibble.tidyverse.org/reference/tibble.html)
with one row per chunk containing `chunk_id`, `start_task`, `end_task`,
`n_tasks`, `task_indices` (list-column), and `estimated_weight`.

## Examples

``` r
weights <- c(100, 90, 80, 10, 10, 10, 5, 5)
plan_chunks(8L, chunk_size = 2L, strategy = "lpt", task_weights = weights)
#> # A tibble: 4 × 6
#>   chunk_id start_task end_task n_tasks task_indices estimated_weight
#>      <int>      <int>    <int>   <int> <list>                  <dbl>
#> 1        1          1        1       1 <int [1]>                 100
#> 2        2          2        2       1 <int [1]>                  90
#> 3        3          3        3       1 <int [1]>                  80
#> 4        4          4        8       5 <int [5]>                  40
```
