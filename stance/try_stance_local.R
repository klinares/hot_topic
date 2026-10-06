# try_stance_local.R: THROWAWAY. Stands in for the work Gemma endpoint at
# home by calling Gemma 4 on OpenRouter, the same provider topics.qmd uses.
# Delete this file before going to work; nothing else depends on it.
#
# Run it line by line from the repo root (open hot_topic in RStudio first).
# It sets STANCE_URL / STANCE_MODEL / STANCE_KEY for this R session only,
# checks one passage, times twenty, then starts the app, which inherits the
# settings because it runs in the same session.

Sys.setenv(STANCE_URL = "https://openrouter.ai/api/v1",
           STANCE_MODEL = "google/gemma-4-31b-it",
           STANCE_KEY = Sys.getenv("OPENROUTER_API_KEY"))

source(here::here("stance", "R", "stance_core.R"))
ep <- stance_endpoint()
claim <- "The United States should take an active role in the affairs of other nations."
prompt <- stance_prompt(claim, "paragraphs from public comments")

# A small file to code. Any CSV with a text column does; this is the topics
# project's paragraph file.
raw <- readr::read_csv(here::here("topics", "outputs", "paragraph_theta.csv"),
                       show_col_types = FALSE)
paras <- dplyr::filter(stance_prepare(raw, "text", "Year", "atom_id"), keep)

# 1. One passage. A label means the endpoint, model name, and key all work;
#    otherwise the attached error says which one failed.
one <- code_one(paras$text[1], prompt, ep)
one

# 2. Twenty passages, timed, to estimate a full run.
t <- system.time(lab <- code_all(paras$text[1:20], prompt, ep))
table(lab, useNA = "ifany")
message(sprintf("%.2f s per passage; all %d would take about %.0f minutes.",
                t[["elapsed"]] / 20, nrow(paras), t[["elapsed"]] / 20 * nrow(paras) / 60))

# 3. A whole estimate without the model, to check the shares, trends, plots,
#    and period rules on labels drawn at random.
fake <- dplyr::mutate(paras, label = withr::with_seed(1L, sample(
  stance_labels, dplyr::n(), replace = TRUE, prob = c(0.2, 0.15, 0.15, 0.5))))
stance_static(fake)
tr <- stance_trends(fake)
attr(tr, "notes")
stance_plot_salience(tr)
stance_plot_direction(tr)

# 4. The app. Upload a CSV on the Detect stance page and run a claim. The
#    STANCE_KEY above only reaches it because it is the same R session.
shiny::runApp(here::here("stance"))
