# app.R: the dashboard for this project's topics. It reads the CSVs that
# topics.qmd writes to outputs/ and the PDFs that Quarto renders to reports/,
# in this same folder, so nothing is copied. It never refits or calls a model.
#
# On Posit Connect, publish app.R, R/, reports/, logo/, and from outputs/ only
# paragraph_theta.csv, topic_codebook.csv, topic_summary.csv, topic_trends.csv.

library(shiny)
options(bitmapType = "cairo")  # the work server has no X11

# ---- deployment settings -----------------------------------------------------
options(
  drsvyr.classification = "UNCLASSIFIED",            # the banner on every page
  hot_topic.logo = "office_logo.png",                # in logo/; a placeholder until it exists
  hot_topic.office = "",                             # office name beside the logo, if wanted
  hot_topic.source = "public comments",              # what the text is, in a phrase
  hot_topic.unit = c("comment", "comments"),         # one document, and many
  hot_topic.stance_app = "")                         # URL of the stance app, if deployed

purrr::walk(list.files("R", pattern = "\\.R$", full.names = TRUE), source)

# Shiny serves only www/ by itself; these two folders are served by name.
addResourcePath("reports", "reports")
addResourcePath("logo", "logo")

hd <- load_outputs("outputs")  # read once per R process, shared by every session

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
