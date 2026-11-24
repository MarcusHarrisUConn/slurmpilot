# Build Safe Non-Interactive SSH Command Arguments

Constructs an argument vector suitable for `processx::run("ssh", args)`
with `BatchMode=yes`, explicit port/key handling, and safe remote
command passing.

## Usage

``` r
build_ssh_args(
  host,
  user = NULL,
  port = 22L,
  ssh_key = NULL,
  ssh_options = character(),
  remote_cmd
)
```

## Arguments

- host:

  Remote cluster hostname or IP address.

- user:

  Optional SSH username.

- port:

  SSH port integer. Default `22L`.

- ssh_key:

  Optional path to private SSH key (`-i`).

- ssh_options:

  Optional character vector of extra `ssh` options.

- remote_cmd:

  Remote shell command string to execute.

## Value

Character vector of CLI arguments for `ssh`.

## Examples

``` r
build_ssh_args("hpc.univ.edu", user = "mharris", remote_cmd = "squeue -u mharris")
#> [1] "-o"                               "BatchMode=yes"                   
#> [3] "-o"                               "StrictHostKeyChecking=accept-new"
#> [5] "-p"                               "22"                              
#> [7] "--"                               "mharris@hpc.univ.edu"            
#> [9] "squeue -u mharris"               
```
