# build_apptainer_def generates reproducible Apptainer recipes (contract + snapshot)

    Code
      cat(def_snap$text)
    Output
      Bootstrap: docker
      From: rocker/r-ver:4.4.1
      
      %labels
          GeneratedBy slurmpilot
          RVersion 4.4.1
          Toolchains cpp,cmdstan,tmb,linear_algebra
          EnvHash fixedhash001
      
      %environment
          export LC_ALL=C.UTF-8
          export LANG=C.UTF-8
          export OMP_NUM_THREADS=1
          export OPENBLAS_NUM_THREADS=1
          export MKL_NUM_THREADS=1
          export R_REMOTES_NO_ERRORS_FROM_WARNINGS=true
          export CMDSTAN=/opt/cmdstan
      
      %post
          set -eu
          export DEBIAN_FRONTEND=noninteractive
          apt-get update && apt-get install -y --no-install-recommends \
              build-essential \
              ca-certificates \
              cmake \
              curl \
              g++ \
              gfortran \
              liblapack-dev \
              libnlopt-dev \
              libopenblas-dev \
              libtbb-dev \
              make
      
          mkdir -p /root/.R
          cat <<'EOF' > /root/.R/Makevars
      CXX17 = g++
      CXX17FLAGS = -O3 -fPIC
      CXX17STD = -std=c++17
      EOF
      
          Rscript -e "install.packages(c('RTMB', 'Rcpp', 'lme4'), repos = 'https://packagemanager.posit.co/cran/__linux__/jammy/latest', Ncpus = max(1L, parallel::detectCores() - 1L))"
      
          Rscript -e "install.packages('cmdstanr', repos = c('https://stan-dev.r-universe.dev', 'https://packagemanager.posit.co/cran/__linux__/jammy/latest'))"
      
          mkdir -p /opt/cmdstan
          Rscript -e "cmdstanr::install_cmdstan(dir = '/opt/cmdstan', version = '2.35.0', cores = max(1L, parallel::detectCores() - 1L), overwrite = TRUE)"
          chmod -R a+rX /opt/cmdstan
      
          apt-get clean
          rm -rf /var/lib/apt/lists/*
      
      %test
          Rscript -e "cat('R:', R.version.string, '\n')"
          Rscript -e "stopifnot(all(vapply(c('RTMB', 'Rcpp', 'cmdstanr', 'lme4'), requireNamespace, logical(1L), quietly = TRUE)))"
          Rscript -e "cmdstanr::set_cmdstan_path('/opt/cmdstan'); cat('CmdStan:', cmdstanr::cmdstan_version(), '\n')"
      
      %runscript
          exec Rscript "$@"

# render_sbatch_script and render_worker_script satisfy contract and snapshot

    Code
      cat(sb$text)
    Output
      #!/usr/bin/env bash
      #SBATCH --job-name=dsem_sim
      #SBATCH --array=2-3,7%4
      #SBATCH --cpus-per-task=2
      #SBATCH --mem=4G
      #SBATCH --time=00:45:00
      #SBATCH --partition=general
      #SBATCH --account=quant_methods
      #SBATCH --output=/scratch/mharris/dsem_sim/logs/chunk_%a.out
      #SBATCH --error=/scratch/mharris/dsem_sim/logs/chunk_%a.err
      #SBATCH --mail-user=marcus.harris.uconn@gmail.com
      #SBATCH --mail-type=FAIL
      
      set -euo pipefail
      
      WORK_DIR='/scratch/mharris/dsem_sim'
      mkdir -p "${WORK_DIR}/logs" "${WORK_DIR}/results" "${WORK_DIR}/status"
      cd "${WORK_DIR}"
      
      # Load HPC environment modules
      module load apptainer/1.3
      
      export OMP_NUM_THREADS=2
      export OPENBLAS_NUM_THREADS=2
      export MKL_NUM_THREADS=2
      export SLURMPILOT_WORK_DIR="${WORK_DIR}"
      export SLURMPILOT_CHUNK_ID="${SLURM_ARRAY_TASK_ID}"
      export SLURMPILOT_ATTEMPT=2
      export STAN_NUM_THREADS='2'
      
      echo "[slurmpilot] Starting job ${SLURM_JOB_ID:-local} array task ${SLURM_ARRAY_TASK_ID} on $(hostname)"
      apptainer exec --cleanenv --bind '/scratch/mharris/dsem_sim:/scratch/mharris/dsem_sim' --bind '/data/readonly:/data/readonly:ro' '/scratch/containers/slurmpilot_env.sif' Rscript "${WORK_DIR}/worker.R" --work-dir "${WORK_DIR}" --chunk-id "${SLURM_ARRAY_TASK_ID}" --attempt "2"

