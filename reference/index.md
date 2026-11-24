# Package index

## Micro-Pilot Profiling & Resource Sizing

Empirically profile OS RSS & runtime, size SLURM arrays, load-balance
heterogeneous workloads, audit closures, and inspect post-mortem
efficiency.

- [`pilot_run()`](https://marcusharrisphd.com/slurmpilot/reference/pilot_run.md)
  : Run an Empirical Micro-Pilot to Profile Runtime and Peak RSS Memory
- [`plot(`*`<slurmpilot_pilot>`*`)`](https://marcusharrisphd.com/slurmpilot/reference/plot.slurmpilot_pilot.md)
  : Plot a Micro-Pilot Profile
- [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md)
  : Estimate Optimal SLURM Array Resources from a Micro-Pilot
- [`resource_spec()`](https://marcusharrisphd.com/slurmpilot/reference/resource_spec.md)
  : Construct an Explicit SLURM Resource Specification
- [`scale_resources()`](https://marcusharrisphd.com/slurmpilot/reference/scale_resources.md)
  : Scale Memory and/or Walltime of a Resource Specification
- [`as_slurm_flags()`](https://marcusharrisphd.com/slurmpilot/reference/as_slurm_flags.md)
  : Convert a Resource Specification into SLURM CLI Flags
- [`plan_chunks()`](https://marcusharrisphd.com/slurmpilot/reference/plan_chunks.md)
  : Plan Load-Balanced SLURM Array Chunk Assignments
- [`inspect_job_globals()`](https://marcusharrisphd.com/slurmpilot/reference/inspect_job_globals.md)
  : Inspect Worker Function Closures, Globals, and Serialization Bundle
  Size
- [`slurm_efficiency_report()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_efficiency_report.md)
  : Audit Post-Mortem SLURM Memory, Walltime, and Load-Balance
  Efficiency
- [`plot(`*`<slurmpilot_efficiency>`*`)`](https://marcusharrisphd.com/slurmpilot/reference/plot.slurmpilot_efficiency.md)
  : Plot a Post-Mortem SLURM Resource Efficiency Report

## Multi-Stage Pipelines & Job Lifecycle

User-facing S3 workflow API for single-stage jobs, autopilot runs, and
multi-stage dependent HPC DAGs.

- [`slurm_autopilot()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_autopilot.md)
  : End-to-End Micro-Pilot to Cluster Autopilot

- [`slurm_job_spec()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_job_spec.md)
  : Construct a SLURM Array Job Specification

- [`slurm_submit()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_submit.md)
  :

  Submit a Job to a `slurmpilot` Scheduler Backend

- [`slurm_status()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_status.md)
  : Poll Current Status of a Submitted Job

- [`slurm_wait()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_wait.md)
  : Wait for a Job to Reach a Terminal State

- [`slurm_retry()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_retry.md)
  : Surgically Retry Failed, OOM, Timed-Out, or Cancelled Chunks

- [`slurm_retry_history()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_retry_history.md)
  : Retrieve Per-Chunk Surgical Retry Provenance for a Job

- [`slurm_cancel()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_cancel.md)
  : Cancel Active Chunks of a Submitted Job

- [`slurm_logs()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_logs.md)
  : Retrieve Stdout and Stderr Logs for a Submitted Job

- [`slurm_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_collect.md)
  : Collect Ordered Task Results from a Completed Job

- [`slurm_stage()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_stage.md)
  : Define a Stage in a Multi-Stage SLURM Pipeline DAG

- [`slurm_pipeline()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline.md)
  : Construct a Validated Multi-Stage SLURM Pipeline DAG

- [`slurm_pipeline_run()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_run.md)
  : Execute a Multi-Stage SLURM Pipeline DAG

- [`slurm_pipeline_status()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_status.md)
  : Inspect Status Across All Stages of a SLURM Pipeline Run

- [`slurm_pipeline_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_pipeline_collect.md)
  : Collect Results from a Completed SLURM Pipeline Run

## Scheduler Backends

Pluggable R6 scheduler interface with a local parallel mock SLURM
simulator and production SSH/SLURM adapter.

- [`SlurmBackend`](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.md)
  :

  Abstract Base Class for `slurmpilot` Scheduler Backends

- [`MockSlurmBackend`](https://marcusharrisphd.com/slurmpilot/reference/MockSlurmBackend.md)
  : Local Parallel Mock SLURM Scheduler Backend

- [`mock_slurm_backend()`](https://marcusharrisphd.com/slurmpilot/reference/mock_slurm_backend.md)
  : Create a Local Parallel Mock SLURM Backend

- [`SlurmSshBackend`](https://marcusharrisphd.com/slurmpilot/reference/SlurmSshBackend.md)
  : Production SSH/SLURM Scheduler Backend

- [`slurm_ssh_backend()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_ssh_backend.md)
  : Create an SSH/SLURM Scheduler Backend

## HPC Environment, Apptainer & Container Handoff

Scan dependencies, detect compiled toolchains, emit reproducible
Apptainer .def recipes and sbatch scripts, and attach rcapsule
containers.

- [`scan_project_env()`](https://marcusharrisphd.com/slurmpilot/reference/scan_project_env.md)
  : Scan an R Project for Package Dependencies and Compiled HPC
  Toolchains

- [`toolchain_registry()`](https://marcusharrisphd.com/slurmpilot/reference/toolchain_registry.md)
  : Built-In Compiled Toolchain and System Dependency Registry

- [`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md)
  :

  Build a Reproducible Apptainer/Singularity `.def` Recipe

- [`use_rcapsule_container()`](https://marcusharrisphd.com/slurmpilot/reference/use_rcapsule_container.md)
  :

  Attach a Validated Apptainer or `rcapsule` Container to a SLURM Job
  Spec

- [`render_sbatch_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_sbatch_script.md)
  :

  Render a Self-Contained SLURM `sbatch` Array Submission Script

- [`render_worker_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_worker_script.md)
  : Generate the Standalone Base-R Cluster Worker Script

## Non-Blocking Shiny Offload Modules

Drop-in bslib/Shiny UI and server modules plus the bundled interactive
Monte Carlo demo studio.

- [`mod_hpc_submit_ui()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_submit_ui.md)
  : Shiny UI Module for Micro-Pilot Auto-Sizing and HPC Job Submission

- [`mod_hpc_submit_server()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_submit_server.md)
  : Shiny Server Module for Non-Blocking Micro-Pilot and HPC Submission

- [`mod_hpc_monitor_ui()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_monitor_ui.md)
  : Shiny UI Module for Live Cluster Telemetry and Surgical Job Recovery

- [`mod_hpc_monitor_server()`](https://marcusharrisphd.com/slurmpilot/reference/mod_hpc_monitor_server.md)
  : Shiny Server Module for Non-Blocking Cluster Monitoring and Recovery

- [`run_demo_app()`](https://marcusharrisphd.com/slurmpilot/reference/run_demo_app.md)
  :

  Launch the Bundled Non-Blocking `slurmpilot` Demo Shiny App

## Security, Reproducibility & SLURM Parsers

Checkpoint SHA-256 verification, independent L’Ecuyer-CMRG parallel RNG
streams, SSH/SCP builders, and SLURM output parsers.

- [`verify_checkpoint()`](https://marcusharrisphd.com/slurmpilot/reference/verify_checkpoint.md)
  : Verify SHA-256 Checksum and Readability of a Chunk Checkpoint

- [`slurmpilot_rng_stream()`](https://marcusharrisphd.com/slurmpilot/reference/slurmpilot_rng_stream.md)
  :

  Derive an Independent `L'Ecuyer-CMRG` Parallel RNG Stream

- [`build_ssh_args()`](https://marcusharrisphd.com/slurmpilot/reference/build_ssh_args.md)
  : Build Safe Non-Interactive SSH Command Arguments

- [`build_scp_args()`](https://marcusharrisphd.com/slurmpilot/reference/build_scp_args.md)
  : Build Safe Non-Interactive SCP Command Arguments

- [`build_scancel_command()`](https://marcusharrisphd.com/slurmpilot/reference/build_scancel_command.md)
  :

  Build a SLURM `scancel` Command String

- [`parse_sbatch_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_sbatch_output.md)
  :

  Parse SLURM `sbatch` Output to Extract Job ID

- [`parse_squeue_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_squeue_output.md)
  :

  Parse Pipe-Delimited SLURM `squeue` Output

- [`parse_sacct_output()`](https://marcusharrisphd.com/slurmpilot/reference/parse_sacct_output.md)
  :

  Parse Pipe-Delimited SLURM `sacct` Accounting Output

- [`format_slurm_time()`](https://marcusharrisphd.com/slurmpilot/reference/format_slurm_time.md)
  : Format Duration in Seconds as a SLURM Time String

- [`parse_slurm_time()`](https://marcusharrisphd.com/slurmpilot/reference/parse_slurm_time.md)
  : Parse a SLURM Time String to Seconds

- [`format_slurm_mem()`](https://marcusharrisphd.com/slurmpilot/reference/format_slurm_mem.md)
  :

  Format Memory in Megabytes as a SLURM `--mem` String

- [`parse_slurm_mem()`](https://marcusharrisphd.com/slurmpilot/reference/parse_slurm_mem.md)
  : Parse a SLURM Memory String to Megabytes

- [`format_slurm_array_indices()`](https://marcusharrisphd.com/slurmpilot/reference/format_slurm_array_indices.md)
  :

  Format Integer Array Indices into Compact SLURM `--array` Notation

- [`parse_slurm_array_spec()`](https://marcusharrisphd.com/slurmpilot/reference/parse_slurm_array_spec.md)
  : Parse a SLURM Array Expression into Expanded Integer Indices

## Package Overview

- [`slurmpilot`](https://marcusharrisphd.com/slurmpilot/reference/slurmpilot-package.md)
  [`slurmpilot-package`](https://marcusharrisphd.com/slurmpilot/reference/slurmpilot-package.md)
  : slurmpilot: Auto-Profiling 'SLURM' HPC Orchestration and 'Shiny'
  Offloading
