# Real SSH/SLURM scheduler backend + pure command builders & output parsers

#' Build Safe Non-Interactive SSH Command Arguments
#'
#' Constructs an argument vector suitable for `processx::run("ssh", args)` with
#' `BatchMode=yes`, explicit port/key handling, and safe remote command passing.
#'
#' @param host Remote cluster hostname or IP address.
#' @param user Optional SSH username.
#' @param port SSH port integer. Default `22L`.
#' @param ssh_key Optional path to private SSH key (`-i`).
#' @param ssh_options Optional character vector of extra `ssh` options.
#' @param remote_cmd Remote shell command string to execute.
#'
#' @return Character vector of CLI arguments for `ssh`.
#' @export
#' @examples
#' build_ssh_args("hpc.univ.edu", user = "mharris", remote_cmd = "squeue -u mharris")
build_ssh_args <- function(
  host,
  user = NULL,
  port = 22L,
  ssh_key = NULL,
  ssh_options = character(),
  remote_cmd
) {
  checkmate::assert_string(host, min.chars = 1L)
  if (!is.null(user)) checkmate::assert_string(user, min.chars = 1L)
  checkmate::assert_int(port, lower = 1L, upper = 65535L)
  if (!is.null(ssh_key)) checkmate::assert_string(ssh_key, min.chars = 1L)
  checkmate::assert_character(ssh_options, any.missing = FALSE)
  checkmate::assert_string(remote_cmd, min.chars = 1L)

  target <- if (!is.null(user)) paste0(user, "@", host) else host
  args <- c(
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=accept-new",
    "-p", as.character(port)
  )
  if (!is.null(ssh_key)) {
    args <- c(args, "-i", ssh_key)
  }
  if (length(ssh_options) > 0L) {
    args <- c(args, ssh_options)
  }
  c(args, target, remote_cmd)
}

#' Build Safe Non-Interactive SCP Command Arguments
#'
#' Constructs an argument vector suitable for `processx::run("scp", args)` to
#' stage local job bundles to a SLURM cluster or retrieve remote checkpoint
#' artifacts.
#'
#' @param src Character vector of one or more source paths.
#' @param dest Character scalar destination path.
#' @param port SSH port integer (`-P`). Default `22L`.
#' @param ssh_key Optional path to private SSH key (`-i`).
#' @param ssh_options Optional character vector of extra SSH/SCP options.
#' @param recursive Logical; pass `-r` for recursive directory copy.
#'
#' @return Character vector of CLI arguments for `scp`.
#' @export
#' @examples
#' build_scp_args("submit.sbatch", "mharris@hpc.univ.edu:/scratch/job1/")
build_scp_args <- function(
  src,
  dest,
  port = 22L,
  ssh_key = NULL,
  ssh_options = character(),
  recursive = FALSE
) {
  checkmate::assert_character(src, min.len = 1L, any.missing = FALSE)
  checkmate::assert_string(dest, min.chars = 1L)
  checkmate::assert_int(port, lower = 1L, upper = 65535L)
  if (!is.null(ssh_key)) checkmate::assert_string(ssh_key, min.chars = 1L)
  checkmate::assert_character(ssh_options, any.missing = FALSE)
  checkmate::assert_flag(recursive)

  args <- c(
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=accept-new",
    "-P", as.character(port)
  )
  if (isTRUE(recursive)) {
    args <- c(args, "-r")
  }
  if (!is.null(ssh_key)) {
    args <- c(args, "-i", ssh_key)
  }
  if (length(ssh_options) > 0L) {
    args <- c(args, ssh_options)
  }
  c(args, src, dest)
}

#' Parse SLURM `sbatch` Output to Extract Job ID
#'
#' Parses both standard (`"Submitted batch job 123456"`) and `--parsable`
#' (`"123456"` or `"123456;cluster_name"`) output from `sbatch`.
#'
#' @param stdout Character scalar or vector captured from `sbatch` stdout.
#'
#' @return Character scalar SLURM job ID.
#' @export
#' @examples
#' parse_sbatch_output("Submitted batch job 482910\n")
#' parse_sbatch_output("482910;hpc_prod")
parse_sbatch_output <- function(stdout) {
  txt <- trimws(paste(as.character(stdout), collapse = "\n"))
  if (!nzchar(txt)) {
    cli::cli_abort("Empty stdout from {.code sbatch}; could not parse SLURM job ID.")
  }
  # Match "Submitted batch job 123456"
  m_std <- regexec("Submitted batch job\\s+([0-9]+)", txt)
  hit_std <- regmatches(txt, m_std)[[1L]]
  if (length(hit_std) == 2L) {
    return(hit_std[[2L]])
  }
  # Match --parsable output "123456" or "123456;cluster"
  lines <- trimws(strsplit(txt, "\n", fixed = TRUE)[[1L]])
  lines <- lines[nzchar(lines)]
  last_line <- lines[[length(lines)]]
  m_parse <- regexec("^([0-9]+)(?:;.*)?$", last_line)
  hit_parse <- regmatches(last_line, m_parse)[[1L]]
  if (length(hit_parse) == 2L) {
    return(hit_parse[[2L]])
  }
  cli::cli_abort("Unable to parse SLURM job ID from {.code sbatch} output: {.val {txt}}")
}

