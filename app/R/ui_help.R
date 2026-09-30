# ui_help.R: the Start here tab, written for a general audience.
# The source of the text is a deployment setting, like the classification
# marking: options(hot_topic.source = "public comments submitted to ...").

help_ui <- function(hd) {
  src <- getOption("hot_topic.source", "public comments")
  p <- hd$paras
  n_docs <- dplyr::n_distinct(p$atom_id)
  per_doc <- dplyr::count(p, atom_id)$n
  fmt <- function(x) format(x, big.mark = ",")
  top <- hd$topics |> dplyr::slice_max(prevalence, n = 3)
  tagList(
    bslib::card(
      bslib::card_header("About the data"),
      tags$p(glue::glue(
        "Methodologist examined text from {fmt(n_docs)} {src}, written between ",
        "{hd$years[1]} and {hd$years[2]}, and applied structural topic modeling ",
        "(STM), a statistical method that finds the subjects people write about by ",
        "looking at which words tend to appear together. Each comment was first ",
        "divided into paragraphs, because a single comment often covers several ",
        "subjects. Where writers put a line break after every sentence, neighboring ",
        "sentences on the same subject were joined back into paragraphs; ",
        "sentences too short to join anything were set aside. This produced ",
        "{fmt(nrow(p))} paragraphs, which the model sorted into {nrow(hd$topics)} ",
        "topics. It also estimated how much attention each topic received in each ",
        "year, which is what the trends on the Topics tab show.")),
      tags$p(glue::glue(
        "The three topics that take up the most text are ",
        "{paste0('\"', top$label, '\"', collapse = ', ')}. Topics are found by the ",
        "model, not chosen in advance; their names were drafted with help from a ",
        "language model and checked by a person.")),
      bslib::layout_columns(
        bslib::value_box("Comments", fmt(n_docs)),
        bslib::value_box("Paragraphs", fmt(nrow(p))),
        bslib::value_box("Years", paste(hd$years, collapse = " to ")),
        bslib::value_box("Topics", nrow(hd$topics))),
      tags$table(
        class = "table table-sm", style = "max-width:560px;",
        tags$tbody(
          tags$tr(tags$td("Paragraphs per comment (median, range)"),
                  tags$td(glue::glue("{stats::median(per_doc)} ({min(per_doc)} to {max(per_doc)})"))),
          tags$tr(tags$td("Words per paragraph (median)"),
                  tags$td(stats::median(p$n_tokens))),
          tags$tr(tags$td("Year with the most comments"),
                  tags$td(dplyr::count(dplyr::distinct(p, atom_id, Year), Year) |>
                            dplyr::slice_max(n, n = 1, with_ties = FALSE) |>
                            with(glue::glue("{Year} ({n})")))))),
      plotOutput("help_years", height = 220),
      tags$p(class = "text-muted small",
             "Comments per year. Years with few comments give less certain trends.")),
    bslib::card(
      bslib::card_header("How to use this tool"),
      tags$dl(
        tags$dt("Topics"),
        tags$dd("What each topic is about, how its share of attention moved over ",
                "time, and how clearly paragraphs belong to it."),
        tags$dt("Read"),
        tags$dd("The paragraphs behind a topic. Filter by topic, year, or a word; ",
                "click a paragraph to read the whole comment it came from; ",
                "download what you see.")),
      tags$h5("Reading the numbers"),
      tags$ul(
        tags$li(tags$strong("Prevalence"), " is the model's estimate of the share ",
                "of text about a topic, shown with a range of likely values. ",
                "Paragraph counts are exact counts. The app labels which is which."),
        tags$li(tags$strong("Theta"), " is how much of a paragraph belongs to a ",
                "topic, from 0 to 1. Each paragraph is placed in its highest topic, ",
                "so a paragraph with theta 0.3 is only partly about it."),
        tags$li(tags$strong("AvePP"), " is the average theta of a topic's own ",
                "paragraphs. A low value means the topic's paragraphs also discuss ",
                "other subjects; read some before relying on its trend."),
        tags$li("Topics describe what was written, not how many people hold a ",
                "view. A long comment contributes more paragraphs than a short one."))))
}

help_server <- function(input, output, hd) {
  output$help_years <- renderPlot({
    hd$paras |>
      dplyr::distinct(atom_id, Year) |>
      dplyr::count(Year) |>
      ggplot2::ggplot(ggplot2::aes(Year, n)) +
      ggplot2::geom_col(fill = viridisLite::viridis(1, begin = 0.35)) +
      ggplot2::labs(x = NULL, y = "comments") +
      ggplot2::theme_minimal(base_size = 13)
  })
}
