# Pre-submit closure, globals, and bundle size diagnostics

sp_walk_closure_envs <- function(env) {
  envs <- list()
  cur <- env
  seen <- character(0L)
  while (!is.null(cur) && !identical(cur, emptyenv()) &&
         !identical(cur, globalenv()) && !isNamespace(cur) &&
         !identical(cur, baseenv())) {
    env_id <- format(cur)
    if (env_id %in% seen) break
    seen <- c(seen, env_id)
    # Skip package environments on search path (e.g. package:stats)
    nm <- environmentName(cur)
    if (startsWith(nm, "package:") || identical(nm, "Autoloads")) break
    envs[[length(envs) + 1L]] <- cur
    cur <- parent.env(cur)
  }
  envs
}

sp_package_exports <- function(packages) {
  base_and_pkgs <- unique(c("base", "stats", "utils", "methods", "graphics", "grDevices", "datasets", packages))
  syms <- character(0L)
  for (pkg in base_and_pkgs) {
    if (requireNamespace(pkg, quietly = TRUE)) {
      ns <- asNamespace(pkg)
      syms <- c(syms, getNamespaceExports(ns))
    }
  }
  unique(syms)
}

#' Inspect Worker Function Closures, Globals, and Serialization Bundle Size
#'
#' Performs a pre-submission static and memory audit of a worker function
#' `fun`, its lexical closure environment, explicit `globals`, `packages`, and
#' optional `args_list`. Detects two common HPC failure modes before staging:
#' 1. **Accidental closure bloat:** A function defined inside another function
#'    silently captures large local objects (such as raw datasets >50 MB) in its
#'    enclosing frame, inflating `payload.rds` for every SLURM array task.
#' 2. **Missing or unexported globals:** Free variables or local helper
#'    functions referenced inside `fun` that are neither exported by `packages`
#'    nor explicitly listed in `globals`, which would fail on isolated cluster
#'    workers.
#'
#' @param fun Worker function `fun(arg)` to inspect.
#' @param args_list Optional list of task arguments included in bundle size
#'   estimation.
#' @param globals Optional named list of explicit worker globals.
#' @param packages Character vector of packages declared for worker nodes.
#' @param size_warn_mb Numeric threshold in MB above which captured closure
#'   objects or total estimated bundle size trigger a diagnostic warning.
#'   Default `50`.
#'
#' @return An S3 object of class `"slurmpilot_globals_report"` containing:
#'   - `ok`: logical (`TRUE` when zero warnings are emitted).
#'   - `warnings`: character vector of actionable pre-submit warnings.
#'   - `estimated_bundle_mb`: total estimated serialization size in MB.
#'   - `fun_size_mb`, `args_size_mb`, `globals_size_mb`: component sizes in MB.
#'   - `closure_objects`: tibble of objects captured in non-global enclosing
#'     frames (`name`, `class`, `size_mb`, `env_name`).
#'   - `globals_table`: tibble of explicit `globals` (`name`, `class`, `size_mb`).
#'   - `missing_variables`: character vector of unresolved free variables.
#'   - `unexported_functions`: character vector of referenced functions not found
#'     in base/declared `packages` or `globals`.
#'
#' @seealso [slurm_job_spec()], [slurm_submit()]
#' @export
#' @examples
#' make_worker <- function() {
#'   local_offset <- 10
#'   function(x) x + local_offset
#' }
#' rep <- inspect_job_globals(make_worker(), args_list = as.list(1:5))
#' print(rep)
inspect_job_globals <- function(
  fun,
  args_list = NULL,
  globals = list(),
  packages = character(),
  size_warn_mb = 50
) {
  checkmate::assert_function(fun)
  if (!is.null(args_list) && !is.list(args_list)) {
    args_list <- as.list(args_list)
  }
  checkmate::assert_list(globals)
  if (length(globals) > 0L) checkmate::assert_named(globals, type = "unique")
  checkmate::assert_character(packages, any.missing = FALSE)
  checkmate::assert_number(size_warn_mb, lower = 0.001, finite = TRUE)

  # 1. Inspect lexical closure environments for captured objects
  closure_envs <- sp_walk_closure_envs(environment(fun))
  closure_rows <- list()
  closure_syms <- character(0L)

  for (idx in seq_along(closure_envs)) {
    env_i <- closure_envs[[idx]]
    env_label <- environmentName(env_i)
    if (!nzchar(env_label)) env_label <- sprintf("local_frame_%d", idx)
    objs <- ls(envir = env_i, all.names = TRUE)
    closure_syms <- c(closure_syms, objs)
    for (nm in objs) {
      val <- tryCatch(get(nm, envir = env_i, inherits = FALSE), error = function(e) NULL)
      sz_mb <- as.numeric(utils::object.size(val)) / (1024^2)
      cls <- paste(class(val), collapse = "/")
      closure_rows[[length(closure_rows) + 1L]] <- tibble::tibble(
        name = nm,
        class = cls,
        size_mb = sz_mb,
        env_name = env_label
      )
    }
  }

  closure_tbl <- if (length(closure_rows) > 0L) {
    df <- do.call(rbind, closure_rows)
    df[order(-df$size_mb, df$name), , drop = FALSE]
  } else {
    tibble::tibble(name = character(), class = character(), size_mb = numeric(), env_name = character())
  }

  # 2. Inspect explicit globals table
  globals_tbl <- if (length(globals) > 0L) {
    rows <- lapply(names(globals), function(nm) {
      val <- globals[[nm]]
      tibble::tibble(
        name = nm,
        class = paste(class(val), collapse = "/"),
        size_mb = as.numeric(utils::object.size(val)) / (1024^2)
      )
    })
    df <- do.call(rbind, rows)
    df[order(-df$size_mb, df$name), , drop = FALSE]
  } else {
    tibble::tibble(name = character(), class = character(), size_mb = numeric())
  }

  # 3. Static free-variable & function detection via codetools::findGlobals
  fg <- tryCatch(
    codetools::findGlobals(fun, merge = FALSE),
    error = function(e) list(functions = character(), variables = character())
  )
  known_exports <- sp_package_exports(packages)
  provided_syms <- unique(c(names(globals), closure_syms, known_exports))

  # Ignore special control-flow / syntax operators
  special_ops <- c(
    "{", "(", "if", "else", "for", "while", "repeat", "next", "break",
    "return", "function", "<-", "<<-", "=", "$", "@", "[", "[[", "::", ":::",
    "~", ":", "+", "-", "*", "/", "^", "%%", "%/%", "%*%", "%in%", "|>",
    "!", "&", "&&", "|", "||", "==", "!=", "<", "<=", ">", ">=", "TRUE",
    "FALSE", "NULL", "NA", "NaN", "Inf", "T", "F", "c", "list", ".data"
  )

  missing_vars <- setdiff(fg$variables, c(provided_syms, special_ops))
  unexported_fns <- setdiff(fg$functions, c(provided_syms, special_ops))

  # 4. Component serialization size estimates
  fun_size_mb <- as.numeric(utils::object.size(fun)) / (1024^2)
  closure_total_mb <- sum(closure_tbl$size_mb, na.rm = TRUE)
  args_size_mb <- if (!is.null(args_list)) as.numeric(utils::object.size(args_list)) / (1024^2) else 0
  globals_size_mb <- if (length(globals) > 0L) as.numeric(utils::object.size(globals)) / (1024^2) else 0
  est_bundle_mb <- fun_size_mb + closure_total_mb + args_size_mb + globals_size_mb

  # 5. Assemble actionable diagnostics
  warnings_vec <- character(0L)
  large_closure <- closure_tbl[closure_tbl$size_mb >= size_warn_mb, , drop = FALSE]
  if (nrow(large_closure) > 0L) {
    items <- sprintf("%s (%.1f MB)", large_closure$name, large_closure$size_mb)
    warnings_vec <- c(
      warnings_vec,
      sprintf(
        "Worker closure captures large local object(s) >= %.1f MB: %s. Consider setting environment(fun) <- globalenv() and passing only required objects via globals.",
        size_warn_mb, paste(items, collapse = ", ")
      )
    )
  }
  if (est_bundle_mb >= size_warn_mb && nrow(large_closure) == 0L) {
    warnings_vec <- c(
      warnings_vec,
      sprintf(
        "Estimated staged payload size (%.1f MB) exceeds %.1f MB; consider reading large read-only datasets from shared HPC storage instead of serializing in payload.rds.",
        est_bundle_mb, size_warn_mb
      )
    )
  }
  if (length(missing_vars) > 0L) {
    warnings_vec <- c(
      warnings_vec,
      sprintf(
        "Unresolved free variable(s) referenced in fun: %s. Pass them explicitly via globals = list(...).",
        paste(missing_vars, collapse = ", ")
      )
    )
  }
  if (length(unexported_fns) > 0L) {
    warnings_vec <- c(
      warnings_vec,
      sprintf(
        "Unexported or undeclared function(s) referenced in fun: %s. Pass helper functions via globals = list(...) or declare their package in packages = c(...).",
        paste(unexported_fns, collapse = ", ")
      )
    )
  }

  structure(
    list(
      ok = length(warnings_vec) == 0L,
      warnings = warnings_vec,
      estimated_bundle_mb = est_bundle_mb,
      fun_size_mb = fun_size_mb,
      closure_size_mb = closure_total_mb,
      args_size_mb = args_size_mb,
      globals_size_mb = globals_size_mb,
      size_warn_mb = size_warn_mb,
      closure_objects = closure_tbl,
      globals_table = globals_tbl,
      missing_variables = missing_vars,
      unexported_functions = unexported_fns,
      packages = packages
    ),
    class = "slurmpilot_globals_report"
  )
}

#' @export
print.slurmpilot_globals_report <- function(x, ...) {
  status_tag <- if (isTRUE(x$ok)) "OK" else sprintf("%d warning(s)", length(x$warnings))
  cli::cli_h3("slurmpilot Pre-Submit Globals & Bundle Audit [{status_tag}]")
  cli::cli_bullets(c(
    "*" = "Estimated payload size: {sprintf('%.2f MB', x$estimated_bundle_mb)} (closure={sprintf('%.2f MB', x$closure_size_mb)}, globals={sprintf('%.2f MB', x$globals_size_mb)}, args={sprintf('%.2f MB', x$args_size_mb)})",
    "*" = "Captured local closure objects: {nrow(x$closure_objects)} | Explicit globals: {nrow(x$globals_table)}",
    "*" = "Unresolved variables: {length(x$missing_variables)} | Unexported functions: {length(x$unexported_functions)}"
  ))
  if (length(x$warnings) > 0L) {
    for (w in x$warnings) {
      cli::cli_bullets(c("!" = w))
    }
  }
  invisible(x)
}
