# app.R: the stance detector. A user uploads a CSV of short text passages,
# writes a claim, and every passage is labeled by the model named in
# STANCE_URL / STANCE_MODEL, one request at a time. Nothing is written to the
# server's disk and nothing is read from outputs/: the app works entirely on
# what the user uploads.
#
# On Posit Connect:
#   - set STANCE_URL and STANCE_MODEL as environment variables
#   - set "Max connections per process" to 1, because a run holds the R process
#   - publish app.R and R/ only; inputs/ and outputs/ are not needed
# Deployment settings, set here or with options() before the app starts:
#   drsvyr.classification    the marking in the banner
#   stance.tested            what the endpoint has been run on
#   stance.docs              where the method report lives
#   stance.max_rows          largest file the app will code (default 10,000)
#   stance.sec_per_passage   measured seconds per passage (default 0.1)

library(shiny)
options(bitmapType = "cairo")  # the work server has no X11
options(shiny.maxRequestSize = 200 * 1024^2)  # uploads up to 200 MB
purrr::walk(list.files("R", pattern = "\\.R$", full.names = TRUE), source)

ui <- bslib::page(
  title = "stance",
  theme = bslib::bs_theme(version = 5, bootswatch = "flatly"),
  classification_banner(),
  bslib::navset_bar(
    title = "stance", id = "nav",
    bslib::nav_panel("Start here", stance_help_ui()),
    bslib::nav_panel("Detect stance", mod_stance_ui("stance")),
    bslib::nav_panel("Check the labels", mod_stance_check_ui("stance"))))

server <- function(input, output, session) {
  mod_stance_server("stance")
}

shinyApp(ui, server)
