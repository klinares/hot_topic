# ui_stance.R: the two working pages. "Detect stance" uploads a CSV, codes
# every passage, and offers the labels and estimates; "Check the labels" takes
# hand codes for 400 of them back and compares. Both are served by one
# moduleServer, so the check works on the run that is open.
#
# Nothing is written to the server's disk: the uploaded file lives in the
# session, and results leave through the download buttons.
#
# A run holds its R process for as long as it takes. On Posit Connect, set
# "Max connections per process" to 1 so one user's run never freezes another
# user's session.

stance_examples <- c(
  "The proposed rule should be withdrawn.",
  "The United States should take an active role in the affairs of other nations.",
  "The new fee schedule will harm small providers.",
  "Remote work improves how this service is delivered.")

mod_stance_ui <- function(id) {
  ns <- NS(id)
  d <- stance_defaults
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(
      width = 400,
      tags$h5("1. Your passages"),
      fileInput(ns("file"), NULL, accept = c(".csv", "text/csv"),
                buttonLabel = "CSV file", placeholder = "no file"),
      uiOutput(ns("cols")),
      tags$h5("2. Your claim"),
      textAreaInput(ns("prop"), NULL, rows = 3, width = "100%",
                    placeholder = "One sentence that states one side"),
      tags$p(class = "small text-muted mb-1", "Or use an example:"),
      purrr::imap(stance_examples, function(x, i)
        actionLink(ns(paste0("ex", i)), x, class = "d-block small mb-1")),
      textInput(ns("kind"), "These passages are", value = "short text passages",
                width = "100%"),
      tags$p(class = "small text-muted",
             "Goes into the prompt, so write it as a description: ",
             tags$em("paragraphs from public comments"), ", ",
             tags$em("answers to an open-ended survey question"), "."),
      tags$h5("3. Run"),
      uiOutput(ns("ready")),
      actionButton(ns("go"), "Detect stance", class = "btn-primary w-100"),
      tags$hr(),
      downloadButton(ns("dl_data"), "Your file with labels (CSV)",
                     class = "btn-outline-secondary w-100 mb-2"),
      downloadButton(ns("dl_est"), "Estimates (CSV)",
                     class = "btn-outline-secondary w-100")),
    uiOutput(ns("preview")),
    bslib::card(
      bslib::card_header(textOutput(ns("title"), inline = TRUE)),
      uiOutput(ns("summary")),
      uiOutput(ns("results")),
      uiOutput(ns("overall_head")),
      tableOutput(ns("overall")),
      tags$p(class = "small text-muted",
             "Intervals are 95 percent and clustered by document. They do not ",
             "include error in the model's labels; the Check the labels page is ",
             "how to measure that.")))
}

