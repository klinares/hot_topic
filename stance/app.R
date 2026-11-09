# app.R: the stance detector. A user pastes their API key, checks the
# connection, uploads a CSV of short text passages, writes a claim, and every
# passage is labeled by Claude Opus. Nothing is written to the server's disk:
# the app works on what the user uploads, and results leave through the downloads.
#
# The base URL and model ID are fixed here and nowhere else; the user supplies
# only the key. The key lives in that user's session: never saved, never in an
# environment variable, never in a result, and the app reads no key from the
# server. A run stays locked until Check connection has passed with that key.
#
# On Posit Connect:
#   - set "Max connections per process" to 1, because a run holds the R process
#   - publish app.R, R/, and logo/

library(shiny)
options(bitmapType = "cairo")  # the work server has no X11
options(shiny.maxRequestSize = 500 * 1024^2)  # uploads up to 500 MB

# ---- the model -----------------------------------------------------------------
# Paste the base URL (ellmer's ends in /v1: https://api.anthropic.com/v1) and the
# model ID; the app will not start while a placeholder is left.
options(
  stance.base_url = "https://YOUR-ANTHROPIC-ENDPOINT/v1",
  stance.model = "OPUS-ID",
  stance.rpm = 300,     # requests allowed per minute; a run waits to stay under it
  stance.workers = 4)   # requests sent at once
if (any(grepl("YOUR-|^[A-Z0-9]+-ID$", c(getOption("stance.base_url"), getOption("stance.model")))))
  stop("Paste the base URL and model ID into app.R.", call. = FALSE)

purrr::walk(list.files("R", pattern = "\\.R$", full.names = TRUE), source)

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
