# Security validation, injection defense, path confinement & checkpoint integrity

sp_assert_no_control_chars <- function(x, arg = "value") {
  checkmate::assert_character(x, any.missing = FALSE)
  bad <- grepl("[\r\n\t[:cntrl:]]", x, perl = TRUE)
  if (any(bad)) {
    cli::cli_abort(
      "Unsafe control or newline character detected in {.arg {arg}}."
    )
  }
  invisible(x)
}

sp_has_shell_metachars <- function(x) {
  grepl("[`$;|&><(){}\\\\'\"*?!#]", x, perl = TRUE)
}

sp_assert_safe_slurm_token <- function(x, arg = "value") {
  checkmate::assert_string(x, min.chars = 1L)
  sp_assert_no_control_chars(x, arg = arg)
  if (startsWith(x, "-")) {
    cli::cli_abort("{.arg {arg}} must not start with '-' (option injection guard): {.val {x}}.")
  }
  if (!grepl("^[A-Za-z0-9][A-Za-z0-9_.:/@+-]{0,127}$", x) || sp_has_shell_metachars(x)) {
    cli::cli_abort("Unsafe characters in SLURM parameter {.arg {arg}}: {.val {x}}.")
  }
  invisible(x)
}

sp_assert_safe_mail_type <- function(x, arg = "mail_type") {
  checkmate::assert_string(x, min.chars = 1L)
  sp_assert_no_control_chars(x, arg = arg)
  if (!grepl("^[A-Z0-9_]+(,[A-Z0-9_]+)*$", toupper(x))) {
    cli::cli_abort("Invalid SLURM {.arg {arg}} specification: {.val {x}}.")
  }
  invisible(toupper(x))
}

sp_assert_safe_email <- function(x, arg = "mail_user") {
  checkmate::assert_string(x, min.chars = 3L)
  sp_assert_no_control_chars(x, arg = arg)
  if (!grepl("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,63}$", x)) {
    cli::cli_abort("Invalid or unsafe email address in {.arg {arg}}: {.val {x}}.")
  }
  invisible(x)
}

sp_assert_safe_module_name <- function(x, arg = "modules") {
  checkmate::assert_character(x, any.missing = FALSE)
  if (length(x) == 0L) return(invisible(x))
  sp_assert_no_control_chars(x, arg = arg)
  for (m in x) {
    if (startsWith(m, "-") || grepl("(^|/)\\.\\.(/|$)", m) ||
        !grepl("^[A-Za-z0-9][A-Za-z0-9_./+-]{0,127}$", m)) {
      cli::cli_abort("Unsafe HPC module name in {.arg {arg}}: {.val {m}}.")
    }
  }
  invisible(x)
}

sp_assert_safe_env_name <- function(x, arg = "env_vars") {
  checkmate::assert_character(x, any.missing = FALSE)
  if (length(x) == 0L) return(invisible(x))
  sp_assert_no_control_chars(x, arg = arg)
  bad <- !grepl("^[A-Za-z_][A-Za-z0-9_]{0,127}$", x)
  if (any(bad)) {
    cli::cli_abort("Invalid environment variable name in {.arg {arg}}: {.val {x[bad][[1L]]}}.")
  }
  invisible(x)
}

sp_assert_safe_extra_sbatch <- function(x, arg = "extra_sbatch") {
  checkmate::assert_character(x, any.missing = FALSE)
  if (length(x) == 0L) return(invisible(x))
  sp_assert_no_control_chars(x, arg = arg)
  forbidden_flags <- paste(
    c(
      "--wrap", "--prolog", "--epilog", "--task-prolog", "--task-epilog",
      "--get-user-env", "--output", "-o", "--error", "-e", "--chdir", "-D",
      "--export", "--batch", "--input", "-i"
    ),
    collapse = "|"
  )
  forbidden_pat <- paste0("(^|\\s)(", forbidden_flags, ")(=|\\s|$)")
  for (line in x) {
    trimmed <- trimws(line)
    if (!nzchar(trimmed) || !grepl("^--?[A-Za-z0-9]", trimmed)) {
      cli::cli_abort(
        "Each entry in {.arg {arg}} must be a single valid SLURM flag (e.g. '--gres=gpu:1'): {.val {line}}."
      )
    }
    if (grepl("['\"`$;&|><\\\\(){}*?!#]", trimmed, perl = TRUE)) {
      cli::cli_abort("Unsafe shell metacharacter or quote in {.arg {arg}}: {.val {line}}.")
    }
    if (grepl(forbidden_pat, trimmed, ignore.case = TRUE, perl = TRUE)) {
      cli::cli_abort(
        "Forbidden SLURM directive (such as {.code --wrap}, {.code --prolog}, {.code --epilog}, or I/O override) in {.arg {arg}}: {.val {line}}."
      )
    }
    # Forbid smuggling multiple flags in one entry (e.g. '--comment=ok --partition=gpu')
    if (grepl("\\s+-", trimmed, perl = TRUE)) {
      cli::cli_abort(
        "Multiple flags in a single {.arg {arg}} entry are forbidden; pass one flag per element: {.val {line}}."
      )
    }
  }
  invisible(x)
}

