# ui_topics.R: what the topic model found and how prevalence moved over time.
# Two kinds of number appear here and are labeled as different claims: the
# STM prevalence trend is a model estimate with an interval; paragraph counts
# per year are exact counts of modal assignments.

mod_topics_ui <- function(id, hd) {
  ns <- NS(id)
  tagList(
    bslib::layout_columns(
      col_widths = c(4, 8),
      bslib::card(
        bslib::card_header("Topic"),
        selectInput(ns("topic"), NULL, topic_choices(hd$topics), width = "100%"),
        uiOutput(ns("card"))),
      bslib::card(
        bslib::card_header("Estimated prevalence over time"),
        plotOutput(ns("trend"), height = 300),
        tags$p(class = "text-muted small",
               "Estimated share of text on this topic by year, with a 95% ",
               "interval. It is a model estimate, and the band widens where ",
               "few comments were written."))),
    bslib::layout_columns(
      col_widths = c(6, 6),
      bslib::card(
        bslib::card_header("Paragraphs assigned per year (exact count)"),
        plotOutput(ns("counts"), height = 260),
        tags$p(class = "text-muted small",
               "Paragraphs whose modal topic is this one. Years with few ",
               "paragraphs are where the trend above is interpolating.")),
      bslib::card(
        bslib::card_header("All topics: prevalence and assignment sharpness"),
        plotOutput(ns("overview"), height = 260),
        tags$p(class = "text-muted small",
               "Bar length is average prevalence. Color is AvePP, the mean ",
               "topic proportion among a topic's own paragraphs; low values ",
               "mean paragraphs are only loosely about this topic."))),
    bslib::card(
      bslib::card_header("All topics over time"),
      plotOutput(ns("heat"), height = 380),
      tags$p(class = "text-muted small",
             "Estimated prevalence by year, one row per topic, ordered by ",
             "overall prevalence. Read it for timing, not for exact values.")),
    bslib::card(
      bslib::card_header("Codebook"),
      DT::DTOutput(ns("table")),
      downloadButton(ns("dl_codebook"), "Download codebook (CSV)")))
}

mod_topics_server <- function(id, hd) {
  moduleServer(id, function(input, output, session) {
    k <- reactive(as.integer(req(input$topic)))
    row <- reactive(dplyr::filter(hd$topics, topic == k()))

    output$card <- renderUI({
      r <- row()
      tagList(
        tags$h5(r$label),
        tags$p(r$description),
        tags$p(tags$strong("Distinctive words: "), r$frex),
        tags$p(tags$strong("Paragraphs: "), format(r$n_paras, big.mark = ","),
               tags$br(), tags$strong("Prevalence: "), sprintf("%.1f%%", 100 * r$prevalence),
               tags$br(), tags$strong("AvePP: "), sprintf("%.2f", r$avepp)),
        if (!is.na(r$proposition) && nzchar(r$proposition))
          tags$p(tags$strong("Codebook proposition: "), tags$em(r$proposition)))
    })

    output$trend <- renderPlot({
      d <- dplyr::filter(hd$trends, topic == k())
      ggplot2::ggplot(d, ggplot2::aes(Year, fit)) +
        ggplot2::geom_ribbon(ggplot2::aes(ymin = lo, ymax = hi),
                             fill = viridisLite::viridis(1, begin = 0.35),
                             alpha = 0.25) +
        ggplot2::geom_line(colour = viridisLite::viridis(1, begin = 0.35),
                           linewidth = 1) +
        ggplot2::scale_y_continuous(labels = function(x) paste0(round(100 * x), "%")) +
        ggplot2::labs(x = NULL, y = "expected share of text") +
        ggplot2::theme_minimal(base_size = 13)
    })

    output$counts <- renderPlot({
      hd$paras |>
        dplyr::filter(topic == k()) |>
        dplyr::count(Year) |>
        ggplot2::ggplot(ggplot2::aes(Year, n)) +
        ggplot2::geom_col(fill = viridisLite::viridis(1, begin = 0.6)) +
        ggplot2::labs(x = NULL, y = "paragraphs") +
        ggplot2::theme_minimal(base_size = 13)
    })

    output$overview <- renderPlot({
      hd$topics |>
        dplyr::mutate(name = stats::reorder(paste0(topic, ". ", label), prevalence),
                      pick = topic == k()) |>
        ggplot2::ggplot(ggplot2::aes(prevalence, name, fill = avepp)) +
        ggplot2::geom_col(ggplot2::aes(colour = pick), linewidth = 0.8) +
        ggplot2::scale_colour_manual(values = c(`FALSE` = NA, `TRUE` = "black"),
                                     guide = "none") +
        ggplot2::scale_fill_viridis_c(name = "AvePP", limits = c(0, 1)) +
        ggplot2::scale_x_continuous(labels = function(x) paste0(round(100 * x), "%")) +
        ggplot2::labs(x = "average prevalence", y = NULL) +
        ggplot2::theme_minimal(base_size = 12)
    })

    output$heat <- renderPlot({
      lv <- rev(paste0(hd$topics$topic, ". ", hd$topics$label))
      hd$trends |>
        dplyr::left_join(dplyr::select(hd$topics, topic, label), by = "topic") |>
        dplyr::mutate(name = factor(paste0(topic, ". ", label), levels = lv)) |>
        ggplot2::ggplot(ggplot2::aes(Year, name, fill = fit)) +
        ggplot2::geom_tile() +
        ggplot2::scale_fill_viridis_c(name = "prevalence",
                                      labels = function(x) paste0(round(100 * x), "%")) +
        ggplot2::labs(x = NULL, y = NULL) +
        ggplot2::theme_minimal(base_size = 12)
    })

    output$table <- DT::renderDT({
      hd$topics |>
        dplyr::transmute(topic, label, description, words = frex,
                         paragraphs = n_paras,
                         prevalence = round(prevalence, 3), avepp = round(avepp, 2),
                         proposition) |>
        DT::datatable(rownames = FALSE, selection = "none",
                      options = list(pageLength = 10, scrollX = TRUE))
    })

    output$dl_codebook <- downloadHandler(
      filename = function() paste0("topic_codebook_", Sys.Date(), ".csv"),
      content = function(f) readr::write_csv(hd$topics, f, na = ""))
  })
}
