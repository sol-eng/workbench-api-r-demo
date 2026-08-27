source("workbench_api.R")


# PWB_BASE_URL / PWB_API_TOKEN come from your .Renviron

cfg <- wb_config()          # add verify_ssl = FALSE if the demo cert is self-signed
wb_version(cfg)             # confirms token + API-enabled before you launch anything

# Optional but useful: check a "Local" cluster exists to run the job on
wb_get_compute_envs(cfg = cfg)$clusters

res <- wb_launch_session(
  workbench = "RStudio", name = "test",
  launch_parameters = wb_launch_parameters(
    name = "test", cluster = "Local",
    resource_profile = "default"     # or small / medium / large
  ),
  cfg = cfg
)
res

job <- wb_job(
  name = "smoke-test",
  cluster = "Local",
  exe = "/opt/R/4.6.1/bin/Rscript",
  args = c("-e", "print(Sys.time())"),
  working_directory = "/home/samiul.haque",
  resource_profile = "default"
)
res <- wb_launch_job(job, cfg = cfg)
chunks <- wb_get_job_output(res$job$id, cfg = cfg)