sp_assert_safe_path <- function(x, arg = "path", allow_tilde = FALSE, allow_relative = FALSE, allow_spaces = FALSE) {
  checkmate::assert_string(x, min.chars = 1L)
  sp_assert_no_control_chars(x, arg = arg)
  if (startsWith(x, "-")) {
    cli::cli_abort("Path {.arg {arg}} must not start with '-' (option injection guard): {.val {x}}.")
  }
  if (!isTRUE(allow_spaces) && grepl("[[:space:]]", x)) {
    cli::cli_abort("Whitespace is not permitted in {.arg {arg}}: {.val {x}}.")
  }
  if (grepl("(^|[/\\\\])\\.\\.([/\\\\]|$)", x)) {
    cli::cli_abort("Path traversal ('..') is forbidden in {.arg {arg}}: {.val {x}}.")
  }
  if (!isTRUE(allow_tilde) && startsWith(x, "~")) {
    cli::cli_abort("Unexpanded '~' is not permitted in {.arg {arg}}: {.val {x}}.")
  }
  if (!isTRUE(allow_relative) && !grepl("^(/|~|~/|[A-Za-z]:[/\\\\])", x)) {
    # Allow relative only when explicitly requested
    cli::cli_abort("Relative path is not permitted in {.arg {arg}}: {.val {x}}.")
  }
  if (grepl("[`$;|&><(){}\"'*?]", x, perl = TRUE)) {
    cli::cli_abort("Unsafe shell metacharacter in {.arg {arg}}: {.val {x}}.")
  }
  invisible(x)
}

sp_assert_safe_relpath <- function(x, arg = "path") {
  checkmate::assert_string(x, min.chars = 1L)
  sp_assert_no_control_chars(x, arg = arg)
  if (startsWith(x, "-") || startsWith(x, "/") || startsWith(x, "~")) {
    cli::cli_abort("{.arg {arg}} must be a safe relative path without leading '-', '/', or '~': {.val {x}}.")
  }
  if (grepl("(^|[/\\\\])\\.\\.([/\\\\]|$)", x)) {
    cli::cli_abort("Path traversal ('..') is forbidden in {.arg {arg}}: {.val {x}}.")
  }
  if (!grepl("^[A-Za-z0-9._/-]{1,255}$", x)) {
    cli::cli_abort("Unsafe characters in relative path {.arg {arg}}: {.val {x}}.")
  }
  invisible(x)
}

