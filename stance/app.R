# app.R: the stance detector. A user pastes their API key, checks the
# connection, uploads a CSV of short text passages, and writes a claim.
#
# Every chat model allows 300 requests per 4 hours, each on its own count, so
# the app spends them carefully:
#   - an embedding model (no limit) sorts the passages by closeness to the claim
#   - the labeling model reads a random sample from every group, several
#     passages to a request, and the sample is weighted up to the whole file
#   - helper models read the same passages and more; the labeling model's
#     sample measures and corrects their error, which narrows the intervals
#   - the user sends a few requests at a time and adds more until the intervals
#     are narrow enough, today or on another day
# Nothing is written to the server's disk: results leave through the downloads,
# and the downloaded file with labels is what a later visit adds to.
#
# The base URL and the model IDs are fixed here and nowhere else; the user
# supplies only the key, which serves all of them. The key lives in that user's
# session: never saved, never in an environment variable, never in a result,
# and the app reads no key from the server. A run stays locked until Check
# connection has passed with that key.
#
# On Posit Connect:
#   - set "Max connections per process" to 1, because a run holds the R process
#   - publish app.R, R/stance_core.R, R/stance_app.R, and logo/

library(shiny)
options(bitmapType = "cairo")  # the work server has no X11
options(shiny.maxRequestSize = 500 * 1024^2)  # uploads up to 500 MB
source("R/stance_core.R")  # the method: prompt, sample, requests, estimates
source("R/stance_app.R")   # the pages

# ---- the models ----------------------------------------------------------------
# Paste the base URL (an OpenAI-compatible endpoint, ending in /v1) and the model
# IDs; the app will not start while a placeholder is left. chat_model() takes
# the ID and the request settings that model needs: Claude models take no
# temperature and need thinking switched off; open models take temperature 0.
# helpers = list() runs with the labeling model alone.
options(
  stance.base_url = "https://YOUR-ENDPOINT/v1",
  stance.models = stance_models(
    embed = "EMBED-ID",
    label = chat_model("SONNET-ID", thinking = list(type = "disabled")),
    helpers = list(
      chat_model("OPUS-ID", thinking = list(type = "disabled")),
      chat_model("GEMMA-ID", temperature = 0, reasoning_effort = "none"),
      chat_model("LLAMA-ID", temperature = 0))),
  stance.batch = 30,        # requests offered per model per round (of 300 per 4 hours)
  stance.per_request = 10,  # passages to a request; 1 sends each passage alone
  stance.solo_n = 10,       # passages per round the labeling model also reads alone, as a check
  stance.workers = 4)       # requests sent at once
if (any(grepl("YOUR-|^[A-Z0-9]+-ID$", c(
  getOption("stance.base_url"), getOption("stance.models")$embed$model,
  purrr::map_chr(chat_models(getOption("stance.models")), "model")))))
  stop("Paste the base URL and the model IDs into app.R.", call. = FALSE)

# ---- the banner and the logo ---------------------------------------------------
# The marking and the logo are fixed for this app. The logo is logo/office_logo.png;
# until that file exists, a dashed box shows where it goes.
addResourcePath("logo", "logo")
banner <- tags$div(
  style = paste("background:#b40404; color:#fff; text-align:center; font-weight:700;",
                "letter-spacing:0.06em; padding:5px 0; font-size:13px;"),
  "UNCLASSIFIED")
logo <- tags$div(
  style = "padding:8px 16px; border-bottom:1px solid #dee2e6;",
  if (file.exists("logo/office_logo.png"))
    tags$img(src = "logo/office_logo.png", alt = "Office logo", style = "height:48px;") else
    tags$div(style = paste("height:48px; width:160px; border:2px dashed #adb5bd;",
                           "border-radius:4px; color:#6c757d; font-size:12px; display:flex;",
                           "align-items:center; justify-content:center;"),
             "Office logo"))

ui <- bslib::page(
  title = "stance",
  theme = bslib::bs_theme(version = 5, bootswatch = "flatly"),
  banner,
  logo,
  bslib::navset_bar(
    title = "stance", id = "nav",
    bslib::nav_panel("Start here", stance_help_ui()),
    bslib::nav_panel("Detect stance", mod_stance_ui("stance")),
    bslib::nav_panel("Check the labels", mod_stance_check_ui("stance"))))

server <- function(input, output, session) {
  mod_stance_server("stance")
}

shinyApp(ui, server)
