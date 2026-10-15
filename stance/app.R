# app.R: the stance detector. A user uploads a CSV of short text passages,
# writes a claim, and every passage is labeled by the model set below.
# Nothing is written to the server's disk and
# nothing is read from outputs/: the app works entirely on what the user
# uploads.
#
# On Posit Connect:
#   - set "Max connections per process" to 1, because a run holds the R process
#   - publish app.R and R/ only; inputs/ and outputs/ are not needed

library(shiny)
options(bitmapType = "cairo")  # the work server has no X11
options(shiny.maxRequestSize = 500 * 1024^2)  # uploads up to 500 MB

# The model every passage is sent to. The key stays NULL: the work server needs
# none, and a key is never typed here. Where one is needed (at home), NULL
# reads STANCE_KEY from .Renviron instead.
options(stance.url = "http://localhost:11434/v1",
        stance.model = "gemma4:12b-it-qat",   # exactly as `ollama list` prints it
        stance.key = NULL)

# Requests sent to the model at the same time. These are open connections to
# the model server, not R cores: R waits while the server works. Set it to
# what the server can serve at once (4 at work); 1 sends them one by one.
options(stance.workers = 4L)

# Seconds the server takes per passage, measured one at a time (about 6,000
# in ten minutes at work). Only used for the time estimate shown before a run.
options(stance.sec_per_passage = 0.1)

# Other deployment settings, set here if needed:
#   options(drsvyr.classification = "YOUR MARKING")   the banner on every page
#   options(stance.tested = "...")   what the endpoint has been run on
#   options(stance.docs = "...")     where the method report lives

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