sp_resolve_real_path <- function(path, max_depth = 20L) {
  cur <- gsub("\\\\", "/", path)
  cur <- sub("/+$", "", cur)
  if (!nzchar(cur)) cur <- "/"

  depth <- 0L
  while (depth < max_depth) {
    depth <- depth + 1L
    # Check if cur itself is a symlink (including dangling symlinks where file.exists() is FALSE)
    lnk <- tryCatch(Sys.readlink(cur), error = function(e) "")
    if (!is.na(lnk) && nzchar(lnk)) {
      target <- if (grepl("^(/|[A-Za-z]:/)", lnk)) {
        lnk
      } else {
        file.path(dirname(cur), lnk)
      }
      cur <- gsub("\\\\", "/", target)
      cur <- sub("/+$", "", cur)
      if (!nzchar(cur)) cur <- "/"
      next
    }
    if (file.exists(cur) || dir.exists(cur)) {
      return(sub("/+$", "", normalizePath(cur, winslash = "/", mustWork = TRUE)))
    }
    # Walk upward to resolve the nearest existing ancestor (and any symlinks along the way)
    tail_parts <- character(0L)
    probe <- cur
    resolved_base <- NULL
    while (TRUE) {
      lnk_p <- tryCatch(Sys.readlink(probe), error = function(e) "")
      if (!is.na(lnk_p) && nzchar(lnk_p)) {
        target_p <- if (grepl("^(/|[A-Za-z]:/)", lnk_p)) lnk_p else file.path(dirname(probe), lnk_p)
        cur <- if (length(tail_parts) > 0L) {
          paste(c(sub("/+$", "", gsub("\\\\", "/", target_p)), rev(tail_parts)), collapse = "/")
        } else {
          sub("/+$", "", gsub("\\\\", "/", target_p))
        }
        resolved_base <- NULL
        break
      }
      if (file.exists(probe) || dir.exists(probe)) {
        resolved_base <- sub("/+$", "", normalizePath(probe, winslash = "/", mustWork = TRUE))
        break
      }
      parent <- dirname(probe)
      if (identical(parent, probe)) {
        resolved_base <- probe
        break
      }
      tail_parts <- c(tail_parts, basename(probe))
      probe <- parent
    }
    if (!is.null(resolved_base)) {
      if (length(tail_parts) == 0L) {
        return(resolved_base)
      }
      return(paste(c(resolved_base, rev(tail_parts)), collapse = "/"))
    }
  }
  cli::cli_abort("Exceeded maximum symlink resolution depth while validating path: {.path {path}}.")
}

sp_assert_path_confined <- function(path, root_dir, arg = "path") {
  sp_assert_no_control_chars(path, arg = arg)
  if (grepl("(^|[/\\\\])\\.\\.([/\\\\]|$)", path)) {
    cli::cli_abort(
      "Path traversal ('..') violates confinement for {.arg {arg}}: {.path {path}}."
    )
  }
  norm_root <- sp_resolve_real_path(root_dir)
  norm_path <- sp_resolve_real_path(path)
  if (grepl("(^|[/\\\\])\\.\\.([/\\\\]|$)", norm_path)) {
    cli::cli_abort(
      "Resolved path traversal ('..') violates confinement for {.arg {arg}}: {.path {path}}."
    )
  }
  prefix <- paste0(sub("/+$", "", norm_root), "/")
  if (!(identical(norm_path, sub("/+$", "", norm_root)) || startsWith(norm_path, prefix))) {
    cli::cli_abort(
      "Path confinement violation for {.arg {arg}}: {.path {path}} escapes root {.path {root_dir}}."
    )
  }
  invisible(norm_path)
}

sp_assert_safe_id <- function(x, arg = "job_id") {
  checkmate::assert_string(x, min.chars = 1L)
  sp_assert_no_control_chars(x, arg = arg)
  if (!grepl("^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", x)) {
    cli::cli_abort("Invalid identifier {.arg {arg}}: {.val {x}}.")
  }
  invisible(x)
}

sp_assert_safe_slurm_job_id <- function(x, arg = "slurm_job_id", allow_dry_run = FALSE) {
  jid <- as.character(x)
  checkmate::assert_string(jid, min.chars = 1L)
  sp_assert_no_control_chars(jid, arg = arg)
  valid <- grepl("^[0-9]{1,20}$", jid) ||
    (isTRUE(allow_dry_run) && grepl("^DRY_RUN(_R[0-9]+)?$", jid))
  if (!valid) {
    cli::cli_abort("Invalid SLURM job ID in {.arg {arg}}: {.val {jid}}.")
  }
  invisible(jid)
}