#' Parse Pipe-Delimited SLURM `squeue` Output
#'
#' Parses `squeue -h -o "%i|%T|%M|%N|%r"` output into a tidy tibble, expanding
#' compressed array task ranges (such as `12345_[3-6,9]`) into individual chunk
#' rows with normalized SLURM states.
#'
#' @param stdout Character scalar or vector captured from `squeue`.
#'
#' @return A [tibble::tibble()] with columns `slurm_job_id`, `chunk_id`,
#'   `state`, `elapsed_sec`, `node`, and `reason`.
#' @export
#' @examples
#' parse_squeue_output("12345_1|RUNNING|02:15|node01|None\n12345_[2-4]|PENDING|0:00||(Priority)")
parse_squeue_output <- function(stdout) {
  empty <- tibble::tibble(
    slurm_job_id = character(),
    chunk_id = integer(),
    state = character(),
    elapsed_sec = numeric(),
    node = character(),
    reason = character()
  )
  txt <- paste(as.character(stdout), collapse = "\n")
  lines <- trimws(strsplit(txt, "\n", fixed = TRUE)[[1L]])
  lines <- lines[nzchar(lines)]
  if (length(lines) == 0L) {
    return(empty)
  }

  rows <- list()
  for (ln in lines) {
    fields <- strsplit(ln, "|", fixed = TRUE)[[1L]]
    if (length(fields) < 2L) next
    raw_id <- trimws(fields[[1L]])
    state <- sp_normalize_slurm_state(fields[[2L]])
    elapsed_sec <- if (length(fields) >= 3L) parse_slurm_time(fields[[3L]]) else NA_real_
    node <- if (length(fields) >= 4L && nzchar(trimws(fields[[4L]]))) trimws(fields[[4L]]) else NA_character_
    reason <- if (length(fields) >= 5L && nzchar(trimws(fields[[5L]]))) trimws(fields[[5L]]) else NA_character_

    if (grepl("_", raw_id, fixed = TRUE)) {
      parts <- strsplit(raw_id, "_", fixed = TRUE)[[1L]]
      base_id <- parts[[1L]]
      cids <- sp_expand_slurm_array_expr(parts[[2L]])
    } else {
      base_id <- raw_id
      cids <- 1L
    }

    for (cid in cids) {
      rows[[length(rows) + 1L]] <- tibble::tibble(
        slurm_job_id = base_id,
        chunk_id = as.integer(cid),
        state = state,
        elapsed_sec = elapsed_sec,
        node = node,
        reason = reason
      )
    }
  }

  if (length(rows) == 0L) return(empty)
  do.call(rbind, rows)
}

