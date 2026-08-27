# =============================================================================
# workbench_api.R
# -----------------------------------------------------------------------------
# A thin, consistent R wrapper around the Posit Workbench management API
# (JSON-RPC over HTTPS). Covers all 15 documented methods as of the
# Workbench 2026.08 interface reference.
#
# Design
# ------
#   * One transport core (.wb_perform / .wb_build_req) owns the JSON-RPC
#     envelope {"method": ..., "kwparams": {...}}, auth, timeouts, and BOTH
#     error levels (HTTP status + in-body JSON-RPC error).
#   * One config object (wb_config) holds base_url + token so callers don't
#     repeat credentials on every call.
#   * 15 thin wrappers map documented snake_case parameters to named R args,
#     every optional arg defaulting to NULL. A compaction step drops the NULLs
#     so only parameters the caller actually set are transmitted.
#   * Constructor helpers (wb_job, wb_launch_parameters, wb_resource_limit,
#     wb_env) build the nested objects that launch_* methods expect, and force
#     the correct JSON array/scalar shapes.
#
# Dependencies: httr2 (>= 1.0.0). jsonlite is pulled in by httr2.
#
# Quick start
# -----------
#   Sys.setenv(PWB_BASE_URL = "https://pwb.demo.soleng.posit.it")
#   Sys.setenv(PWB_API_TOKEN = "<your-32-char-token>")
#   source("workbench_api.R")
#   wb_version()
#   wb_get_session()
# =============================================================================

library(httr2)

# NULL-coalescing operator (base R has this from 4.4.0; define for older R too)
if (!exists("%||%")) {
  `%||%` <- function(a, b) if (is.null(a)) b else a
}

# ---- configuration ----------------------------------------------------------

#' Build a Workbench API config (base URL + token).
#'
#' Reads PWB_BASE_URL and PWB_API_TOKEN from the environment by default so you
#' never hard-code a token in a script. Pass verify_ssl = FALSE only for demo
#' boxes with self-signed certs.
wb_config <- function(base_url   = Sys.getenv("PWB_BASE_URL"),
                      token      = Sys.getenv("PWB_API_TOKEN"),
                      verify_ssl = TRUE) {
  if (!nzchar(base_url)) {
    stop("No base_url. Set PWB_BASE_URL or pass base_url=.", call. = FALSE)
  }
  if (!nzchar(token)) {
    stop("No API token. Set PWB_API_TOKEN or pass token=.", call. = FALSE)
  }
  structure(
    list(
      base_url   = sub("/+$", "", base_url),  # strip trailing slash
      token      = token,
      verify_ssl = isTRUE(verify_ssl)
    ),
    class = "wb_config"
  )
}

# ---- internal helpers -------------------------------------------------------

# Drop NULL entries: this is what makes optional-parameter handling consistent.
.wb_compact <- function(x) x[!vapply(x, is.null, logical(1))]

# Several *_id / *_ids params want a comma-separated STRING. Accept an R vector
# (or an already-joined string) and normalize to the string the API expects.
.wb_join_ids <- function(x) {
  if (is.null(x)) return(NULL)
  paste(x, collapse = ",")
}

# Force a value to serialize as a JSON ARRAY even when length 1. jsonlite's
# auto_unbox would otherwise turn c("id") into the scalar "id" instead of ["id"].
.wb_as_array <- function(x) {
  if (is.null(x)) return(NULL)
  as.list(x)
}

# Extract the most useful message from a Workbench error payload. The API nests
# the real reason: the top level says "Error occurred while executing method",
# while the launcher's actual complaint (e.g. "Invalid resource profile for
# user") lives in error$error$message and/or error$properties$details. This
# walks the chain and returns the deepest, most specific text.
.wb_error_message <- function(parsed) {
  if (is.null(parsed) || is.null(parsed$error)) return(NULL)
  msgs <- character(0)
  e <- parsed$error
  repeat {
    if (!is.null(e$message)) msgs <- c(msgs, e$message)
    if (!is.null(e$error) && is.list(e$error)) e <- e$error else break
  }
  det <- parsed$error$properties$details
  if (!is.null(det)) msgs <- c(msgs, det)
  msgs <- unique(msgs[nzchar(msgs)])
  if (length(msgs)) paste(msgs, collapse = " | ") else NULL
}