sp_assert_safe_slurm_dependency <- function(x, arg = "dependency", allow_dry_run = FALSE) {
  checkmate::assert_string(x, min.chars = 1L)
  sp_assert_no_control_chars(x, arg = arg)
  clauses <- strsplit(x, ",", fixed = TRUE)[[1L]]
  if (length(clauses) == 0L || any(!nzchar(clauses))) {
    cli::cli_abort("Invalid SLURM {.arg {arg}} specification: {.val {x}}.")
  }
  id_pat <- if (isTRUE(allow_dry_run)) "(?:[0-9]{1,20}|DRY_RUN(?:_R[0-9]+)?)" else "[0-9]{1,20}"
  clause_pat <- paste0(
    "^(?:singleton|(?:after|afterany|afterburstbuffer|aftercorr|afternotok|afterok)(?::",
    id_pat,
    ")+)$"
  )
  for (cl in clauses) {
    if (!grepl(clause_pat, cl, perl = TRUE)) {
      cli::cli_abort("Unsafe or invalid SLURM {.arg {arg}} clause: {.val {cl}}.")
    }
  }
  invisible(x)
}

sp_assert_safe_ssh_host <- function(x, arg = "host") {
  checkmate::assert_string(x, min.chars = 1L)
  sp_assert_no_control_chars(x, arg = arg)
  if (startsWith(x, "-")) {
    cli::cli_abort("SSH {.arg {arg}} must not start with '-' (option injection guard): {.val {x}}.")
  }
  if (!grepl("^[A-Za-z0-9][A-Za-z0-9._:-]{0,253}$", x)) {
    cli::cli_abort("Invalid or unsafe SSH {.arg {arg}}: {.val {x}}.")
  }
  invisible(x)
}

sp_assert_safe_ssh_user <- function(x, arg = "user") {
  checkmate::assert_string(x, min.chars = 1L)
  sp_assert_no_control_chars(x, arg = arg)
  if (startsWith(x, "-")) {
    cli::cli_abort("SSH {.arg {arg}} must not start with '-' (option injection guard): {.val {x}}.")
  }
  if (!grepl("^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$", x)) {
    cli::cli_abort("Invalid or unsafe SSH {.arg {arg}}: {.val {x}}.")
  }
  invisible(x)
}

sp_assert_safe_ssh_options <- function(x, arg = "ssh_options") {
  checkmate::assert_character(x, any.missing = FALSE)
  if (length(x) == 0L) return(invisible(x))
  sp_assert_no_control_chars(x, arg = arg)

  forbidden_directives <- c(
    "proxycommand", "localcommand", "permitlocalcommand",
    "remotecommand", "proxyusefdpass", "knownhostscommand",
    "match", "include", "identityfile", "controlpath",
    "controlmaster", "controlpersist", "proxyjump",
    "forwardagent", "sendenv", "setenv", "pkcs11provider",
    "securitykeyprovider", "dynamicforward", "localforward",
    "remoteforward", "userknownhostsfile"
  )
  pattern <- paste0("(^|[^a-z]|-o)(", paste(forbidden_directives, collapse = "|"), ")(\\b|=|$)")
  # Block dangerous SSH CLI flags (-F config file, -S control socket, -J jump, port/agent forwarding, -i/-E/-O/-M/-G)
  forbidden_flag_pat <- "^-[46CTqvNfn]*(F|S|L|R|D|W|A|E|O|M|G|i|J)($|[^A-Za-z]|.)"

  for (opt in x) {
    trimmed <- trimws(opt)
    if (grepl(forbidden_flag_pat, trimmed, perl = TRUE)) {
      cli::cli_abort(
        "Dangerous SSH CLI flag forbidden in {.arg {arg}}: {.val {opt}}."
      )
    }
    if (grepl(pattern, tolower(trimmed), perl = TRUE)) {
      cli::cli_abort(
        "Dangerous SSH directive forbidden in {.arg {arg}}: {.val {opt}}."
      )
    }
    if (grepl("[`$;|&><]", trimmed, perl = TRUE)) {
      cli::cli_abort("Unsafe shell metacharacter in {.arg {arg}}: {.val {opt}}.")
    }
  }
  invisible(x)
}

sp_sh_quote_path <- function(x) {
  vapply(as.character(x), function(s) {
    if (identical(s, "~")) {
      return("\"$HOME\"")
    }
    if (startsWith(s, "~/")) {
      rest <- sub("^~/", "", s)
      return(paste0("\"$HOME\"/", sp_sh_quote(rest)))
    }
    sp_sh_quote(s)
  }, character(1L), USE.NAMES = FALSE)
}