mod_stance_check_ui <- function(id) {
  ns <- NS(id)
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(
      width = 400,
      tags$h5("1. Get the sheet"),
      downloadButton(ns("dl_sheet"), "400 passages to code (CSV)",
                     class = "btn-primary w-100"),
      tags$p(class = "small text-muted mt-2",
             "Drawn at random from the passages that were coded. The model's ",
             "label is not in the file, so it cannot anchor you."),
      tags$h5("2. Code them by hand"),
      tags$p(class = "small",
             "Put one of ", tags$code("favor"), ", ", tags$code("neutral"), ", ",
             tags$code("oppose"), ", ", tags$code("irrelevant"),
             " in the ", tags$code("hand_label"), " column. Judge the same claim, ",
             "by the same rules the model was given. Leave a row blank to skip it. ",
             "Keep the ", tags$code("stance_row"), " column as it is."),
      tags$h5("3. Upload your codes"),
      fileInput(ns("hand"), NULL, accept = c(".csv", "text/csv"),
                buttonLabel = "CSV file", placeholder = "no file")),
    bslib::card(
      bslib::card_header("Why 400"),
      tags$p("400 hand codes put the overall agreement within about 5 ",
             "percentage points. That is enough to see whether the labels are ",
             "usable. It is ", tags$strong("not"), " enough to say much about a ",
             "label the model rarely uses: a label on 5 percent of passages ",
             "appears about 20 times in 400, and 20 cases carry an uncertainty of ",
             "roughly 18 points. Read the per-label rows with their counts, and ",
             "treat a row marked thin as a hint, not a measurement."),
      tags$p(class = "small text-muted",
             "One coder is a weak standard. If a decision matters, have a second ",
             "person code a subset of the same rows and compare the two of you ",
             "first. Agreement also tells you nothing about which way the errors ",
             "run: read the confusion matrix, where a model that pushes ",
             "everything into one label shows up as a filled column.")),
    bslib::card(
      bslib::card_header("Agreement"),
      uiOutput(ns("agree")),
      tags$h6("Confusion matrix"),
      tags$p(class = "small text-muted mb-1",
             "Rows are your labels, columns the model's. The diagonal is where ",
             "you agreed."),
      tableOutput(ns("confusion")),
      tags$h6("By label"),
      tableOutput(ns("by_label")),
      tags$p(class = "small text-muted",
             tags$strong("Recall"), " is the share of your passages with that ",
             "label that the model also gave it. ", tags$strong("Precision"),
             " is the share of the model's passages with that label that you ",
             "agreed on.")))
}

