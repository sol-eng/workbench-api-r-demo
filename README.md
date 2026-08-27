# workbench-api-r

A thin, consistent R wrapper around the [Posit Workbench management API](https://docs.posit.co/ide/server-pro/admin/workbench_api/workbench_api.html) — the JSON-RPC-over-HTTPS interface that lets you launch and manage sessions and jobs programmatically. Covers all 15 documented methods.

Everything lives in one sourceable file, `workbench_api.R`. There is no package to install; `source()` it and go.

## Requirements

- R (>= 4.1 for the native `|>` pipe used internally)
- The [`httr2`](https://httr2.r-lib.org/) package (`jsonlite` comes along with it):
  ```r
  install.packages("httr2")
  ```
- A Workbench **API token** and the **base URL** of your server.

## Setup

### 1. Enable the API on the server (admin, one-time)

The Workbench API is **disabled by default**. An admin must add this to `rserver.conf` and restart:

```
workbench-api-enabled=1
```

Add `workbench-api-admin-enabled=1` and/or `workbench-api-super-admin-enabled=1` if you need admin-tier tokens (for querying other users, `get_users`, etc.).

### 2. Generate a token (admin)

```bash
rstudio-server generate-api-token user 'my-token' <username>
```

A `user` token can launch/stop/query **its own** sessions and jobs — enough for everything in the example. Admin/super-admin tokens are only needed to act on other users.

### 3. Point the wrapper at your server

The wrapper reads two environment variables. The cleanest way is a `.Renviron` file in your project root (R reads it automatically at startup — restart R after editing):

```
PWB_BASE_URL=https://pwb.example.posit.it
PWB_API_TOKEN=your-32-char-token
```

Format notes: no `export`, no spaces around `=`, no quotes. **Add `.Renviron` to `.gitignore`** — it holds a live token.

> Use the bare `https://host` form (port 443). Only use `:8787` when hitting the Workbench process directly on the box itself; behind a reverse proxy that port is usually firewalled.

## Quick start

```r
source("workbench_api.R")

cfg <- wb_config()          # reads PWB_BASE_URL / PWB_API_TOKEN
wb_version(cfg)             # connectivity + auth smoke test (GET, no params)
wb_get_session(cfg = cfg)   # your active sessions
```

If your demo box uses a self-signed certificate:

```r
cfg <- wb_config(verify_ssl = FALSE)
```

## The 15 methods

Each wrapper maps documented parameters to named R arguments. Every optional argument defaults to `NULL` and is dropped before sending, so you only ever transmit what you set.

| Function | API method | Notes |
|---|---|---|
| `wb_launch_session()` | `launch_session` | Start a session. |
| `wb_launch_job()` | `launch_job` | Start a job. Pass a `wb_job()`. |
| `wb_launch_audited_job()` | `launch_audited_job` | Pass a `wb_job()` as `audited_job`. |
| `wb_get_session()` | `get_session` | Active sessions/jobs. No args = all yours. |
| `wb_get_historical_session()` | `get_historical_session` | Ended sessions (ISO-8601 time filters). |
| `wb_resume_session()` | `resume_session` | Resume a suspended RStudio Pro session. |
| `wb_get_compute_envs()` | `get_compute_envs` | Clusters, IDEs, and **resource profiles**. |
| `wb_get_job_output()` | `get_job_output` | Streams stdout/stderr; blocks until job exits. |
| `wb_get_audited_job_output()` | `get_audited_job_output` | Output for an audited job. |
| `wb_get_audited_job_details()` | `get_audited_job_details` | Audit details (completed jobs). |
| `wb_stop_session()` | `stop_session` | Stop/suspend/force-quit. Accepts an id vector. |
| `wb_stop_job()` | `stop_job` | Stop a job. |
| `wb_stop_audited_job()` | `stop_audited_job` | Stop an audited job. |
| `wb_version()` | `version` | Version + enabled features. |
| `wb_get_users()` | `get_users` | Registered users (**admin token required**). |

Plus helpers for the nested objects: `wb_job()`, `wb_launch_parameters()`, `wb_resource_limit()`, `wb_env()`; a `wb_config()` constructor; and a `wb_call()` escape hatch for any method by name.

## Running a job

Jobs run via `/bin/sh -c`, which does **not** inherit your interactive shell's PATH, and they must name a valid **resource profile** on many servers. Both bite in practice — see Gotchas below. The reliable pattern:

```r
job <- wb_job(
  name              = "smoke-test",
  cluster           = "Local",
  exe               = "/opt/R/4.6.1/bin/Rscript",   # FULL path — R is often not on PATH
  args              = c("-e", "print(Sys.time())"),
  working_directory = "/home/<user>",
  resource_profile  = "default"                      # a name from wb_get_compute_envs()
)

res    <- wb_launch_job(job, cfg = cfg)
job_id <- res$result$job$id %||% res$job$id

# Read output (check both streams)
chunks <- wb_get_job_output(job_id, cfg = cfg)
for (c in chunks) if (is.list(c) && !is.null(c$output)) cat(c$output)
```

Find the R versions available on your box with `ls /opt/R` (they live under `/opt/R/<version>/bin/`), and the valid profile names with:

```r
wb_get_compute_envs(cfg = cfg)$clusters[[1]]$resourceProfiles
```

## Gotchas (learned the hard way)

These are the non-obvious things that will cost you an afternoon otherwise.

1. **`resource_profile` is sent as `resourceProfile` (camelCase).** The documented snake_case input key is silently dropped by the launcher; the job then defaults to the "custom" profile, which is rejected when `allow-custom-resources=0`, producing the misleading error **"Invalid resource profile for user"**. `wb_job(resource_profile = "default")` handles the casing for you — but if you build a job list by hand, use `resourceProfile`.

2. **R is often not on PATH for jobs.** `exe = "R"` or `"Rscript"` yields `/bin/sh: 1: R: not found`. Use a full path like `/opt/R/4.6.1/bin/Rscript`, or set `PATH` via the job's `environment`.

3. **The API is disabled by default.** A valid token still 401s until `workbench-api-enabled=1` is set server-side.

4. **`401` with an empty body usually means the token is missing/empty**, not wrong. In shell, `echo "[$TOKEN]"`; in R, check `nchar(cfg$token)`. Env vars don't survive a new terminal.

5. **Use port 443 (bare `https://host`), not `:8787`,** when the server sits behind a proxy.

6. **Error messages are nested.** The top-level message is always the generic "Error occurred while executing method"; the real reason is deeper. This wrapper digs out the deepest message automatically, so the R error shows the actual cause.

7. **`get_users` / querying other users need an admin token.** A plain `user` token correctly 401s on those — that's expected, not a bug.

## Files

- `workbench_api.R` — the wrapper (source this).
- `example.R` — a runnable, end-to-end walkthrough.
- `.Renviron.example` — copy to `.Renviron` and fill in.

## Disclaimer

Community utility, not an official Posit product. Endpoint behavior can vary by Workbench version and by server configuration (launcher plugin, resource profiles, PATH). When something is rejected, the launcher log on the node (`/var/log/rstudio/launcher/`) is the source of truth.