sp_is_secret_env_name <- function(x) {
  if (length(x) == 0L) return(logical(0L))
  pat <- paste0(
    "(^|_)(API_?KEY|SECRET(_?KEY)?|TOKEN|PASSWORD|PASSWD|PASS|CREDENTIAL|",
    "PRIVATE_?KEY|ACCESS_?KEY|SESSION_?TOKEN|AUTH|COOKIE|DSN)(_|$)|",
    "^(AWS_|GITHUB_|GH_|OPENAI_|ANTHROPIC_|GEMINI_|GOOGLE_API|HF_TOKEN|",
    "HUGGING_?FACE|AZURE_|GCP_|SLURM_JWT|DATABASE_URL|POSTGRES_URL|MYSQL_|",
    "REDIS_URL|MONGO_URI|PGPASS)"
  )
  grepl(pat, as.character(x), ignore.case = TRUE, perl = TRUE)
}

sp_scrub_ambient_env <- function(env = Sys.getenv(), keep = character()) {
  if (length(env) == 0L) return(env)
  nms <- names(env)
  if (is.null(nms)) return(env)
  drop <- sp_is_secret_env_name(nms) & !(nms %in% as.character(keep))
  out <- as.character(env[!drop])
  names(out) <- nms[!drop]
  out
}

sp_callr_scrubbed_env <- function(keep = character()) {
  cur <- Sys.getenv()
  nms <- names(cur)
  drop <- if (!is.null(nms)) {
    nms[sp_is_secret_env_name(nms) & !(nms %in% as.character(keep))]
  } else {
    character(0L)
  }
  unset_map <- if (length(drop) > 0L) {
    stats::setNames(rep(NA_character_, length(drop)), drop)
  } else {
    character(0L)
  }
  base_safe <- callr::rcmd_safe_env()
  base_safe <- base_safe[!(names(base_safe) %in% names(unset_map))]
  c(base_safe, unset_map, R_ENVIRON_USER = "", R_PROFILE_USER = "")
}

sp_assert_safe_r_package <- function(x, arg = "packages") {
  checkmate::assert_character(x, any.missing = FALSE)
  if (length(x) == 0L) return(invisible(x))
  sp_assert_no_control_chars(x, arg = arg)
  bad <- !grepl("^[A-Za-z][A-Za-z0-9.]*[A-Za-z0-9]$", x)
  if (any(bad)) {
    cli::cli_abort("Invalid or unsafe R package name in {.arg {arg}}: {.val {x[bad][[1L]]}}.")
  }
  invisible(x)
}

sp_assert_safe_apt_package <- function(x, arg = "apt_packages") {
  checkmate::assert_character(x, any.missing = FALSE)
  if (length(x) == 0L) return(invisible(x))
  sp_assert_no_control_chars(x, arg = arg)
  bad <- !grepl("^[a-z0-9][a-z0-9+.-]{1,127}$", x) | grepl("\\.\\.", x)
  if (any(bad)) {
    cli::cli_abort("Invalid or unsafe Debian/Ubuntu apt package name in {.arg {arg}}: {.val {x[bad][[1L]]}}.")
  }
  invisible(x)
}

sp_assert_safe_docker_image <- function(x, arg = "base_image") {
  checkmate::assert_string(x, min.chars = 1L)
  sp_assert_no_control_chars(x, arg = arg)
  if (startsWith(x, "-") || grepl("\\.\\.", x) ||
      !grepl("^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,255}$", x)) {
    cli::cli_abort("Invalid or unsafe container base image reference in {.arg {arg}}: {.val {x}}.")
  }
  invisible(x)
}

sp_assert_safe_version <- function(x, arg = "version") {
  checkmate::assert_string(x, min.chars = 1L)
  sp_assert_no_control_chars(x, arg = arg)
  if (!grepl("^[0-9]+(\\.[0-9A-Za-z-]+)*$", x)) {
    cli::cli_abort("Invalid version string in {.arg {arg}}: {.val {x}}.")
  }
  invisible(x)
}

sp_assert_safe_url <- function(x, arg = "url") {
  checkmate::assert_string(x, min.chars = 8L)
  sp_assert_no_control_chars(x, arg = arg)
  if (!grepl("^https?://[A-Za-z0-9._~:/?#\\[\\]@!*+,;=%-]+$", x, perl = TRUE) ||
      grepl("['\"`$\\\\\\s]", x, perl = TRUE)) {
    cli::cli_abort("Invalid or unsafe HTTP(S) URL in {.arg {arg}}: {.val {x}}.")
  }
  invisible(x)
}

