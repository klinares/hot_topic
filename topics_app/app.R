# app.R: the topics dashboard. It reads the four CSVs that topics.qmd writes
# from outputs/ and never refits anything or calls a model.
#
# On Posit Connect, publish app.R, R/, outputs/, and www/.

library(shiny)
options(bitmapType = "cairo")  # the work server has no X11

# ---- deployment settings -----------------------------------------------------
options(
  drsvyr.classification = "UNCLASSIFIED",            # the banner on every page
  hot_topic.logo = "logo.png",                       # in www/; a placeholder until it exists
  hot_topic.office = "",                             # office name beside the logo, if wanted
  hot_topic.source = "public comments",              # what the text is, in a phrase
  hot_topic.unit = c("comment", "comments"),         # one document, and many
  hot_topic.stance_app = "")                         # URL of the stance app, if deployed

purrr::walk(list.files("R", pattern = "\\.R$", full.names = TRUE), source)

# read once per R process, shared by every session; HOT_TOPIC_DATA points
# elsewhere if the CSVs are not in outputs/
hd <- load_outputs(Sys.getenv("HOT_TOPIC_DATA", "outputs"))

ui <- bslib::page(
  title = "Topics",
  theme = bslib::bs_theme(version = 5, bootswatch = "flatly"),
  classification_banner(),
  office_logo(),
  bslib::navset_bar(
    title = "Topics", id = "nav",
    bslib::nav_panel("Start here", help_ui(hd)),
    bslib::nav_panel("Topics", mod_topics_ui("topics", hd)),
    bslib::nav_panel("Read", mod_read_ui("read", hd))))

server <- function(input, output, session) {
  help_server(input, output, hd)
  mod_topics_server("topics", hd)
  mod_read_server("read", hd)
}

shinyApp(ui, server)