# ---- transport core ---------------------------------------------------------

# Build (but do not perform) the request. Shared by the standard and streaming
# performers so auth / TLS / URL logic lives in exactly one place.
.wb_build_req <- function(method, kwparams, http, cfg, timeout) {
  req <- request(cfg$base_url) |>
    req_url_path_append("api", method) |>
    req_headers(Authorization = paste("Bearer", cfg$token)) |>
    req_timeout(timeout) |>
    req_error(is_error = function(resp) FALSE)  # we inspect status ourselves

  if (!cfg$verify_ssl) {
    req <- req_options(req, ssl_verifypeer = 0L, ssl_verifyhost = 0L)
  }

  if (identical(http, "POST")) {
    body <- list(method = method)
    if (!is.null(kwparams) && length(kwparams) > 0) body$kwparams <- kwparams
    req <- req_body_json(req, body, auto_unbox = TRUE)
  }
  req
}

# Perform a standard (non-streaming) call and normalize the result.
#   raw = FALSE (default) unwraps the top-level `result` object.
.wb_perform <- function(method,
                        kwparams = NULL,
                        http     = c("POST", "GET"),
                        cfg      = wb_config(),
                        raw      = FALSE,
                        timeout  = 60) {
  http <- match.arg(http)
  stopifnot(inherits(cfg, "wb_config"))

  resp   <- req_perform(.wb_build_req(method, kwparams, http, cfg, timeout))
  status <- resp_status(resp)
  parsed <- tryCatch(resp_body_json(resp, simplifyVector = FALSE),
                     error = function(e) NULL)

  # Level 1: HTTP errors (401 permission denied, 50x server, proxy 40x/50x).
  if (status >= 400) {
    msg <- .wb_error_message(parsed) %||%
      tryCatch(resp_body_string(resp), error = function(e) "")
    stop(sprintf("Workbench API HTTP %d on '%s': %s",
                 status, method, if (nzchar(msg)) msg else "(no body)"),
         call. = FALSE)
  }

  # Level 2: JSON-RPC error (HTTP 200 with an {error:{code,message}} payload).
  if (!is.null(parsed) && !is.null(parsed$error)) {
    stop(sprintf("Workbench API error on '%s' [code %s]: %s",
                 method, parsed$error$code %||% "?",
                 .wb_error_message(parsed) %||% "unknown"),
         call. = FALSE)
  }

  if (raw) return(parsed)
  if (!is.null(parsed) && !is.null(parsed$result)) parsed$result else parsed
}

# Perform a streaming call (get_job_output / get_audited_job_output).
# Collects the whole response, then:
#   * parses it as a single JSON object if possible (finished audited job), else
#   * splits newline-delimited JSON chunks (live streaming stdout/stderr).
# NOTE: for a live job this BLOCKS until the job exits or the timeout is hit.
# See the bottom of this file for a true incremental-streaming variant.
.wb_perform_stream <- function(method, kwparams, cfg = wb_config(),
                               timeout = 300) {
  stopifnot(inherits(cfg, "wb_config"))
  resp <- req_perform(.wb_build_req(method, kwparams, "POST", cfg, timeout))
  if (resp_status(resp) >= 400) {
    stop(sprintf("Workbench API HTTP %d on '%s'", resp_status(resp), method),
         call. = FALSE)
  }
  txt <- resp_body_string(resp)

  whole <- tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE),
                    error = function(e) NULL)
  if (!is.null(whole)) return(whole)

  lines <- Filter(nzchar, trimws(strsplit(txt, "\n", fixed = TRUE)[[1]]))
  lapply(lines, function(l)
    tryCatch(jsonlite::fromJSON(l, simplifyVector = FALSE),
             error = function(e) l))
}

