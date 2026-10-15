# ui_help.R: the Start here tab. What the method is and why it is used, how to
# use the tool, a picture of how the results were made, how to read the
# numbers, and a summary of the data behind this deployment.
#
# Deployment settings this page reads (set in app.R):
#   options(hot_topic.source = "...")      what the text is, in a phrase
#   options(hot_topic.unit = c("comment", "comments"))  one document, and many
#   options(hot_topic.stance_app = "...")  link to the stance app, if deployed
# The method reports are the PDFs that Quarto renders into reports/.

# bold text followed by punctuation, without the space HTML would put between
b_ <- function(x) tags$strong(x, .noWS = "after")

help_ui <- function(hd) {
  src <- getOption("hot_topic.source", "public comments")
  unit_names <- getOption("hot_topic.unit", c("comment", "comments"))
  one <- unit_names[1]; unit <- unit_names[2]
  stance_app <- getOption("hot_topic.stance_app", "")
  fmt <- function(x) format(x, big.mark = ",")
  p <- hd$paras
  n_docs <- dplyr::n_distinct(p$id)
  per_doc <- dplyr::count(p, id)$n
  top <- dplyr::slice_max(hd$topics, prevalence, n = 3)

  tagList(
    help_css(),
    bslib::layout_columns(
      col_widths = c(7, 5),
      bslib::card(
        bslib::card_header("What this tool shows"),
        tags$p(
          tags$strong("Topic modeling"), " finds the subjects a large body of text ",
          "is about, without anyone listing them in advance. This tool shows the ",
          "results of a ", b_("structural topic model"), " (STM) fitted to ",
          glue::glue("{fmt(nrow(p))} paragraphs from {fmt(n_docs)} {src}, "),
          glue::glue("{hd$years[1]} to {hd$years[2]}. "),
          "The model groups words that tend to appear together into ",
          glue::glue("{nrow(hd$topics)} topics, "),
          "measures how much of each paragraph belongs to each topic, and estimates ",
          "each topic's share of the text in every year, with a 95 percent interval."),
        tags$p(
          "It is needed because no one can read text at this scale, and the usual ",
          "shortcut, searching for keywords, only finds what the searcher already ",
          "expected. A topic model reads everything with the same rule, so it can ",
          "surface subjects nobody thought to look for, and it reports how much ",
          "attention each one received rather than whether it was mentioned at all. ",
          "Because year is part of the model, it can say when a subject rose or ",
          "faded and how sure that estimate is."),
        tags$p(
          "For our work, this gives a first, repeatable map of what people are ",
          "writing about: which subjects dominate, which are emerging, and where to ",
          "read closely. Each topic comes with a draft claim that the stance tool ",
          "can test, so a subject found here can be followed by where writers stand ",
          "on it. The results describe the text, not a population: a long ",
          glue::glue("{one} counts more than a short one, and the "),
          "labels are a person's reading of the model, so the paragraphs behind a ",
          "topic should be read before its trend is reported.")),
      bslib::card(
        bslib::card_header("How the results were made"),
        help_flowchart(one))),
    bslib::layout_columns(
      col_widths = c(7, 5),
      bslib::card(
        bslib::card_header("Using the tool"),
        tags$ol(
          tags$li("On ", b_("Topics"), ", pick a topic: its words, its draft ",
                  "label and description, its estimated share over time, the exact ",
                  "count of paragraphs assigned to it each year, and how all topics ",
                  "compare. The codebook at the bottom downloads as a CSV."),
          tags$li("On ", b_("Read"), ", read the paragraphs behind a topic. ",
                  "Filter by topic, years, how strongly a paragraph belongs to the ",
                  glue::glue("topic, or a word. Click a paragraph to open the whole "),
                  glue::glue("{one} it came from, in order."),
                  " Download the paragraphs shown, or the whole ",
                  glue::glue("{unit} they belong to.")),
          tags$li(tags$strong("Report"), " a trend only after reading a sample of its ",
                  "paragraphs, and quote the interval, not just the line."),
          tags$li(tags$strong("Measure stance"), " on a topic's draft claim with the ",
                  "stance tool: download the topic's paragraphs from Read, reword ",
                  "the claim if needed, and upload them there.",
                  if (nzchar(stance_app)) tagList(" ", tags$a(
                    href = stance_app, target = "_blank", "Open the stance app")))),
        tags$h6("Method reports"),
        help_reports(),
        tags$p(class = "small text-muted",
               "The app only reads saved results. Nothing is refitted or sent to a ",
               "model while you use it.")),
      bslib::card(
        class = "border-primary",
        bslib::card_header(class = "bg-primary text-white", "Reading the numbers"),
        tags$ul(class = "small",
          tags$li(tags$strong("Prevalence"), " is the model's estimate of the share of ",
                  "text about a topic, shown with a range of likely values. Paragraph ",
                  "counts are exact counts. The plots say which is which."),
          tags$li(tags$strong("Theta"), " is how much of a paragraph belongs to a topic, ",
                  "from 0 to 1. Each paragraph is placed in its highest topic, so one ",
                  "with theta 0.3 is only partly about it."),
          tags$li(tags$strong("AvePP"), " is the average theta of a topic's own ",
                  "paragraphs. Under about 0.7, the topic mixes subjects; read its ",
                  "paragraphs before relying on its trend."),
          tags$li(tags$strong("Labels are drafts."), " A language model proposed each ",
                  "label from the topic's words and paragraphs, and a person checked ",
                  "it. The words and paragraphs are the evidence; the label is a name."),
          tags$li(tags$strong("Ends of the range are less certain."), " A trend leans ",
                  "on neighboring years, least of all at the first and last year, and ",
                  "the band widens where few were written."),
          tags$li(tags$strong("Attention, not opinion."), " A rising topic means more ",
                  "is written about it, not that more people favor it. That is what ",
                  "the stance tool measures.")))),
    bslib::card(
      bslib::card_header("The data in this deployment"),
      bslib::layout_columns(
        bslib::value_box(tools::toTitleCase(unit), fmt(n_docs)),
        bslib::value_box("Paragraphs", fmt(nrow(p))),
        bslib::value_box("Years", paste(hd$years, collapse = " to ")),
        bslib::value_box("Topics", nrow(hd$topics))),
      bslib::layout_columns(
        col_widths = c(5, 7),
        tags$div(
          tags$table(
            class = "table table-sm",
            tags$tbody(
              tags$tr(tags$td(glue::glue("Paragraphs per {one} (median, range)")),
                      tags$td(glue::glue("{stats::median(per_doc)} ({min(per_doc)} to {max(per_doc)})"))),
              tags$tr(tags$td("Words per paragraph (median)"),
                      tags$td(stats::median(p$n_tokens))),
              tags$tr(tags$td("Largest topics"),
                      tags$td(paste(top$label, collapse = "; ")))))),
        tags$div(
          plotOutput("help_years", height = 200),
          tags$p(class = "text-muted small",
                 glue::glue("{tools::toTitleCase(unit)} per year. Years with few give less certain trends."))))))
}