sp_assert_safe_apptainer_bind <- function(x, arg = "container_binds") {
  checkmate::assert_character(x, any.missing = FALSE)
  if (length(x) == 0L) return(invisible(x))
  sp_assert_no_control_chars(x, arg = arg)
  for (b in x) {
    parts <- strsplit(b, ":", fixed = TRUE)[[1L]]
    if (length(parts) < 1L || length(parts) > 3L) {
      cli::cli_abort("Invalid Apptainer bind mount in {.arg {arg}}: {.val {b}}.")
    }
    sp_assert_safe_path(parts[[1L]], arg = arg, allow_tilde = FALSE, allow_relative = FALSE)
    if (length(parts) >= 2L) {
      sp_assert_safe_path(parts[[2L]], arg = arg, allow_tilde = FALSE, allow_relative = FALSE)
    }
    if (length(parts) == 3L && !(parts[[3L]] %in% c("ro", "rw"))) {
      cli::cli_abort("Invalid Apptainer bind mode in {.arg {arg}} (expected 'ro' or 'rw'): {.val {b}}.")
    }
  }
  invisible(x)
}

sp_assert_safe_apptainer_post <- function(x, arg = "extra_post") {
  checkmate::assert_character(x, any.missing = FALSE)
  if (length(x) == 0L) return(invisible(x))
  for (line in x) {
    if (grepl("[\r\n]", line)) {
      cli::cli_abort("Multiline entries are not allowed in {.arg {arg}}; pass one line per vector element.")
    }
    if (grepl("^\\s*%(post|files|environment|labels|test|runscript|setup|startscript|help|app)\\b", line, ignore.case = TRUE)) {
      cli::cli_abort("Apptainer section breakout directive forbidden in {.arg {arg}}: {.val {line}}.")
    }
  }
  invisible(x)
}

sp_escape_ui_text <- function(x, max_chars = 500L) {
  if (is.null(x) || length(x) == 0L || is.na(x[[1L]])) {
    return("")
  }
  s <- as.character(x[[1L]])
  # Strip ANSI escape sequences and non-printable control characters (keep \n for logs)
  s <- gsub("\033\\[[0-9;]*[A-Za-z]", "", s, perl = TRUE)
  s <- gsub("[\001-\010\013\014\016-\037\177]", "", s, perl = TRUE)
  if (nchar(s, type = "chars") > max_chars) {
    s <- paste0(substr(s, 1L, max_chars - 3L), "...")
  }
  s
}

sp_clamp_int <- function(x, default, lower, upper) {
  val <- suppressWarnings(as.integer(x))
  if (length(val) != 1L || is.na(val) || !is.finite(val)) {
    return(as.integer(default))
  }
  as.integer(max(lower, min(upper, val)))
}

sp_clamp_num <- function(x, default, lower, upper) {
  val <- suppressWarnings(as.numeric(x))
  if (length(val) != 1L || is.na(val) || !is.finite(val)) {
    return(as.numeric(default))
  }
  as.numeric(max(lower, min(upper, val)))
}