# Escape hatch: call any method by name (handy if Posit adds new ones).
wb_call <- function(method, kwparams = NULL, http = "POST",
                    cfg = wb_config(), raw = FALSE) {
  .wb_perform(method, kwparams, http, cfg, raw = raw)
}

# ---- constructor helpers for nested objects ---------------------------------

#' A ResourceLimit object (memory / cpu / gpus).
wb_resource_limit <- function(type, value, max_value = NULL,
                              default_value = NULL) {
  .wb_compact(list(
    type          = type,
    value         = as.character(value),
    max_value     = max_value,
    default_value = default_value
  ))
}

#' An EnvironmentVariable object.
wb_env <- function(name, value) list(name = name, value = as.character(value))

#' LaunchParameters for launcher-backed sessions.
#' resource_limits should be a LIST of wb_resource_limit() objects.
wb_launch_parameters <- function(name, cluster,
                                 container_image       = NULL,
                                 resource_limits       = NULL,
                                 queues                = NULL,
                                 placement_constraints = NULL,
                                 resource_profile      = NULL,
                                 ...) {
  .wb_compact(c(list(
    name                  = name,
    cluster               = cluster,
    container_image       = container_image,
    resource_limits       = resource_limits,
    queues                = .wb_as_array(queues),
    placement_constraints = placement_constraints,
    resource_profile      = resource_profile
  ), list(...)))
}

#' A WorkbenchJob object for launch_job / launch_audited_job.
#' Provide EITHER exe (+ args) OR command. args/tags/queues are forced to arrays.
#'
#' IMPORTANT — resource_profile casing: the R arg is snake_case for a natural
#' interface, but it is serialized on the wire as `resourceProfile` (camelCase),
#' which is what the launcher actually reads. The documented snake_case input key
#' is SILENTLY DROPPED: the job then falls through to the "custom" profile, which
#' is rejected on any box with allow-custom-resources=0, surfacing as the
#' misleading "Invalid resource profile for user". Name a valid profile here
#' (e.g. "default"/"small"/"medium"/"large" — see wb_get_compute_envs()).
#'
#' Also note: on hosts where R is not on the default PATH (jobs run via
#' /bin/sh -c), give `exe` a FULL path, e.g. "/opt/R/4.6.1/bin/Rscript".
wb_job <- function(name, cluster = "Local",
                   exe                   = NULL,
                   command               = NULL,
                   args                  = NULL,
                   working_directory     = NULL,
                   environment           = NULL,
                   tags                  = NULL,
                   container_image       = NULL,
                   resource_profile      = NULL,
                   resource_limits       = NULL,
                   queues                = NULL,
                   placement_constraints = NULL,
                   user                  = NULL) {
  .wb_compact(list(
    name                  = name,
    cluster               = cluster,
    exe                   = exe,
    command               = command,
    args                  = .wb_as_array(args),
    working_directory     = working_directory,
    environment           = environment,
    tags                  = .wb_as_array(tags),
    container_image       = container_image,
    resourceProfile       = resource_profile,   # camelCase key is intentional
    resource_limits       = resource_limits,
    queues                = .wb_as_array(queues),
    placement_constraints = placement_constraints,
    user                  = user
  ))
}

# =============================================================================
# The 15 API methods
# =============================================================================

# --- launch -----------------------------------------------------------------

#' 1. launch_session — start a session (super-admin token to impersonate).
wb_launch_session <- function(workbench,
                              username          = NULL,
                              name              = NULL,
                              project_id        = NULL,
                              open_file         = NULL,
                              working_directory = NULL,
                              launch_parameters = NULL,
                              start_hooks       = NULL,
                              stop_hooks        = NULL,
                              environment       = NULL,
                              cfg               = wb_config()) {
  kw <- .wb_compact(list(
    workbench         = workbench,
    username          = username,
    name              = name,
    project_id        = project_id,
    open_file         = open_file,
    working_directory = working_directory,
    launch_parameters = launch_parameters,
    start_hooks       = start_hooks,
    stop_hooks        = stop_hooks,
    environment       = environment
  ))
  .wb_perform("launch_session", kw, "POST", cfg)
}