help_server <- function(input, output, hd) {
  output$help_years <- renderPlot({
    hd$paras |>
      dplyr::distinct(id, Year) |>
      dplyr::count(Year) |>
      ggplot2::ggplot(ggplot2::aes(Year, n)) +
      ggplot2::geom_col(fill = viridisLite::viridis(1, begin = 0.35)) +
      ggplot2::labs(x = NULL, y = getOption("hot_topic.unit", c("comment", "comments"))[2]) +
      ggplot2::theme_minimal(base_size = 13)
  })
}

# One link per method report found in reports/, which app.R serves under the
# same path, so the links work wherever the app is deployed.
help_reports <- function() {
  reports <- c("topics.pdf" = "How topics and their trends were estimated",
               "preprocess.pdf" = "How the text was divided into paragraphs")
  have <- reports[file.exists(file.path("reports", names(reports)))]
  if (!length(have))
    return(tags$p(class = "small text-danger", "No method report found in reports/. Render preprocess.qmd and topics.qmd."))
  tags$ul(purrr::imap(have, function(txt, f)
    tags$li(tags$a(href = file.path("reports", f), target = "_blank", txt, " (PDF)"))))
}

# ---- the flowchart -----------------------------------------------------------
# Plain HTML boxes and arrows, so it needs no package and follows the theme.

help_step <- function(n, title, ..., dashed = FALSE)
  div(class = paste("tf-step", if (dashed) "tf-later"),
      div(class = "tf-num", n),
      div(tags$strong(title), div(class = "small text-muted", ...)))

help_arrow <- function() div(class = "tf-arrow", "↓")

help_flowchart <- function(one) {
  div(class = "tf",
    help_step(1, "The text", glue::glue("Every {one}, with its year.")),
    help_arrow(),
    help_step(2, "Paragraphs", "Each is divided into paragraphs, because one ",
              glue::glue("{one} often covers several subjects. Fragments are set aside.")),
    help_arrow(),
    help_step(3, "Words", "Lowercased; common words and very rare ones removed."),
    help_arrow(),
    help_step(4, "Topic model", "Finds the topics and each paragraph's share of each. ",
              "The number of topics is chosen by comparing fits."),
    help_arrow(),
    help_step(5, "Labels", "Drafted by a language model from each topic's words and ",
              "paragraphs, then checked and edited by a person."),
    help_arrow(),
    help_step(6, "Trends", "Each topic's share by year, with 95 percent intervals that ",
              "include the model's uncertainty."),
    help_arrow(),
    help_step(7, "This app", "Reads the saved results. Nothing is refitted.",
              dashed = TRUE))
}

help_css <- function() tags$style(HTML("
.tf { display: flex; flex-direction: column; }
.tf-step { display: flex; gap: .75rem; align-items: flex-start; padding: .5rem .75rem;
  border: 1px solid var(--bs-border-color); border-radius: .5rem;
  background: var(--bs-body-bg); }
.tf-later { border-style: dashed; }
.tf-num { flex: 0 0 1.6rem; height: 1.6rem; border-radius: 50%;
  background: var(--bs-primary); color: #fff; font-size: .8rem; font-weight: 600;
  display: flex; align-items: center; justify-content: center; margin-top: .1rem; }
.tf-later .tf-num { background: var(--bs-secondary); }
.tf-arrow { text-align: center; color: var(--bs-secondary-color); line-height: 1.1;
  font-size: 1.1rem; }
"))
