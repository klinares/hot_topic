# ui_stance.R: the two working pages. "Detect stance" uploads a CSV, codes
# every passage, and offers three files: the labels, the estimates, and a
# sheet of 400 passages to code by hand. "Check the labels" takes two of those
# back, the labeled file and the coded sheet, possibly days later, and
# compares them. The app remembers nothing between the two: every file of a
# run carries the same run id, and the check matches on it.
#
# Nothing is written to the server's disk: the uploaded file lives in the
# session, and results leave through the download buttons.
#
# A run holds its R process for as long as it takes. On Posit Connect, set
# "Max connections per process" to 1 so one user's run never freezes another
# user's session. options(stance.workers = n) in app.R sets how many requests
# go to the model at once.
#
# The model and its URL are fixed in app.R; the user pastes a key. The key is
# held in a reactiveVal of this module, so it belongs to one
# session and goes when the session ends: never written to disk, never in a
# download, never set with Sys.setenv(), which would expose it to other
# sessions, and no key is ever read from the server's environment.

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
      tags$h5("1. Connect to the model"),
      tags$p(class = "small mb-1", "Model: ", tags$code(getOption("stance.model"))),
      passwordInput(ns("key"), "API key", width = "100%", placeholder = "Paste your key"),
      tags$div(class = "d-flex gap-2 mb-2",
               actionButton(ns("use_key"), "Use this key", class = "btn-primary"),
               actionButton(ns("forget_key"), "Forget it")),
      uiOutput(ns("key_status")),
      tags$p(class = "small text-muted",
             "The key lives in this session only. It is never saved and is not in any result."),
      actionButton(ns("connect"), "Check connection", class = "btn-outline-primary w-100"),
      uiOutput(ns("conn")),
      tags$h5("2. Your passages"),
      fileInput(ns("file"), NULL, accept = c(".csv", "text/csv"),
                buttonLabel = "CSV file", placeholder = "no file"),
      uiOutput(ns("cols")),
      tags$h5("3. What to measure"),
      selectInput(ns("scheme"), NULL, width = "100%",
                  choices = purrr::map_chr(stance_schemes, "name") |>
                    (function(x) stats::setNames(names(x), x))()),
      uiOutput(ns("scheme_help")),
      tags$h6("Your claim"),
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
      tags$h5("4. Run"),
      uiOutput(ns("ready")),
      actionButton(ns("go"), "Detect stance", class = "btn-primary w-100"),
      tags$hr(),
      tags$h5("5. Download"),
      downloadButton(ns("dl_data"), "Your file with labels (CSV)",
                     class = "btn-outline-secondary w-100 mb-2"),
      downloadButton(ns("dl_est"), "Estimates (CSV)",
                     class = "btn-outline-secondary w-100 mb-2"),
      downloadButton(ns("dl_sheet"), "400 passages to code by hand (CSV)",
                     class = "btn-outline-secondary w-100"),
      tags$p(class = "small text-muted mt-2",
             "Keep the file with labels. To check the labels later, you upload it ",
             "again together with the coded sheet; the app keeps nothing.")),
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
      tags$h5("1. Code the sheet by hand"),
      tags$p(class = "small",
             "Open the sheet of 400 passages from Detect stance. Put one of the ",
             "labels listed in its ", tags$code("choose_from"), " column in the ",
             tags$code("hand_label"), " column. Judge the same claim, ",
             "by the same rules the model was given. Leave a row blank to skip it. ",
             "Do not change ", tags$code("stance_run"), " or ", tags$code("stance_row"), "."),
      tags$h5("2. Upload both files"),
      fileInput(ns("labeled"), "Your file with labels", accept = c(".csv", "text/csv"),
                buttonLabel = "CSV file", placeholder = "from Detect stance"),
      fileInput(ns("hand"), "Your coded sheet", accept = c(".csv", "text/csv"),
                buttonLabel = "CSV file", placeholder = "with hand_label filled in"),
      tags$p(class = "small text-muted",
             "The two are matched on the run id and row number they both carry, ",
             "so they must come from the same run. Any day will do.")),
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
    workers <- max(1L, as.integer(getOption("stance.workers", 1L)))

    # ---- the key and the connection ------------------------------------------
    # key() is the pasted key, conn() the endpoint once a check has passed. A new
    # or forgotten key clears conn(), so a run never uses a key that was not
    # checked.
    key <- reactiveVal(NULL)
    conn <- reactiveVal(NULL)
    conn_msg <- reactiveVal(NULL)
    disconnect <- function() {
      conn(NULL)
      conn_msg(NULL)
    }
    observeEvent(input$use_key, {
      k <- trimws(input$key %||% "")
      updateTextInput(session, "key", value = "")
      if (!nzchar(k)) return(showNotification("Nothing pasted.", type = "warning"))
      key(k)
      disconnect()
    })
    observeEvent(input$forget_key, {
      key(NULL)
      disconnect()
    })
    output$key_status <- renderUI(
      if (is.null(key())) tags$p(class = "small text-warning mb-1", "No key in use.") else
        tags$p(class = "small text-success mb-1", "✓ Key in use for this session."))

    observeEvent(input$connect, {
      if (is.null(key()))
        return(conn_msg(list(ok = FALSE, message = "Paste your API key and press Use this key first.")))
      ep <- stance_endpoint(key())
      res <- withProgress(message = "Checking the model", value = 0.5, stance_check(ep))
      conn(if (res$ok) ep)
      conn_msg(res)
    })
    output$conn <- renderUI({
      m <- conn_msg()
      tagList(
        if (is.null(m)) tags$p(class = "small text-muted mt-2", "Check the connection before a run.") else
          tags$p(class = paste("small mt-2", if (m$ok) "text-success" else "text-danger"), m$message),
        tags$p(class = "small text-warning",
          "Labels from this model have not yet been checked against hand coding, so do ",
          "the 400-passage check before reporting. Your passages go to ",
          httr2::url_parse(getOption("stance.base_url"))$hostname,
          ": upload only text that may go there."))
    })

    purrr::iwalk(stance_examples, function(x, i)
      observeEvent(input[[paste0("ex", i)]], updateTextAreaInput(session, "prop", value = x)))

    sch <- reactive(stance_scheme(input$scheme %|_|% "favor"))
    output$scheme_help <- renderUI({
      s <- sch()
      tags$div(class = "small text-muted mb-2",
        tags$p(class = "mb-1", s$use),
        tags$ul(class = "mb-0", purrr::imap(stance_codes(s), function(l, i) {
          means <- c(s$means, irrelevant = "does not address the claim")
          tags$li(tags$strong(l, .noWS = "after"), ": ", means[[l]])
        })))
    })

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
      n_u <- dplyr::n_distinct(p$text[p$keep])  # duplicates are sent once
      # Time from the check's reply time, `workers` at a time, but never faster
      # than the per-minute limit, which the run waits for.
      secs <- conn_msg()$secs
      if (!is.null(secs))
        secs <- max(n_u * secs / workers, n_u / getOption("stance.rpm", 300) * 60)
      tagList(
        tags$p(class = "small text-muted", sprintf(
          "%s passages, %s unique, one request each, %d at a time%s. Keep this tab open.",
          format(n, big.mark = ","), format(n_u, big.mark = ","), workers,
          if (is.null(secs)) "" else paste0(": about ", fmt_dur(secs)))),
        if (is.null(conn())) tags$p(class = "small text-danger",
                                  "Check the connection first (step 1)."))
    })

    # ---- the run -------------------------------------------------------------
    run <- reactiveVal(NULL)
    observeEvent(input$go, {
      p <- prep()
      if (is.null(p)) {
        showNotification("Upload a CSV first.", type = "warning")
        return()
      }
      s <- sch()
      prop <- trimws(input$prop %||% "")
      if (lengths(strsplit(prop, "\\s+")) < 5) {
        showNotification("Write the claim as a full sentence.", type = "warning")
        return()
      }
      if (!sum(p$keep)) {
        showNotification("No passage is within the word bounds.", type = "warning")
        return()
      }
      ep <- conn()
      if (is.null(ep)) {
        showNotification("Check the connection to the model first.", type = "warning")
        return()
      }
      todo <- dplyr::filter(p, keep)
      prompt <- stance_prompt(s, prop, trimws(input$kind %||% "") %|_|%
                                "short text passages")
      t0 <- Sys.time()
      # stance_label_all reports after every chunk of requests, so the bar moves
      # while they run in parallel
      lab <- withProgress(message = "Reading passages", value = 0, tryCatch(
        stance_label_all(todo$text, prompt, ep, s, workers, on_step = function(i, n)
          setProgress(i / n, detail = sprintf("%s of %s unique", format(i, big.mark = ","),
                                              format(n, big.mark = ",")))),
        error = function(e) {
          showNotification(conditionMessage(e), type = "error", duration = NULL)
          NULL
        }))
      req(lab)
      todo$label <- as.vector(lab)
      todo$why <- attr(lab, "why")
      # why a row has no label: outside the bounds, or the request's own reason
      p$why[match(todo$stance_row, p$stance_row)] <- todo$why
      coded <- dplyr::filter(todo, !is.na(label))
      static <- stance_static(coded, s)
      trends <- if ("time" %in% names(coded)) stance_trends(coded, s) else NULL
      counts <- list(total = nrow(p), coded = nrow(coded),
                     excluded = sum(!p$keep) + sum(is.na(todo$label)),
                     documents = dplyr::n_distinct(coded$cluster))
      run_id <- stance_run_id(ep$model)
      labeled <- raw() |>
        dplyr::mutate(stance_run = run_id, stance_row = dplyr::row_number()) |>
        dplyr::left_join(dplyr::select(todo, stance_row, stance = label),
                         by = "stance_row") |>
        dplyr::left_join(dplyr::select(p, stance_row, stance_words = n_words,
                                       stance_excluded = why), by = "stance_row") |>
        dplyr::mutate(stance_scheme = s$id, stance_claim = prop, stance_model = ep$model,
                      stance_date = as.character(Sys.Date()))
      run(list(scheme = s, prop = prop, prompt = prompt, ep = ep, counts = counts,
               coded = coded, static = static, trends = trends,
               unlabeled = todo$why[is.na(todo$label)],
               notes = attr(trends, "notes"),
               minutes = as.numeric(difftime(Sys.time(), t0, units = "mins")),
               # the three files, built once so the buttons only write them
               labeled = labeled,
               estimates = stance_record(stance_table(static, trends), s, prop,
                                         prompt, ep, counts),
               sheet = stance_sheet(coded, s, prop, run_id)))
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
          format(r$counts$total, big.mark = ","),
          format(r$counts$documents, big.mark = ","), fmt_dur(r$minutes * 60))),
        # passages that got no label are left out of the estimates; say why,
        # one line per kind of reason with its first instance
        if (length(r$unlabeled)) {
          kinds <- split(r$unlabeled, sub(":.*", "", r$unlabeled))
          tagList(
            tags$p(class = "small text-danger mb-1", sprintf(
              "%s passage(s) got no label and are left out of the estimates:",
              format(length(r$unlabeled), big.mark = ","))),
            tags$ul(class = "small text-danger", purrr::imap(kinds, function(w, k)
              tags$li(format(length(w), big.mark = ","), " ", k, ", e.g. ",
                      substr(sub("^[^:]*: ", "", w[1]), 1, 200)))))
        },
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

    output$plot_static <- renderPlot({
      r <- req(run())
      stance_plot_static(r$static, r$scheme)
    })
    output$plot_sal <- renderPlot({
      r <- req(run())
      stance_plot_salience(r$trends, stance_observed(r$coded, r$scheme))
    })
    output$plot_dir <- renderPlot({
      r <- req(run())
      stance_plot_direction(r$trends, stance_observed(r$coded, r$scheme), r$scheme)
    })

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
      content = function(file) readr::write_excel_csv(req(run())$labeled, file, na = ""))

    output$dl_est <- downloadHandler(
      filename = function() paste0("stance_estimates_", stamp(), ".csv"),
      content = function(file) readr::write_csv(req(run())$estimates, file))

    output$dl_sheet <- downloadHandler(
      filename = function() paste0("stance_handcode_", stamp(), ".csv"),
      content = function(file) readr::write_excel_csv(req(run())$sheet, file, na = ""))

    # ---- the hand-coded check ------------------------------------------------
    # Built only from the two uploads, so it works in any later session.
    read_up <- function(f) tryCatch(
      readr::read_csv(f$datapath, show_col_types = FALSE, progress = FALSE,
                      col_types = readr::cols(.default = readr::col_character())),
      error = function(e) e)
    check <- reactive({
      lf <- req(input$labeled)
      hf <- req(input$hand)
      fail <- function(msg) {
        showNotification(msg, type = "error", duration = NULL)
        NULL
      }
      labeled <- read_up(lf)
      sheet <- read_up(hf)
      if (inherits(labeled, "error")) return(fail(paste("The labeled file could not be read:",
                                                      conditionMessage(labeled))))
      if (inherits(sheet, "error")) return(fail(paste("The sheet could not be read:",
                                                    conditionMessage(sheet))))
      m <- tryCatch(stance_match(labeled, sheet), error = function(e) e)
      if (inherits(m, "error")) return(fail(conditionMessage(m)))
      if (length(attr(m, "ignored")))
        showNotification(paste("Ignoring labels that are not in this scheme:",
                               paste(attr(m, "ignored"), collapse = ", ")),
                         type = "warning", duration = NULL)
      a <- tryCatch(stance_agreement(m$hand_label, m$label, m$document, attr(m, "scheme")),
                    error = function(e) e)
      if (inherits(a, "error")) return(fail(conditionMessage(a)))
      c(a, list(run = attr(m, "run"), claim = attr(m, "claim"), scheme = attr(m, "scheme"),
                model = attr(m, "model"), date = attr(m, "date")))
    })

    output$agree <- renderUI({
      a <- req(check())
      k <- a$kappa
      tagList(
        tags$p(class = "small",
               tags$strong("Scheme: "), a$scheme$name, tags$br(),
               tags$strong("Claim: "), tags$em(a$claim %|_|% "not recorded"), tags$br(),
               tags$strong("Model: "), a$model %|_|% "not recorded", " | ",
               tags$strong("Run: "), a$run, " | ", tags$strong("Coded on: "),
               a$date %|_|% "not recorded"),
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
  paste(round(sec / 3600, 1), "hours")
}

# "" or NA falls back to y; unlike %||%, which only catches NULL.
`%|_|%` <- function(x, y) if (is.null(x) || !length(x) || is.na(x) || !nzchar(x)) y else x