#' 2. launch_job — start a Workbench job. `job` = wb_job(...).
wb_launch_job <- function(job, apply_config_settings = NULL,
                          cfg = wb_config()) {
  kw <- .wb_compact(list(job = job,
                         apply_config_settings = apply_config_settings))
  .wb_perform("launch_job", kw, "POST", cfg)
}

#' 3. launch_audited_job — start an audited job. `audited_job` = wb_job(...).
wb_launch_audited_job <- function(audited_job, apply_config_settings = NULL,
                                  cfg = wb_config()) {
  kw <- .wb_compact(list(audited_job = audited_job,
                         apply_config_settings = apply_config_settings))
  .wb_perform("launch_audited_job", kw, "POST", cfg)
}

# --- query ------------------------------------------------------------------

#' 4. get_session — active sessions/jobs. No args => all your sessions.
#' `session_id` and `fields` accept vectors. `timestamp` enables long-polling
#' (server waits up to ~30s for a change), so the timeout is bumped accordingly.
wb_get_session <- function(session_id       = NULL,
                           user             = NULL,
                           fields           = NULL,
                           timestamp        = NULL,
                           include_projects = NULL,
                           include_jobs     = NULL,
                           include_all_jobs = NULL,
                           cfg              = wb_config()) {
  kw <- .wb_compact(list(
    session_id       = .wb_join_ids(session_id),
    user             = user,
    fields           = .wb_as_array(fields),
    timestamp        = timestamp,
    include_projects = include_projects,
    include_jobs     = include_jobs,
    include_all_jobs = include_all_jobs
  ))
  .wb_perform("get_session", kw, "POST", cfg,
              timeout = if (!is.null(timestamp)) 35 else 60)
}

#' 5. get_historical_session — sessions that have ended (admin token for others).
#' Times are ISO-8601 strings, e.g. "2025-07-23T00:00:00.000000Z".
wb_get_historical_session <- function(filter_time_begin = NULL,
                                      filter_time_end   = NULL,
                                      include_jobs      = NULL,
                                      include_all_users = NULL,
                                      cfg               = wb_config()) {
  kw <- .wb_compact(list(
    filter_time_begin = filter_time_begin,
    filter_time_end   = filter_time_end,
    include_jobs      = include_jobs,
    include_all_users = include_all_users
  ))
  .wb_perform("get_historical_session", kw, "POST", cfg)
}

#' 6. resume_session — resume a suspended RStudio Pro session.
wb_resume_session <- function(session_id,
                              username          = NULL,
                              launch_parameters = NULL,
                              cfg               = wb_config()) {
  kw <- .wb_compact(list(
    session_id        = session_id,
    username          = username,
    launch_parameters = launch_parameters
  ))
  .wb_perform("resume_session", kw, "POST", cfg)
}

#' 7. get_compute_envs — supported clusters/IDEs. GET normally; POST if `user`
#' is supplied (requires admin/super-admin read access).
wb_get_compute_envs <- function(user = NULL, cfg = wb_config()) {
  if (is.null(user)) {
    .wb_perform("get_compute_envs", NULL, "GET", cfg)
  } else {
    .wb_perform("get_compute_envs", list(user = user), "POST", cfg)
  }
}

#' 8. get_job_output — stdout/stderr for a job. Streams (blocks) for live jobs.
wb_get_job_output <- function(job_id, user = NULL, cfg = wb_config(),
                              timeout = 300) {
  kw <- .wb_compact(list(job_id = job_id, user = user))
  .wb_perform_stream("get_job_output", kw, cfg, timeout)
}

#' 9. get_audited_job_output — output for an audited job (single object if
#' finished, streamed chunks if live).
wb_get_audited_job_output <- function(audited_job_id, user = NULL,
                                      cfg = wb_config(), timeout = 300) {
  kw <- .wb_compact(list(audited_job_id = audited_job_id, user = user))
  .wb_perform_stream("get_audited_job_output", kw, cfg, timeout)
}