#' Parse Pipe-Delimited SLURM `sacct` Accounting Output
#'
#' Parses `sacct -n -P --format=JobID,State,Elapsed,MaxRSS,ExitCode` output into
#' a tidy per-chunk tibble. Automatically consolidates `.batch` sub-step
#' `MaxRSS` onto the parent array task row (e.g. `12345_2.batch` merged into
#' `12345_2`) and ignores `.extern` overhead steps.
#'
#' @param stdout Character scalar or vector captured from `sacct`.
#'
#' @return A [tibble::tibble()] with columns `slurm_job_id`, `chunk_id`,
#'   `state`, `elapsed_sec`, `peak_rss_mb`, and `exit_code`.
#' @export
#' @examples
#' sample_out <- paste(
#'   "12345_1|COMPLETED|00:04:12||0:0",
#'   "12345_1.batch|COMPLETED|00:04:12|512000K|0:0",
#'   "12345_2|OUT_OF_MEMORY|00:01:05||0:125",
#'   sep = "\n"
#' )
#' parse_sacct_output(sample_out)
parse_sacct_output <- function(stdout) {
  empty <- tibble::tibble(
    slurm_job_id = character(),
    chunk_id = integer(),
    state = character(),
    elapsed_sec = numeric(),
    peak_rss_mb = numeric(),
    exit_code = integer()
  )
  txt <- paste(as.character(stdout), collapse = "\n")
  lines <- trimws(strsplit(txt, "\n", fixed = TRUE)[[1L]])
  lines <- lines[nzchar(lines)]
  if (length(lines) == 0L) {
    return(empty)
  }

  records <- list()
  for (ln in lines) {
    fields <- strsplit(ln, "|", fixed = TRUE)[[1L]]
    if (length(fields) < 2L) next
    raw_id <- trimws(fields[[1L]])
    if (!nzchar(raw_id)) next

    # Skip .extern steps
    if (grepl("\\.extern$", raw_id)) next

    is_batch <- grepl("\\.batch$", raw_id)
    clean_id <- sub("\\..*$", "", raw_id)

    # Ignore unexpanded array meta-rows like 12345_[1-4] in sacct
    if (grepl("\\[", clean_id)) next

    if (grepl("_", clean_id, fixed = TRUE)) {
      parts <- strsplit(clean_id, "_", fixed = TRUE)[[1L]]
      base_id <- parts[[1L]]
      cid <- suppressWarnings(as.integer(parts[[2L]]))
      if (is.na(cid)) next
    } else {
      base_id <- clean_id
      cid <- 1L
    }

    state <- sp_normalize_slurm_state(fields[[2L]])
    elapsed_sec <- if (length(fields) >= 3L) parse_slurm_time(fields[[3L]]) else NA_real_
    rss_mb <- if (length(fields) >= 4L) parse_slurm_mem(fields[[4L]]) else NA_real_
    exit_code <- NA_integer_
    if (length(fields) >= 5L && nzchar(trimws(fields[[5L]]))) {
      ec_parts <- strsplit(trimws(fields[[5L]]), ":", fixed = TRUE)[[1L]]
      exit_code <- suppressWarnings(as.integer(ec_parts[[1L]]))
    }

    key <- paste0(base_id, "_", cid)
    if (is.null(records[[key]])) {
      records[[key]] <- list(
        slurm_job_id = base_id,
        chunk_id = cid,
        state = state,
        elapsed_sec = elapsed_sec,
        peak_rss_mb = rss_mb,
        exit_code = exit_code
      )
    } else {
      cur <- records[[key]]
      if (is_batch) {
        if (!is.na(rss_mb)) {
          cur$peak_rss_mb <- if (is.na(cur$peak_rss_mb)) rss_mb else max(cur$peak_rss_mb, rss_mb)
        }
        if (is.na(cur$elapsed_sec) && !is.na(elapsed_sec)) {
          cur$elapsed_sec <- elapsed_sec
        }
      } else {
        cur$state <- state
        if (!is.na(elapsed_sec)) cur$elapsed_sec <- elapsed_sec
        if (!is.na(rss_mb)) {
          cur$peak_rss_mb <- if (is.na(cur$peak_rss_mb)) rss_mb else max(cur$peak_rss_mb, rss_mb)
        }
        if (!is.na(exit_code)) cur$exit_code <- exit_code
      }
      records[[key]] <- cur
    }
  }

  if (length(records) == 0L) return(empty)
  rows <- lapply(records, function(r) {
    tibble::tibble(
      slurm_job_id = r$slurm_job_id,
      chunk_id = as.integer(r$chunk_id),
      state = r$state,
      elapsed_sec = as.numeric(r$elapsed_sec),
      peak_rss_mb = as.numeric(r$peak_rss_mb),
      exit_code = as.integer(r$exit_code)
    )
  })
  out <- do.call(rbind, rows)
  out[order(out$slurm_job_id, out$chunk_id), , drop = FALSE]
}

#' Build a SLURM `scancel` Command String
#'
#' Constructs a `scancel` command targeting either an entire SLURM job or
#' specific array task indices (`<job_id>_<chunk_id>`).
#'
#' @param slurm_job_id Character or integer SLURM job ID.
#' @param chunks Optional integer vector of specific array task indices to
#'   cancel.
#'
#' @return Character scalar `scancel` command.
#' @export
#' @examples
#' build_scancel_command("482910")
#' build_scancel_command("482910", chunks = c(2, 5))
build_scancel_command <- function(slurm_job_id, chunks = NULL) {
  jid <- as.character(slurm_job_id)
  checkmate::assert_string(jid, min.chars = 1L)
  if (is.null(chunks)) {
    return(paste("scancel", jid))
  }
  checkmate::assert_integerish(chunks, lower = 1L, min.len = 1L)
  targets <- paste0(jid, "_", sort(unique(as.integer(chunks))))
  paste("scancel", paste(targets, collapse = " "))
}

