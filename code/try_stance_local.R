# try_stance_local.R: THROWAWAY. Stands in for the work Gemma endpoint at
# home by calling Gemma 4 on OpenRouter, the same provider topics.qmd uses.
# Delete this file (with llm_openrouter.R) before going to work; nothing
# else depends on it.
#
# Run it line by line from the repo root (open hot_topic in RStudio first).
# It sets STANCE_URL / STANCE_MODEL / STANCE_KEY for this R session only,
# checks one paragraph, times twenty, then starts the app, which inherits the
# settings because it runs in the same session.

source(here::here("code", "llm_openrouter.R"))  # model names and the home key
Sys.setenv(STANCE_URL = "https://openrouter.ai/api/v1",
           STANCE_MODEL = sub("^openrouter/", "", open_router_models[["stance"]]),
           STANCE_KEY = Sys.getenv("OPENROUTER_API_KEY"))

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x
source(here::here("app", "R", "stance_core.R"))
ep <- stance_endpoint()
paras <- readr::read_csv(here::here("app", "outputs", "paragraph_theta.csv"),
                         show_col_types = FALSE)
claim <- "The United States should take an active role in the affairs of other nations."

# 1. One paragraph. A label means the endpoint, model name, and key all work;
#    otherwise the attached error says which one failed.
one <- code_one(paras$text[1], stance_prompt(claim), ep)
one

# 2. Twenty paragraphs, timed, to estimate a full run.
t <- system.time(lab <- code_all(paras$text[1:20], claim, ep))
table(lab, useNA = "ifany")
message(sprintf("%.1f s per paragraph; the full corpus (%d) would take about %.0f minutes.",
                t[["elapsed"]] / 20, nrow(paras), t[["elapsed"]] / 20 * nrow(paras) / 60))

# 3. The app. Open the Stance tab, paste a claim, and run it.
shiny::runApp(here::here("app"))
