# =============================================================================
# example.R — end-to-end walkthrough of the Workbench API wrapper
# -----------------------------------------------------------------------------
# Runs top to bottom: connect -> inspect -> launch a job -> read output ->
# launch a session -> stop it. Each step prints what it's doing.
#
# Prereqs:
#   * install.packages("httr2")
#   * PWB_BASE_URL and PWB_API_TOKEN set (e.g. in .Renviron) — see README.
#   * Adjust the CONFIG block below for your box (username, R path, profile).
# =============================================================================

source("workbench_api.R")

# ---- CONFIG: edit these for your server -------------------------------------

USERNAME      <- Sys.getenv("USER", "your.username")   # your Workbench username
R_BIN         <- "/opt/R/4.6.1/bin/Rscript"            # full path; see `ls /opt/R`
RESOURCE_PROF <- "default"                              # a valid profile name
VERIFY_SSL    <- TRUE                                   # FALSE for self-signed demo certs

# -----------------------------------------------------------------------------

cfg <- wb_config(verify_ssl = VERIFY_SSL)

say <- function(...) cat("\n== ", sprintf(...), " ==\n", sep = "")

# ---- 1. Connectivity + auth -------------------------------------------------
say("1. Version / smoke test")
v <- wb_version(cfg)
cat("Server version:", v$version$release_name %||% "?", "\n")
cat("Enabled features:", paste(unlist(v$features), collapse = ", "), "\n")

# ---- 2. What can this box run? ----------------------------------------------
say("2. Compute environments (clusters + resource profiles)")
ce <- wb_get_compute_envs(cfg = cfg)
clusters <- vapply(ce$clusters, function(c) c$name %||% NA_character_, character(1))
cat("Clusters:", paste(clusters, collapse = ", "), "\n")

profiles <- vapply(ce$clusters[[1]]$resourceProfiles,
                   function(p) p$name %||% NA_character_, character(1))
cat("Resource profiles on", clusters[1], ":", paste(profiles, collapse = ", "), "\n")

if (!RESOURCE_PROF %in% profiles) {
  warning(sprintf("RESOURCE_PROF '%s' not in the profile list above; edit CONFIG.",
                  RESOURCE_PROF))
}

# ---- 3. Current active sessions ---------------------------------------------
say("3. Your active sessions")
sess <- wb_get_session(cfg = cfg)$sessions
if (length(sess)) {
  for (s in sess) cat(sprintf("  %-10s %-20s %s\n",
                              s$id %||% "?",
                              s$display_name %||% s$label %||% "?",
                              s$activity_state %||% "?"))
} else {
  cat("  (none)\n")
}

# ---- 4. Launch a job and read its output ------------------------------------
# Note the two things that trip everyone up (see README "Gotchas"):
#   * exe is a FULL path (R is not on PATH for /bin/sh -c jobs)
#   * resource_profile is required and is sent as camelCase for you
say("4. Launch a job")
job <- wb_job(
  name              = "smoke-test",
  cluster           = clusters[1],
  exe               = R_BIN,
  args              = c("-e", "cat('Hello from Workbench\\n'); print(Sys.time())"),
  working_directory = file.path("/home", USERNAME),
  resource_profile  = RESOURCE_PROF
)

res    <- wb_launch_job(job, cfg = cfg)
job_id <- res$result$job$id %||% res$job$id
cat("Launched job id:", job_id, "\n")

say("5. Job output")
# wb_get_job_output blocks until the job exits (a Sys.time() print is instant).
chunks <- wb_get_job_output(job_id, cfg = cfg)
for (c in chunks) if (is.list(c) && !is.null(c$output)) cat(c$output)

# ---- 6. Launch and stop a session -------------------------------------------
say("6. Launch an RStudio session")
sres <- wb_launch_session(
  workbench         = "RStudio",
  name              = "api-example",
  launch_parameters = wb_launch_parameters(
    name = "api-example", cluster = clusters[1],
    resource_profile = RESOURCE_PROF
  ),
  cfg = cfg
)
sid <- sres$result$id %||% sres$id
cat("Session id:", sid, " url:", sres$result$url %||% sres$url, "\n")

say("7. Stop the session")
wb_stop_session(sid, cfg = cfg)   # returns NULL on success (empty 200 body)
cat("Stop requested for", sid, "\n")

# Confirm it's gone from the active list
remaining <- wb_get_session(cfg = cfg)$sessions
still_there <- any(vapply(remaining, function(s) identical(s$id, sid), logical(1)))
cat("Session still active:", still_there, "\n")

say("Done")
