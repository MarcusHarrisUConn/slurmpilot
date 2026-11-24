# Build Safe Non-Interactive SCP Command Arguments

Constructs an argument vector suitable for `processx::run("scp", args)`
to stage local job bundles to a SLURM cluster or retrieve remote
checkpoint artifacts.

## Usage

``` r
build_scp_args(
  src,
  dest,
  port = 22L,
  ssh_key = NULL,
  ssh_options = character(),
  recursive = FALSE
)
```

## Arguments

- src:

  Character vector of one or more source paths.

- dest:

  Character scalar destination path.

- port:

  SSH port integer (`-P`). Default `22L`.

- ssh_key:

  Optional path to private SSH key (`-i`).

- ssh_options:

  Optional character vector of extra SSH/SCP options.

- recursive:

  Logical; pass `-r` for recursive directory copy.

## Value

Character vector of CLI arguments for `scp`.

## Examples

``` r
build_scp_args("submit.sbatch", "mharris@hpc.univ.edu:/scratch/job1/")
#> [1] "-o"                                  "BatchMode=yes"                      
#> [3] "-o"                                  "StrictHostKeyChecking=accept-new"   
#> [5] "-P"                                  "22"                                 
#> [7] "--"                                  "submit.sbatch"                      
#> [9] "mharris@hpc.univ.edu:/scratch/job1/"
```
