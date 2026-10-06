# ui_stance.R: the Stance tab. A user writes a claim; every paragraph is
# labeled by the model named in STANCE_URL / STANCE_MODEL, one request at a
# time; the tab shows each label's yearly trend and offers the estimates as a
# CSV. Nothing is written to disk.
#
# A run holds its R process for about ten minutes. On Posit Connect, set
# "Max connections per process" to 1 so one user's run never freezes another
# user's session.

mod_stance_ui <- function(id, hd) {
  ns <- NS(id)
  ex <- hd$topics$proposition
  ex <- utils::head(ex[!is.na(ex) & nzchar(ex)], 4)
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(
      width = 380,
      tags$h5("Your claim"),
      textAreaInput(ns("prop"), NULL, rows = 4, width = "100%",
                    placeholder = "One sentence that states one side, e.g. \"The federal government should ...\""),
      if (length(ex)) tagList(
        tags$p(class = "small text-muted mb-1", "Examples drafted from the topics; click one to use it:"),
        purrr::imap(ex, function(x, i)
          actionLink(ns(paste0("ex", i)), x, class = "d-block small mb-2"))),
      actionButton(ns("go"), "Detect stance", class = "btn-primary w-100"),
      tags$p(class = "small text-muted mt-2", sprintf(
        "Reads all %s paragraphs, one at a time; expect about ten minutes. Keep this tab open.",
        format(nrow(hd$paras), big.mark = ","))),
      downloadButton(ns("dl"), "Download yearly estimates (CSV)", class = "w-100")),
    bslib::card(
      bslib::card_header("How it works"),
      tags$ol(
        tags$li("Write one claim, in one sentence, that a writer could agree or disagree with. ",
                "State one side only; avoid \"X rather than Y\"."),
        tags$li("Press ", tags$strong("Detect stance"), ". A language model reads every paragraph on ",
                "its own and labels it ", tags$em("favor"), ", ", tags$em("oppose"), ", ",
                tags$em("neutral"), ", or ", tags$em("irrelevant"), " (does not address the claim)."),
        tags$li("Each label's share of all paragraphs is estimated for every year, as a smooth ",
                "trend with a 95% interval. Paragraphs from one comment are treated as related."),
        tags$li("Download the yearly estimates. The file records the claim, the model, and the date.")),
      tags$p(class = "small text-muted",
             "Every paragraph is read, so nothing is sampled. The intervals do not include mistakes ",
             "in the model's labels; try a reworded claim to see whether the result depends on ",
             "wording. A rising favor line can mean more writers agree or more writers discuss ",
             "the claim; the irrelevant line tells which. The full method is in the stance report ",
             "linked on the Start here tab.")),
    bslib::card(
      bslib::card_header(textOutput(ns("title"), inline = TRUE)),
      plotOutput(ns("plot"), height = 480),
      uiOutput(ns("notes")),
      tableOutput(ns("overall"))))
}

mod_stance_server <- function(id, hd) {
  moduleServer(id, function(input, output, session) {
    ex <- hd$topics$proposition
    ex <- utils::head(ex[!is.na(ex) & nzchar(ex)], 4)
    purrr::iwalk(ex, function(x, i)
      observeEvent(input[[paste0("ex", i)]], updateTextAreaInput(session, "prop", value = x)))

    res <- reactiveVal(NULL)
    observeEvent(input$go, {
      prop <- trimws(input$prop)
      if (lengths(strsplit(prop, "\\s+")) < 5) {
        showNotification("Write the claim as a full sentence.", type = "warning")
        return()
      }
      ep <- tryCatch(stance_endpoint(), error = function(e) {
        showNotification(conditionMessage(e), type = "error", duration = NULL)
        NULL
      })
      req(ep)
      p <- hd$paras
      every <- max(1L, nrow(p) %/% 100L)
      lab <- withProgress(message = "Reading paragraphs", value = 0, tryCatch(
        code_all(p$text, prop, ep, on_step = function(i, n)
          if (i %% every == 0L || i == n)
            setProgress(i / n, detail = sprintf("%d of %d", i, n))),
        error = function(e) {
          showNotification(conditionMessage(e), type = "error", duration = NULL)
          NULL
        }))
      req(lab)
      ok <- !is.na(lab)
      d <- p[ok, ]
      trends <- stance_trends(lab[ok], d$Year, d$atom_id)
      res(list(prop = prop, n = nrow(p), n_coded = sum(ok),
               record = stance_record(trends, prop, ep, sum(ok)),
               trends = trends, notes = attr(trends, "notes"),
               overall = stance_overall(lab[ok], d$atom_id)))
    })

    output$title <- renderText(
      if (is.null(res())) "Results appear here" else paste0("“", res()$prop, "”"))
    output$plot <- renderPlot({
      req(res())
      stance_plot(res()$trends)
    })
    output$notes <- renderUI({
      r <- req(res())
      tags$p(class = "small text-muted",
             sprintf("%s of %s paragraphs labeled.", format(r$n_coded, big.mark = ","),
                     format(r$n, big.mark = ",")),
             if (length(r$notes)) tagList(tags$br(), paste(r$notes, collapse = "; ")))
    })
    output$overall <- renderTable({
      req(res())$overall |>
        dplyr::mutate(dplyr::across(c(share, lo, hi), function(x) sprintf("%.1f%%", 100 * x))) |>
        dplyr::rename(`share of all paragraphs` = share, `95% low` = lo, `95% high` = hi)
    })
    output$dl <- downloadHandler(
      filename = function() paste0("stance_", format(Sys.time(), "%Y%m%d_%H%M"), ".csv"),
      content = function(file) readr::write_csv(req(res())$record, file))
  })
}