#' Verify SHA-256 Checksum and Readability of a Chunk Checkpoint
#'
#' Validates that a chunk `.rds` checkpoint exists, matches its recorded SHA-256
#' sidecar digest (and optional `expected_sha256`), and deserializes cleanly via
#' [readRDS()]. Protects [slurm_collect()] against silent corruption or partial
#' writes on shared HPC filesystems.
#'
#' @param result_path Path to a `chunk_XXXX.rds` checkpoint file.
#' @param expected_sha256 Optional 64-character hexadecimal SHA-256 string to
#'   verify against in addition to the `.sha256` sidecar file (if present).
#' @param require_sidecar Logical; if `TRUE`, fails when no `.sha256` sidecar
#'   exists and `expected_sha256` is `NULL`. Default `FALSE` (verifies whenever
#'   a sidecar or `expected_sha256` is available).
#'
#' @return A named list with `ok` (logical), `sha256` (actual SHA-256 hex),
#'   `expected_sha256`, `reason` (`NA_character_` when valid), and `object`
#'   (the deserialized chunk object when valid, else `NULL`).
#' @export
#' @examples
#' tmp <- tempfile(fileext = ".rds")
#' saveRDS(list(chunk_id = 1L, results = list()), tmp)
#' writeLines(digest::digest(tmp, algo = "sha256", file = TRUE), paste0(tmp, ".sha256"))
#' verify_checkpoint(tmp)$ok
#' unlink(c(tmp, paste0(tmp, ".sha256")))
verify_checkpoint <- function(result_path, expected_sha256 = NULL, require_sidecar = FALSE) {
  checkmate::assert_string(result_path, min.chars = 1L)
  if (!is.null(expected_sha256)) {
    checkmate::assert_string(expected_sha256, min.chars = 1L)
  }
  checkmate::assert_flag(require_sidecar)

  if (!file.exists(result_path)) {
    return(list(
      ok = FALSE,
      sha256 = NA_character_,
      expected_sha256 = expected_sha256 %||% NA_character_,
      reason = "Checkpoint file does not exist.",
      object = NULL
    ))
  }

  finfo <- file.info(result_path)
  if (is.na(finfo$size) || finfo$size <= 0) {
    return(list(
      ok = FALSE,
      sha256 = NA_character_,
      expected_sha256 = expected_sha256 %||% NA_character_,
      reason = "Checkpoint file is empty (0 bytes).",
      object = NULL
    ))
  }

  actual_sha <- tolower(digest::digest(result_path, algo = "sha256", file = TRUE))
  sidecar_path <- paste0(result_path, ".sha256")
  sidecar_sha <- NULL

  if (file.exists(sidecar_path)) {
    raw_sidecar <- tryCatch(readLines(sidecar_path, warn = FALSE), error = function(e) character())
    if (length(raw_sidecar) > 0L) {
      tokens <- strsplit(trimws(raw_sidecar[[1L]]), "\\s+")[[1L]]
      sidecar_sha <- if (length(tokens) > 0L && nzchar(tokens[[1L]])) tolower(tokens[[1L]]) else ""
    } else {
      sidecar_sha <- ""
    }
  }

  if (isTRUE(require_sidecar) && is.null(sidecar_sha) && is.null(expected_sha256)) {
    return(list(
      ok = FALSE,
      sha256 = actual_sha,
      expected_sha256 = NA_character_,
      reason = "Missing SHA-256 checkpoint sidecar file.",
      object = NULL
    ))
  }

  if (!is.null(sidecar_sha)) {
    if (!grepl("^[0-9a-f]{64}$", sidecar_sha) || !identical(actual_sha, sidecar_sha)) {
      return(list(
        ok = FALSE,
        sha256 = actual_sha,
        expected_sha256 = sidecar_sha,
        reason = sprintf("SHA-256 sidecar mismatch (expected %s, got %s).", sidecar_sha, actual_sha),
        object = NULL
      ))
    }
  }

  if (!is.null(expected_sha256)) {
    exp_clean <- tolower(trimws(expected_sha256))
    if (!grepl("^[0-9a-f]{64}$", exp_clean) || !identical(actual_sha, exp_clean)) {
      return(list(
        ok = FALSE,
        sha256 = actual_sha,
        expected_sha256 = exp_clean,
        reason = sprintf("SHA-256 digest mismatch (expected %s, got %s).", exp_clean, actual_sha),
        object = NULL
      ))
    }
  }

  obj <- tryCatch(
    readRDS(result_path),
    error = function(e) {
      structure(list(error = conditionMessage(e)), class = "sp_corrupt_rds")
    }
  )

  if (inherits(obj, "sp_corrupt_rds")) {
    return(list(
      ok = FALSE,
      sha256 = actual_sha,
      expected_sha256 = sidecar_sha %||% expected_sha256 %||% NA_character_,
      reason = sprintf("Corrupted or truncated RDS payload: %s", obj$error),
      object = NULL
    ))
  }

  list(
    ok = TRUE,
    sha256 = actual_sha,
    expected_sha256 = sidecar_sha %||% expected_sha256 %||% actual_sha,
    reason = NA_character_,
    object = obj
  )
}
