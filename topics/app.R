# app.R: the topics dashboard. Reads the four CSVs topics.qmd writes from
# outputs/ inside this folder. Set HOT_TOPIC_DATA to read them elsewhere.
#
# Stance is a separate app (../stance) with its own deployment, because it
# calls a language model on every run and holds its R process while it does.
# Nothing here calls a model.
#
# On Posit Connect, publish app.R and R/ and outputs/; inputs/ and the .qmd
# files are not needed to serve the app.

library(shiny)
options(bitmapType = "cairo")  # the work server has no X11
purrr::walk(list.files("R", pattern = "\\.R$", full.names = TRUE), source)

data_dir <- Sys.getenv("HOT_TOPIC_DATA", "outputs")
hd <- load_outputs(data_dir)  # read once per R process, shared by all sessions

# The classification banner is the first element so it sits above the
# navigation on every tab. Set the marking with
# options(drsvyr.classification = "YOUR MARKING") before starting the app, and
# describe the text for the Start here tab with
# options(hot_topic.source = "public comments submitted to ...").
ui <- bslib::page(
  title = "hot_topic",
  theme = bslib::bs_theme(version = 5, bootswatch = "flatly"),
  classification_banner(),
  bslib::navset_bar(
    title = "hot_topic", id = "nav",
    bslib::nav_panel("Start here", help_ui(hd)),
    bslib::nav_panel("Topics", mod_topics_ui("topics", hd)),
    bslib::nav_panel("Read", mod_read_ui("read", hd))))

server <- function(input, output, session) {
  help_server(input, output, hd)
  mod_topics_server("topics", hd)
  mod_read_server("read", hd)
}

shinyApp(ui, server)
