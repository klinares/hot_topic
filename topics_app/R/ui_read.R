# ui_read.R: read the paragraphs behind a topic, open the whole comment a
# paragraph came from, and download what is on screen.

mod_read_ui <- function(id, hd) {
  ns <- NS(id)
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(
      width = 300,
      selectInput(ns("topic"), "Topic", c("All topics" = "0", topic_choices(hd$topics))),
      sliderInput(ns("theta"), "Minimum topic proportion", 0, 1, 0, step = 0.05),
      sliderInput(ns("years"), "Years", hd$years[1], hd$years[2], hd$years,
                  step = 1, sep = ""),
      textInput(ns("search"), "Contains text", placeholder = "word or phrase"),
      tags$hr(),
      uiOutput(ns("count")),
      downloadButton(ns("dl_paras"), "Paragraphs shown (CSV)"),
      tags$br(), tags$br(),
      downloadButton(ns("dl_docs"), "Whole comments (CSV)"),
      tags$p(class = "text-muted small", style = "margin-top:8px;",
             "Whole comments: every paragraph of each comment that has at ",
             "least one paragraph shown, in reading order.")),
    bslib::card(
      bslib::card_header("Paragraphs (click one to open its comment)"),
      DT::DTOutput(ns("table"))),
    bslib::card(
      bslib::card_header(textOutput(ns("doc_title"), inline = TRUE)),
      uiOutput(ns("doc"))))
}

mod_read_server <- function(id, hd) {
  moduleServer(id, function(input, output, session) {
    shown <- reactive({
      d <- hd$paras |>
        dplyr::filter(Year >= input$years[1], Year <= input$years[2],
                      theta_max >= input$theta)
      if (input$topic != "0") d <- dplyr::filter(d, topic == as.integer(input$topic))
      s <- trimws(input$search %||% "")
      if (nzchar(s)) d <- dplyr::filter(d, stringr::str_detect(
        text, stringr::fixed(s, ignore_case = TRUE)))
      d
    })

    output$count <- renderUI(tags$p(
      tags$strong(format(nrow(shown()), big.mark = ",")), " paragraphs from ",
      tags$strong(format(dplyr::n_distinct(shown()$atom_id), big.mark = ",")),
      " comments"))

    output$table <- DT::renderDT({
      d <- shown() |>
        dplyr::transmute(Year, comment = atom_id, topic = paste0(topic, ". ", label),
                         theta = round(theta_max, 2), text)
      DT::datatable(d, rownames = FALSE, selection = "single",
                    options = list(pageLength = 10, scrollX = TRUE,
                                   columnDefs = list(list(width = "55%", targets = 4))))
    })

    picked <- reactive({
      i <- input$table_rows_selected
      if (is.null(i)) NULL else shown()[i, ]
    })

    output$doc_title <- renderText({
      p <- picked()
      if (is.null(p)) "Comment" else paste0("Comment ", p$atom_id, " (", p$Year, ")")
    })

    output$doc <- renderUI({
      p <- picked()
      if (is.null(p))
        return(tags$p(class = "text-muted", "Select a paragraph above."))
      doc <- dplyr::filter(hd$paras, atom_id == p$atom_id)
      tagList(purrr::pmap(doc, function(...) {
        r <- list(...)
        here <- identical(r$para_uid, p$para_uid)
        div(style = paste0("padding:6px 10px; margin:4px 0; border-left:4px solid ",
                           if (here) "#2c3e50" else "#dee2e6", ";",
                           if (here) " background:#f1f3f5;" else ""),
            tags$small(class = "text-muted",
                       paste0("paragraph ", r$para_id, " | topic ", r$topic, ". ",
                              r$label, " | theta ", round(r$theta_max, 2))),
            tags$p(style = "margin:2px 0;", r$text))
      }))
    })

    output$dl_paras <- downloadHandler(
      filename = function() paste0("paragraphs_", Sys.Date(), ".csv"),
      content = function(f) readr::write_excel_csv(
        dplyr::select(shown(), para_uid, atom_id, para_id, Year, topic, label,
                      theta_max, text), f, na = ""))

    output$dl_docs <- downloadHandler(
      filename = function() paste0("comments_", Sys.Date(), ".csv"),
      content = function(f) readr::write_excel_csv(
        hd$paras |>
          dplyr::semi_join(dplyr::distinct(shown(), atom_id), by = "atom_id") |>
          dplyr::select(atom_id, para_id, Year, topic, label, theta_max, text),
        f, na = ""))
  })
}