#' Production SSH/SLURM Scheduler Backend
#'
#' Orchestrates remote SLURM array jobs over SSH/SCP with zero dependency on
#' ZeroMQ or open worker ports. Stages self-contained bundles (`payload.rds`,
#' `chunks.rds`, standalone `worker.R`, and `submit.sbatch`), submits array jobs
#' with `sbatch --parsable`, reconciles live `squeue` and `sacct` telemetry,
#' performs surgical retries of failed array indices with optional `--mem` /
#' `--time` scaling, and retrieves completed checkpoints via `scp`.
#'
#' Accepts an injectable `command_runner` callback (defaulting to
#' `processx::run`) and `dry_run = TRUE` mode so every SSH/SLURM workflow can be
#' verified offline in contract and snapshot tests.
#'
#' @export
SlurmSshBackend <- R6::R6Class(
  classname = "SlurmSshBackend",
  inherit = SlurmBackend,
  public = list(
    #' @field name Backend identifier (`"slurm_ssh"`).
    name = "slurm_ssh",
    #' @field host Remote SLURM login node hostname.
    host = NULL,
    #' @field user Optional SSH username.
    user = NULL,
    #' @field remote_dir Base directory on the remote cluster for job workspaces.
    remote_dir = NULL,
    #' @field local_stage_dir Local staging directory for job bundles and retrieved artifacts.
    local_stage_dir = NULL,
    #' @field port SSH port (default `22L`).
    port = 22L,
    #' @field ssh_key Optional SSH private key path.
    ssh_key = NULL,
    #' @field ssh_options Optional extra SSH/SCP flags.
    ssh_options = character(),
    #' @field partition Optional default SLURM partition.
    partition = NULL,
    #' @field account Optional default SLURM account.
    account = NULL,
    #' @field qos Optional default SLURM QOS.
    qos = NULL,
    #' @field container_sif Optional default remote Apptainer `.sif` path.
    container_sif = NULL,
    #' @field container_binds Optional Apptainer `--bind` mounts.
    container_binds = character(),
    #' @field modules Optional HPC environment modules loaded in `sbatch`.
    modules = character(),
    #' @field dry_run Logical; if `TRUE`, stages bundles locally and records commands without executing SSH/SCP.
    dry_run = FALSE,
    #' @field command_runner Function `(cmd, args)` returning `list(status, stdout, stderr)`.
    command_runner = NULL,

    #' @description Create a new `SlurmSshBackend`.
    #' @param host Remote SLURM cluster hostname.
    #' @param user Optional SSH username.
    #' @param remote_dir Base remote workspace directory. Default `"~/slurmpilot_jobs"`.
    #' @param local_stage_dir Local staging directory. Defaults to a temporary directory.
    #' @param port SSH port integer. Default `22L`.
    #' @param ssh_key Optional private SSH key path.
    #' @param ssh_options Optional extra SSH options.
    #' @param partition Optional default SLURM `--partition`.
    #' @param account Optional default SLURM `--account`.
    #' @param qos Optional default SLURM `--qos`.
    #' @param container_sif Optional remote path to Apptainer `.sif` image.
    #' @param container_binds Optional character vector of Apptainer bind mounts.
    #' @param modules Optional character vector of HPC modules to load.
    #' @param dry_run Logical; record commands without making network calls. Default `FALSE`.
    #' @param command_runner Optional runner `function(cmd, args)` overriding `processx::run`.
    initialize = function(
      host,
      user = NULL,
      remote_dir = "~/slurmpilot_jobs",
      local_stage_dir = NULL,
      port = 22L,
      ssh_key = NULL,
      ssh_options = character(),
      partition = NULL,
      account = NULL,
      qos = NULL,
      container_sif = NULL,
      container_binds = character(),
      modules = character(),
      dry_run = FALSE,
      command_runner = NULL
    ) {
      checkmate::assert_string(host, min.chars = 1L)
      if (!is.null(user)) checkmate::assert_string(user, min.chars = 1L)
      checkmate::assert_string(remote_dir, min.chars = 1L)
      checkmate::assert_int(port, lower = 1L, upper = 65535L)
      if (!is.null(ssh_key)) checkmate::assert_string(ssh_key, min.chars = 1L)
      checkmate::assert_character(ssh_options, any.missing = FALSE)
      if (!is.null(partition)) checkmate::assert_string(partition, min.chars = 1L)
      if (!is.null(account)) checkmate::assert_string(account, min.chars = 1L)
      if (!is.null(qos)) checkmate::assert_string(qos, min.chars = 1L)
      if (!is.null(container_sif)) checkmate::assert_string(container_sif, min.chars = 1L)
      checkmate::assert_character(container_binds, any.missing = FALSE)
      checkmate::assert_character(modules, any.missing = FALSE)
      checkmate::assert_flag(dry_run)
      if (!is.null(command_runner)) checkmate::assert_function(command_runner)

      self$host <- host
      self$user <- user
      self$remote_dir <- sub("/+$", "", remote_dir)
      if (is.null(local_stage_dir)) {
        local_stage_dir <- tempfile("slurmpilot_ssh_")
      }
      dir.create(local_stage_dir, recursive = TRUE, showWarnings = FALSE)
      self$local_stage_dir <- normalizePath(local_stage_dir, winslash = "/", mustWork = FALSE)
      self$port <- as.integer(port)
      self$ssh_key <- ssh_key
      self$ssh_options <- ssh_options
      self$partition <- partition
      self$account <- account
      self$qos <- qos
      self$container_sif <- container_sif
      self$container_binds <- container_binds
      self$modules <- modules
      self$dry_run <- dry_run
      self$command_runner <- command_runner %||% function(cmd, args) {
        processx::run(command = cmd, args = args, error_on_status = FALSE)
      }
      invisible(self)
    },

    #' @description Stage and submit a SLURM array job over SSH/SCP.
    #' @param job_spec A `slurmpilot_job_spec` object.
    #' @param ... Unused.
    #' @return A `slurmpilot_job` handle.
    submit = function(job_spec, ...) {
      checkmate::assert_class(job_spec, "slurmpilot_job_spec")

      # Apply backend defaults for partition/account/qos if unset on resources
      res <- job_spec$resources
      if (is.null(res$partition) && !is.null(self$partition)) res$partition <- self$partition
      if (is.null(res$account) && !is.null(self$account)) res$account <- self$account
      if (is.null(res$qos) && !is.null(self$qos)) res$qos <- self$qos
      res$slurm_flags <- as_slurm_flags(res)
      job_spec$resources <- res

      job_id <- sp_generate_id("slurm")
      local_job_dir <- file.path(self$local_stage_dir, job_id)
      remote_job_dir <- paste0(self$remote_dir, "/", job_id)

      staged <- sp_stage_job_bundle(
        local_job_dir = local_job_dir,
        job_spec = job_spec,
        sbatch_work_dir = remote_job_dir,
        container_sif = self$container_sif,
        container_binds = self$container_binds,
        modules = self$modules
      )

      mkdir_cmd <- sprintf(
        "mkdir -p %s %s %s",
        sp_sh_quote(paste0(remote_job_dir, "/logs")),
        sp_sh_quote(paste0(remote_job_dir, "/results")),
        sp_sh_quote(paste0(remote_job_dir, "/status"))
      )
      stage_files <- c(
        staged$payload_path,
        staged$chunks_rds_path,
        staged$chunks_json_path,
        staged$worker_path,
        staged$sbatch_path
      )
      sbatch_cmd <- sprintf("sbatch --parsable %s", sp_sh_quote(paste0(remote_job_dir, "/submit.sbatch")))

      if (isTRUE(self$dry_run)) {
        dry_cmds <- list(
          mkdir = list(cmd = "ssh", args = private$ssh_args(mkdir_cmd)),
          scp = list(cmd = "scp", args = private$scp_args(stage_files, paste0(private$target(), ":", remote_job_dir, "/"))),
          sbatch = list(cmd = "ssh", args = private$ssh_args(sbatch_cmd))
        )
        slurm_id <- "DRY_RUN"
      } else {
        private$exec_ssh(mkdir_cmd)
        private$exec_scp(stage_files, paste0(private$target(), ":", remote_job_dir, "/"))
        sb_res <- private$exec_ssh(sbatch_cmd)
        slurm_id <- parse_sbatch_output(sb_res$stdout)
        dry_cmds <- NULL
      }

      n_chunks <- res$n_chunks
      chunk_map <- tibble::tibble(
        chunk_id = seq_len(n_chunks),
        n_tasks = res$chunks$n_tasks,
        slurm_job_id = rep(slurm_id, n_chunks),
        attempt = rep(1L, n_chunks)
      )

      private$jobs[[job_id]] <- list(
        job_id = job_id,
        job_name = job_spec$name,
        local_dir = local_job_dir,
        remote_dir = remote_job_dir,
        resources = res,
        job_spec = job_spec,
        slurm_ids = slurm_id,
        chunk_map = chunk_map,
        dry_run_commands = dry_cmds
      )

      job <- new_slurmpilot_job(
        job_id = job_id,
        job_name = job_spec$name,
        backend = self,
        resources = res,
        local_dir = local_job_dir,
        remote_dir = remote_job_dir,
        scheduler_ids = slurm_id,
        spec = job_spec,
        meta = list(dry_run_commands = dry_cmds)
      )
      job
    },

    #' @description Query `squeue` and `sacct` over SSH and reconcile chunk states.
    #' @param job A `slurmpilot_job` handle.
    #' @return A `slurmpilot_status` object.
    status = function(job) {
      checkmate::assert_class(job, "slurmpilot_job")
      rec <- private$get_job_record(job$job_id)

      if (isTRUE(self$dry_run)) {
        cm <- rec$chunk_map
        chunks_tbl <- tibble::tibble(
          chunk_id = cm$chunk_id,
          n_tasks = cm$n_tasks,
          state = rep("PENDING", nrow(cm)),
          attempt = cm$attempt,
          worker_id = paste0(cm$slurm_job_id, "_", cm$chunk_id),
          started_at = NA_character_,
          finished_at = NA_character_,
          wall_sec = NA_real_,
          peak_rss_mb = NA_real_,
          exit_code = NA_integer_,
          error_message = NA_character_,
          checkpoint_exists = FALSE
        )
        return(sp_build_status(rec$job_id, rec$job_name, self$name, chunks_tbl))
      }

      id_csv <- paste(unique(rec$slurm_ids), collapse = ",")
      sq_cmd <- sprintf("squeue -j %s -h -o '%%i|%%T|%%M|%%N|%%r'", id_csv)
      sa_cmd <- sprintf("sacct -j %s -n -P --format=JobID,State,Elapsed,MaxRSS,ExitCode", id_csv)

      sq_res <- private$exec_ssh(sq_cmd, allow_error = TRUE)
      sa_res <- private$exec_ssh(sa_cmd, allow_error = TRUE)

      sq_tbl <- if (identical(sq_res$status, 0L)) parse_squeue_output(sq_res$stdout) else parse_squeue_output("")
      sa_tbl <- if (identical(sa_res$status, 0L)) parse_sacct_output(sa_res$stdout) else parse_sacct_output("")

      cm <- rec$chunk_map
      rows <- lapply(seq_len(nrow(cm)), function(i) {
        cid <- cm$chunk_id[[i]]
        sjid <- cm$slurm_job_id[[i]]

        sq_hit <- sq_tbl[sq_tbl$slurm_job_id == sjid & sq_tbl$chunk_id == cid, , drop = FALSE]
        sa_hit <- sa_tbl[sa_tbl$slurm_job_id == sjid & sa_tbl$chunk_id == cid, , drop = FALSE]

        state <- "PENDING"
        wall_sec <- NA_real_
        peak_rss <- NA_real_
        exit_code <- NA_integer_
        err_msg <- NA_character_

        if (nrow(sq_hit) > 0L) {
          state <- sq_hit$state[[1L]]
          wall_sec <- sq_hit$elapsed_sec[[1L]]
          if (!is.na(sq_hit$reason[[1L]]) && !(sq_hit$reason[[1L]] %in% c("None", ""))) {
            err_msg <- sq_hit$reason[[1L]]
          }
        } else if (nrow(sa_hit) > 0L) {
          state <- sa_hit$state[[1L]]
          wall_sec <- sa_hit$elapsed_sec[[1L]]
          peak_rss <- sa_hit$peak_rss_mb[[1L]]
          exit_code <- sa_hit$exit_code[[1L]]
          if (state %in% sp_retryable_states()) {
            err_msg <- sprintf("SLURM state %s (exit %s)", state, if (is.na(exit_code)) "?" else exit_code)
          }
        }

        tibble::tibble(
          chunk_id = as.integer(cid),
          n_tasks = as.integer(cm$n_tasks[[i]]),
          state = state,
          attempt = as.integer(cm$attempt[[i]]),
          worker_id = paste0(sjid, "_", cid),
          started_at = NA_character_,
          finished_at = NA_character_,
          wall_sec = wall_sec,
          peak_rss_mb = peak_rss,
          exit_code = exit_code,
          error_message = err_msg,
          checkpoint_exists = (state == "COMPLETED")
        )
      })

      chunks_tbl <- do.call(rbind, rows)
      sp_build_status(
        job_id = rec$job_id,
        job_name = rec$job_name,
        backend_name = self$name,
        chunks_tbl = chunks_tbl,
        extra = list(slurm_ids = rec$slurm_ids)
      )
    },

    #' @description Surgically resubmit only failed/OOM/timeout/cancelled array indices.
    #' @param job A `slurmpilot_job` handle.
    #' @param chunks Optional integer vector of array indices to retry.
    #' @param resources Optional updated `slurmpilot_resources` spec.
    #' @return Updated `slurmpilot_job` handle.
    retry = function(job, chunks = NULL, resources = NULL) {
      checkmate::assert_class(job, "slurmpilot_job")
      rec <- private$get_job_record(job$job_id)

      if (!is.null(resources)) {
        checkmate::assert_class(resources, "slurmpilot_resources")
        rec$resources <- resources
        job$resources <- resources
      }

      if (is.null(chunks)) {
        st <- self$status(job)
        chunks <- st$chunks$chunk_id[st$chunks$state %in% sp_retryable_states()]
      } else {
        checkmate::assert_integerish(chunks, lower = 1L, upper = rec$resources$n_chunks, min.len = 1L)
        chunks <- sort(unique(as.integer(chunks)))
      }

      if (length(chunks) == 0L) {
        cli::cli_inform("Job {job$job_id}: no retryable chunks found.")
        return(job)
      }

      next_attempt <- max(rec$chunk_map$attempt[rec$chunk_map$chunk_id %in% chunks]) + 1L
      retry_filename <- sprintf("retry_%d.sbatch", next_attempt)
      local_retry_path <- file.path(rec$local_dir, retry_filename)
      remote_retry_path <- paste0(rec$remote_dir, "/", retry_filename)

      effective_sif <- rec$job_spec$container_sif %||% self$container_sif
      effective_modules <- unique(c(self$modules, rec$job_spec$modules))
      render_sbatch_script(
        job_name = paste0(rec$job_name, "_r", next_attempt),
        resources = rec$resources,
        work_dir = rec$remote_dir,
        worker_script = "worker.R",
        array_indices = chunks,
        attempt = next_attempt,
        container_sif = effective_sif,
        container_binds = self$container_binds,
        modules = effective_modules,
        env_vars = rec$job_spec$env_vars,
        output_path = local_retry_path
      )

      sbatch_cmd <- sprintf("sbatch --parsable %s", sp_sh_quote(remote_retry_path))

      if (isTRUE(self$dry_run)) {
        new_slurm_id <- paste0("DRY_RUN_R", next_attempt)
      } else {
        private$exec_scp(local_retry_path, paste0(private$target(), ":", remote_retry_path))
        sb_res <- private$exec_ssh(sbatch_cmd)
        new_slurm_id <- parse_sbatch_output(sb_res$stdout)
      }

      idx_rows <- rec$chunk_map$chunk_id %in% chunks
      rec$chunk_map$slurm_job_id[idx_rows] <- new_slurm_id
      rec$chunk_map$attempt[idx_rows] <- as.integer(rec$chunk_map$attempt[idx_rows] + 1L)
      rec$slurm_ids <- unique(c(rec$slurm_ids, new_slurm_id))

      private$jobs[[job$job_id]] <- rec
      job$scheduler_ids <- rec$slurm_ids
      job
    },

    #' @description Cancel active SLURM array job(s) or targeted chunk indices via `scancel`.
    #' @param job A `slurmpilot_job` handle.
    #' @param chunks Optional integer vector of chunk IDs to cancel.
    #' @return Latest `slurmpilot_status` invisibly.
    cancel = function(job, chunks = NULL) {
      checkmate::assert_class(job, "slurmpilot_job")
      rec <- private$get_job_record(job$job_id)

      if (is.null(chunks)) {
        for (sjid in unique(rec$slurm_ids)) {
          cmd <- build_scancel_command(sjid)
          if (!isTRUE(self$dry_run)) {
            private$exec_ssh(cmd)
          }
        }
      } else {
        checkmate::assert_integerish(chunks, lower = 1L, upper = rec$resources$n_chunks, min.len = 1L)
        sub_map <- rec$chunk_map[rec$chunk_map$chunk_id %in% chunks, , drop = FALSE]
        for (sjid in unique(sub_map$slurm_job_id)) {
          cids <- sub_map$chunk_id[sub_map$slurm_job_id == sjid]
          cmd <- build_scancel_command(sjid, chunks = cids)
          if (!isTRUE(self$dry_run)) {
            private$exec_ssh(cmd)
          }
        }
      }

      invisible(self$status(job))
    },

    #' @description Retrieve remote stdout/stderr logs via SSH.
    #' @param job A `slurmpilot_job` handle.
    #' @param chunk_id Optional integer chunk ID.
    #' @return Named list of log records (`chunk_id`, `stdout`, `stderr`).
    logs = function(job, chunk_id = NULL) {
      checkmate::assert_class(job, "slurmpilot_job")
      rec <- private$get_job_record(job$job_id)
      cids <- if (is.null(chunk_id)) {
        seq_len(rec$resources$n_chunks)
      } else {
        checkmate::assert_int(chunk_id, lower = 1L, upper = rec$resources$n_chunks)
        as.integer(chunk_id)
      }

      out <- lapply(cids, function(cid) {
        if (isTRUE(self$dry_run)) {
          return(list(chunk_id = cid, stdout = "", stderr = ""))
        }
        out_p <- paste0(rec$remote_dir, "/logs/chunk_", cid, ".out")
        err_p <- paste0(rec$remote_dir, "/logs/chunk_", cid, ".err")
        o_res <- private$exec_ssh(sprintf("cat %s 2>/dev/null || true", sp_sh_quote(out_p)), allow_error = TRUE)
        e_res <- private$exec_ssh(sprintf("cat %s 2>/dev/null || true", sp_sh_quote(err_p)), allow_error = TRUE)
        list(chunk_id = cid, stdout = o_res$stdout %||% "", stderr = e_res$stdout %||% "")
      })
      names(out) <- paste0("chunk_", cids)
      out
    },

    #' @description Retrieve remote chunk checkpoints via SCP and collect ordered task results.
    #' @param job A `slurmpilot_job` handle.
    #' @param simplify Logical; simplify homogeneous scalar or data-frame results.
    #' @param allow_partial Logical; allow collecting incomplete results.
    #' @return Ordered list (or simplified vector/tibble) of task results.
    collect = function(job, simplify = FALSE, allow_partial = FALSE) {
      checkmate::assert_class(job, "slurmpilot_job")
      rec <- private$get_job_record(job$job_id)

      if (!isTRUE(self$dry_run)) {
        remote_results <- paste0(private$target(), ":", rec$remote_dir, "/results/.")
        local_results_dir <- file.path(rec$local_dir, "results")
        dir.create(local_results_dir, recursive = TRUE, showWarnings = FALSE)
        private$exec_scp(remote_results, local_results_dir, recursive = TRUE)
      }

      sp_collect_checkpoints(
        work_dir = rec$local_dir,
        resources = rec$resources,
        simplify = simplify,
        allow_partial = allow_partial
      )
    },

    #' @description Print concise summary of the SSH/SLURM backend.
    print = function() {
      cli::cli_inform(
        "<{.cls SlurmSshBackend}> target={private$target()}, remote_dir={.path {self$remote_dir}}, dry_run={self$dry_run}"
      )
      invisible(self)
    }
  ),
  private = list(
    jobs = list(),

    target = function() {
      if (!is.null(self$user)) paste0(self$user, "@", self$host) else self$host
    },

    get_job_record = function(job_id) {
      rec <- private$jobs[[job_id]]
      if (is.null(rec)) {
        cli::cli_abort("Unknown SLURM SSH job ID: {.val {job_id}}.")
      }
      rec
    },

    ssh_args = function(remote_cmd) {
      build_ssh_args(
        host = self$host,
        user = self$user,
        port = self$port,
        ssh_key = self$ssh_key,
        ssh_options = self$ssh_options,
        remote_cmd = remote_cmd
      )
    },

    scp_args = function(src, dest, recursive = FALSE) {
      build_scp_args(
        src = src,
        dest = dest,
        port = self$port,
        ssh_key = self$ssh_key,
        ssh_options = self$ssh_options,
        recursive = recursive
      )
    },

    exec_ssh = function(remote_cmd, allow_error = FALSE) {
      args <- private$ssh_args(remote_cmd)
      res <- self$command_runner("ssh", args)
      if (!isTRUE(allow_error) && !identical(as.integer(res$status), 0L)) {
        cli::cli_abort(c(
          "SSH command failed (exit {res$status}): {.code {remote_cmd}}",
          "x" = "{res$stderr}"
        ))
      }
      res
    },

    exec_scp = function(src, dest, recursive = FALSE) {
      args <- private$scp_args(src, dest, recursive = recursive)
      res <- self$command_runner("scp", args)
      if (!identical(as.integer(res$status), 0L)) {
        cli::cli_abort(c(
          "SCP transfer failed (exit {res$status}) -> {.val {dest}}",
          "x" = "{res$stderr}"
        ))
      }
      res
    }
  )
)