#' 10. get_audited_job_details — audit details (completed audited jobs only).
wb_get_audited_job_details <- function(audited_job_id, user = NULL,
                                       cfg = wb_config()) {
  kw <- .wb_compact(list(audited_job_id = audited_job_id, user = user))
  .wb_perform("get_audited_job_details", kw, "POST", cfg)
}

# --- stop -------------------------------------------------------------------

#' 11. stop_session — stop/suspend/force-quit one or more sessions.
#' `session_ids` accepts a vector; it is comma-joined for you.
wb_stop_session <- function(session_ids,
                            force_quit = NULL,
                            suspend    = NULL,
                            cfg        = wb_config()) {
  kw <- .wb_compact(list(
    session_ids = .wb_join_ids(session_ids),
    force_quit  = force_quit,
    suspend     = suspend
  ))
  .wb_perform("stop_session", kw, "POST", cfg)
}

#' 12. stop_job — stop a single job.
wb_stop_job <- function(job_id, force_quit = NULL, cfg = wb_config()) {
  kw <- .wb_compact(list(job_id = job_id, force_quit = force_quit))
  .wb_perform("stop_job", kw, "POST", cfg)
}

#' 13. stop_audited_job — stop a single audited job.
wb_stop_audited_job <- function(audited_job_id, force_quit = NULL,
                                cfg = wb_config()) {
  kw <- .wb_compact(list(audited_job_id = audited_job_id,
                         force_quit = force_quit))
  .wb_perform("stop_audited_job", kw, "POST", cfg)
}

# --- info -------------------------------------------------------------------

#' 14. version — server version + enabled features. GET, good connectivity test.
wb_version <- function(cfg = wb_config()) {
  .wb_perform("version", NULL, "GET", cfg)
}

#' 15. get_users — registered users (admin/super-admin read access required).
wb_get_users <- function(cfg = wb_config()) {
  .wb_perform("get_users", NULL, "GET", cfg)
}

# =============================================================================
# Usage examples (kept as comments so sourcing this file has no side effects)
# =============================================================================
#
# Sys.setenv(PWB_BASE_URL  = "https://pwb.demo.soleng.posit.it")
# Sys.setenv(PWB_API_TOKEN = "your-32-char-token")
# source("workbench_api.R")
#
# ## Reuse one config (e.g. to disable TLS verify on a self-signed demo box):
# cfg <- wb_config(verify_ssl = FALSE)
# wb_version(cfg)
# wb_get_session(cfg = cfg)
#
# ## Filter fields and include jobs:
# wb_get_session(fields = c("id", "url", "activity_state"), include_jobs = TRUE)
#
# ## Launch an RStudio session with a memory limit:
# wb_launch_session(
#   workbench = "RStudio",
#   name = "API session",
#   launch_parameters = wb_launch_parameters(
#     name = "API session", cluster = "Local",
#     resource_limits = list(wb_resource_limit("memory", 4096))
#   )
# )
#
# ## Launch a job and read its output:
# res <- wb_launch_job(wb_job(name = "test", exe = "R", args = c("-f", "job.R")))
# out <- wb_get_job_output(res$job$id)
#
# ## Stop sessions (vector auto-joined):
# wb_stop_session(c("acdd5861", "6124d41f"), suspend = TRUE)
#
# =============================================================================
# Note: true incremental streaming for get_job_output
# -----------------------------------------------------------------------------
# .wb_perform_stream collects the whole response before returning, which is fine
# for finished jobs but blocks for live ones. To process chunks as they arrive,
# use req_perform_connection() and read line by line:
#
#   con <- req_perform_connection(
#     .wb_build_req("get_job_output",
#                   list(job_id = "..."), "POST", wb_config(), timeout = 600)
#   )
#   repeat {
#     line <- readLines(con, n = 1L)
#     if (length(line) == 0) break
#     if (nzchar(line)) {
#       chunk <- jsonlite::fromJSON(line, simplifyVector = FALSE)
#       cat(chunk$output)          # do something with each chunk
#     }
#   }
#   close(con)
# =============================================================================