mod_stance_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    d0 <- stance_defaults
    max_rows <- getOption("stance.max_rows", 10000L)
    sec_each <- getOption("stance.sec_per_passage", 0.1)

    purrr::iwalk(stance_examples, function(x, i)
      observeEvent(input[[paste0("ex", i)]], updateTextAreaInput(session, "prop", value = x)))

    # ---- the uploaded file ---------------------------------------------------
    raw <- reactive({
      f <- req(input$file)
      out <- tryCatch(readr::read_csv(f$datapath, show_col_types = FALSE,
                                      progress = FALSE, guess_max = 10000),
                      error = function(e) e)
      if (inherits(out, "error")) {
        showNotification(paste("The file could not be read:", conditionMessage(out)),
                         type = "error", duration = NULL)
        return(NULL)
      }
      if (!nrow(out)) {
        showNotification("That file has no rows.", type = "error")
        return(NULL)
      }
      out
    })

    output$cols <- renderUI({
      r <- raw()
      if (is.null(r)) return(NULL)
      ns <- session$ns
      nm <- names(r)
      # the longest character column is almost always the text
      chr <- nm[purrr::map_lgl(r, function(x) is.character(x) | is.factor(x))]
      wide <- purrr::map_dbl(r[chr], function(x)
        suppressWarnings(mean(nchar(as.character(x)), na.rm = TRUE)))
      wide[!is.finite(wide)] <- -1
      tagList(
        selectInput(ns("text_col"), "Text column", choices = nm,
                    selected = if (length(chr)) chr[[which.max(wide)]] else nm[[1]]),
        selectInput(ns("time_col"), "Time column (optional)",
                    choices = c("none" = "", nm)),
        selectInput(ns("doc_col"), "Document column (optional)",
                    choices = c("each row is independent" = "", nm)))
    })

    # One row per uploaded row: text, document, time, and whether it is coded.
    prep <- reactive({
      r <- raw()
      req(r, input$text_col)
      out <- tryCatch(stance_prepare(r, input$text_col, input$time_col %||% "",
                                     input$doc_col %||% ""),
                      error = function(e) e)
      if (inherits(out, "error")) {
        showNotification(conditionMessage(out), type = "error", duration = NULL)
        return(NULL)
      }
      out
    })

    output$preview <- renderUI({
      p <- prep()
      if (is.null(p)) return(NULL)
      n_keep <- sum(p$keep)
      drops <- p |>
        dplyr::filter(!keep) |>
        dplyr::count(why, name = "rows")
      bslib::card(
        bslib::card_header("Your file"),
        bslib::layout_columns(
          bslib::value_box("Rows", format(nrow(p), big.mark = ",")),
          bslib::value_box("To code", format(n_keep, big.mark = ",")),
          bslib::value_box("Documents", format(dplyr::n_distinct(p$cluster[p$keep]),
                                               big.mark = ",")),
          bslib::value_box("Periods", if ("time" %in% names(p))
            format(dplyr::n_distinct(p$period[p$keep]), big.mark = ",") else "none")),
        if (nrow(drops)) tagList(
          tags$p(class = "small mb-1", "Rows left uncoded:"),
          tags$ul(class = "small", purrr::map2(drops$why, drops$rows, function(w, n)
            tags$li(format(n, big.mark = ","), " ", w)))),
        if (n_keep) tagList(
          tags$p(class = "small text-muted",
                 sprintf("Words per passage: median %s, range %s to %s.",
                         stats::median(p$n_words[p$keep]),
                         min(p$n_words[p$keep]), max(p$n_words[p$keep]))),
          tags$p(class = "small", tags$strong("First passage: "),
                 substr(p$text[p$keep][1], 1, 400))))
    })

    output$ready <- renderUI({
      p <- prep()
      if (is.null(p)) return(tags$p(class = "small text-muted",
                                    "Upload a CSV to start."))
      n <- sum(p$keep)
      if (n == 0) return(tags$p(class = "small text-danger",
                                "No row is within the word bounds."))
      if (n > max_rows) return(tags$p(class = "small text-danger", sprintf(
        "%s passages is more than this app will code in one run (%s). Split the file.",
        format(n, big.mark = ","), format(max_rows, big.mark = ","))))
      tags$p(class = "small text-muted", sprintf(
        "%s passages, one request each: about %s. Keep this tab open.",
        format(n, big.mark = ","), fmt_dur(n * sec_each)))
    })

    # ---- the run -------------------------------------------------------------
    run <- reactiveVal(NULL)
    observeEvent(input$go, {
      p <- prep()
      if (is.null(p)) {
        showNotification("Upload a CSV first.", type = "warning")
        return()
      }
      prop <- trimws(input$prop %||% "")
      if (lengths(strsplit(prop, "\\s+")) < 5) {
        showNotification("Write the claim as a full sentence.", type = "warning")
        return()
      }
      if (!sum(p$keep) || sum(p$keep) > max_rows) {
        showNotification("Nothing to code, or too many rows.", type = "warning")
        return()
      }
      ep <- tryCatch(stance_endpoint(), error = function(e) {
        showNotification(conditionMessage(e), type = "error", duration = NULL)
        NULL
      })
      req(ep)
      todo <- dplyr::filter(p, keep)
      prompt <- stance_prompt(prop, trimws(input$kind %||% "") %|_|%
                                "short text passages")
      every <- max(1L, nrow(todo) %/% 100L)
      t0 <- Sys.time()
      lab <- withProgress(message = "Reading passages", value = 0, tryCatch(
        code_all(todo$text, prompt, ep, on_step = function(i, n)
          if (i %% every == 0L || i == n)
            setProgress(i / n, detail = sprintf("%s of %s",
                                                format(i, big.mark = ","),
                                                format(n, big.mark = ",")))),
        error = function(e) {
          showNotification(conditionMessage(e), type = "error", duration = NULL)
          NULL
        }))
      req(lab)
      todo$label <- lab
      coded <- dplyr::filter(todo, !is.na(label))
      static <- stance_static(coded)
      trends <- if ("time" %in% names(coded)) stance_trends(coded) else NULL
      counts <- list(uploaded = nrow(p), coded = nrow(coded),
                     excluded = sum(!p$keep) + sum(is.na(todo$label)),
                     documents = dplyr::n_distinct(coded$cluster))
      labeled <- raw() |>
        dplyr::mutate(stance_row = dplyr::row_number()) |>
        dplyr::left_join(dplyr::select(todo, stance_row, stance = label),
                         by = "stance_row") |>
        dplyr::left_join(dplyr::select(p, stance_row, stance_words = n_words,
                                       stance_excluded = why), by = "stance_row") |>
        dplyr::mutate(stance_claim = prop, stance_model = ep$model,
                      stance_date = as.character(Sys.Date()))
      run(list(prop = prop, prompt = prompt, ep = ep, counts = counts,
               coded = coded, static = static, trends = trends,
               notes = attr(trends, "notes"),
               minutes = as.numeric(difftime(Sys.time(), t0, units = "mins")),
               # the three files, built once so the buttons only write them
               labeled = labeled,
               estimates = stance_record(stance_table(static, trends), prop,
                                         prompt, ep, counts),
               sheet = stance_sheet(coded, prop)))
    })

    # ---- results -------------------------------------------------------------
    output$title <- renderText(
      if (is.null(run())) "Results appear here" else paste0("“", run()$prop, "”"))

    output$summary <- renderUI({
      r <- req(run())
      thin <- attr(r$trends, "periods")$salience
      thin <- if (is.null(thin)) NULL else thin$period[!thin$enough]
      tagList(
        tags$p(sprintf(
          "%s of %s passages labeled, from %s document(s), in %s.",
          format(r$counts$coded, big.mark = ","),
          format(r$counts$uploaded, big.mark = ","),
          format(r$counts$documents, big.mark = ","), fmt_dur(r$minutes * 60))),
        if (!stance_has_trend(r$trends)) tags$p(class = "small",
          tags$strong("Static estimate. "),
          if ("time" %in% names(r$coded))
            paste("Time is ignored: fewer than", d0$min_periods, "periods hold at least",
                  d0$min_period_n, "passages.") else
            "No time column, so there is nothing to trend."),
        if (length(thin)) tags$p(class = "small text-muted", sprintf(
          "Left out of the trend, under %d passages: %s. They are still in the ",
          d0$min_period_n, paste(thin, collapse = ", ")),
          "overall table below."),
        if (length(r$notes)) tags$ul(class = "small text-muted",
                                     purrr::map(r$notes, tags$li)))
    })

    output$results <- renderUI({
      r <- req(run())
      ns <- session$ns
      if (!stance_has_trend(r$trends))
        return(tagList(plotOutput(ns("plot_static"), height = 260)))
      tagList(plotOutput(ns("plot_sal"), height = 260),
              tags$hr(),
              plotOutput(ns("plot_dir"), height = 280))
    })

    output$plot_static <- renderPlot(stance_plot_static(req(run())$static))
    output$plot_sal <- renderPlot(stance_plot_salience(req(run())$trends))
    output$plot_dir <- renderPlot(stance_plot_direction(req(run())$trends))

    output$overall_head <- renderUI({
      req(run())
      tagList(tags$h6("The whole file"),
              tags$p(class = "small text-muted",
                     "Every coded passage, with no period dropped."))
    })

    output$overall <- renderTable({
      req(run())$static |>
        dplyr::transmute(quantity, `out of` = basis, passages = n,
                         share = pct(share), `95% low` = pct(lo),
                         `95% high` = pct(hi))
    })

    # ---- downloads -----------------------------------------------------------
    output$dl_data <- downloadHandler(
      filename = function() paste0("stance_labels_", stamp(), ".csv"),
      content = function(file) readr::write_csv(req(run())$labeled, file))

    output$dl_est <- downloadHandler(
      filename = function() paste0("stance_estimates_", stamp(), ".csv"),
      content = function(file) readr::write_csv(req(run())$estimates, file))

    output$dl_sheet <- downloadHandler(
      filename = function() paste0("stance_handcode_", stamp(), ".csv"),
      content = function(file) readr::write_csv(req(run())$sheet, file))

    # ---- the hand-coded check ------------------------------------------------
    check <- reactive({
      f <- req(input$hand)
      r <- run()
      if (is.null(r)) {
        showNotification("Run a claim on the Detect stance page first.",
                         type = "warning")
        return(NULL)
      }
      h <- tryCatch(readr::read_csv(f$datapath, show_col_types = FALSE,
                                    progress = FALSE), error = function(e) e)
      if (inherits(h, "error")) {
        showNotification(paste("The file could not be read:", conditionMessage(h)),
                         type = "error", duration = NULL)
        return(NULL)
      }
      if (!all(c("stance_row", "hand_label") %in% names(h))) {
        showNotification("That file needs the stance_row and hand_label columns from the sheet.",
                         type = "error", duration = NULL)
        return(NULL)
      }
      h <- h |>
        dplyr::transmute(stance_row = as.integer(stance_row),
                         hand_label = tolower(trimws(as.character(hand_label)))) |>
        dplyr::filter(!is.na(stance_row), !is.na(hand_label), nzchar(hand_label))
      bad <- setdiff(unique(h$hand_label), stance_labels)
      if (length(bad))
        showNotification(paste("Ignoring labels that are not one of the four:",
                               paste(bad, collapse = ", ")), type = "warning",
                         duration = NULL)
      j <- dplyr::inner_join(h, dplyr::select(r$coded, stance_row, label, cluster),
                             by = "stance_row")
      if (!nrow(j)) {
        showNotification("No stance_row in that file matches the current run.",
                         type = "error", duration = NULL)
        return(NULL)
      }
      a <- tryCatch(stance_agreement(j$hand_label, j$label, j$cluster),
                    error = function(e) e)
      if (inherits(a, "error")) {
        showNotification(conditionMessage(a), type = "error", duration = NULL)
        return(NULL)
      }
      a
    })

    output$agree <- renderUI({
      a <- req(check())
      k <- a$kappa
      tagList(
        bslib::layout_columns(
          bslib::value_box("Passages", format(a$n, big.mark = ",")),
          bslib::value_box("Agreement", pct(a$agree),
                           tags$span(class = "small", sprintf("95%% %s to %s",
                             pct(a$agree_ci[1]), pct(a$agree_ci[2])))),
          bslib::value_box("Cohen's kappa", sprintf("%.2f", k),
                           tags$span(class = "small", sprintf("95%% %.2f to %.2f",
                             a$kappa_ci[1], a$kappa_ci[2])))),
        tags$p(class = "small text-muted",
          sprintf("From %s document(s). ", format(a$documents, big.mark = ",")),
          "Intervals come from a bootstrap over documents, so they carry the ",
          "clustering. Kappa is agreement beyond what the two of you would reach ",
          "by chance given how often each label is used; it falls well below raw ",
          "agreement whenever one label dominates."),
        if (!is.na(k) && k < 0.4) tags$p(class = "text-danger",
          "Kappa under 0.40: the labels disagree with you often enough that the ",
          "estimates should not be reported without saying so. Read the confusion ",
          "matrix, reword the claim, and run it again."))
    })

    output$confusion <- renderTable({
      a <- req(check())
      m <- as.data.frame.matrix(a$confusion)
      cbind(`your label` = rownames(m), m)
    }, rownames = FALSE)

    output$by_label <- renderTable({
      stance_by_label(req(check())) |>
        dplyr::transmute(label, `you used` = hand_n, `model used` = model_n,
                         agreed, recall = pct(recall), precision = pct(precision),
                         `too thin to read` = dplyr::if_else(thin, "yes", ""))
    })
  })
}

# ---- small helpers -----------------------------------------------------------

pct <- function(x) dplyr::if_else(is.na(x), "-", sprintf("%.1f%%", 100 * x))

stamp <- function() format(Sys.time(), "%Y%m%d_%H%M")

fmt_dur <- function(sec) {
  if (sec < 90) return(sprintf("%.0f seconds", sec))
  if (sec < 5400) return(sprintf("%.0f minutes", sec / 60))
  sprintf("%.1f hours", sec / 3600)
}

# "" or NA falls back to y; unlike %||%, which only catches NULL.
`%|_|%` <- function(x, y) if (is.null(x) || !length(x) || is.na(x) || !nzchar(x)) y else x