#' Create an SSH/SLURM Scheduler Backend
#'
#' Convenience constructor wrapping [SlurmSshBackend]`$new(...)`.
#'
#' @param host Remote SLURM cluster hostname.
#' @param user Optional SSH username.
#' @param remote_dir Base remote workspace directory. Default `"~/slurmpilot_jobs"`.
#' @param local_stage_dir Local staging directory. Defaults to a temporary directory.
#' @param port SSH port integer. Default `22L`.
#' @param ssh_key Optional private SSH key path.
#' @param ssh_options Optional extra SSH options.
#' @param partition Optional default SLURM `--partition`.
#' @param account Optional default SLURM `--account`.
#' @param qos Optional default SLURM `--qos`.
#' @param container_sif Optional remote path to Apptainer `.sif` image.
#' @param container_binds Optional character vector of Apptainer bind mounts.
#' @param modules Optional character vector of HPC modules to load.
#' @param dry_run Logical; record commands without making network calls. Default `FALSE`.
#' @param command_runner Optional runner `function(cmd, args)` overriding `processx::run`.
#' @return A [SlurmSshBackend] R6 object.
#' @export
#' @examples
#' ssh_be <- slurm_ssh_backend(host = "hpc.example.edu", user = "researcher", dry_run = TRUE)
#' print(ssh_be)
slurm_ssh_backend <- function(
  host,
  user = NULL,
  remote_dir = "~/slurmpilot_jobs",
  local_stage_dir = NULL,
  port = 22L,
  ssh_key = NULL,
  ssh_options = character(),
  partition = NULL,
  account = NULL,
  qos = NULL,
  container_sif = NULL,
  container_binds = character(),
  modules = character(),
  dry_run = FALSE,
  command_runner = NULL
) {
  SlurmSshBackend$new(
    host = host,
    user = user,
    remote_dir = remote_dir,
    local_stage_dir = local_stage_dir,
    port = port,
    ssh_key = ssh_key,
    ssh_options = ssh_options,
    partition = partition,
    account = account,
    qos = qos,
    container_sif = container_sif,
    container_binds = container_binds,
    modules = modules,
    dry_run = dry_run,
    command_runner = command_runner
  )
}
