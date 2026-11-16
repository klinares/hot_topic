# stance_app.R: the app's three pages. "Start here" explains the method.
# "Detect stance" uploads a CSV, has the models label a sample of it, and offers three files:
# the labels, the estimates, and a sheet to code by hand. "Check the labels"
# takes two of those back, possibly days later, and compares them.
#
# The app remembers nothing between visits and writes nothing to the server.
# The labeled file is the memory: it carries the sample (group, draw, label) in
# its stance_ columns, so uploading it again continues the same sample.
#
# The models and their URL are fixed in app.R; the user pastes a key. The key
# is held in a reactiveVal of the module, so it belongs to one session and goes
# when the session ends: never written to disk, never in a download, never set
# with Sys.setenv(), and no key is ever read from the server's environment.
#
# A run holds its R process while it labels. On Posit Connect, set "Max
# connections per process" to 1 so one user's run never freezes another's.

stance_examples <- c(
  "The proposed rule should be withdrawn.",
  "The United States should take an active role in the affairs of other nations.",
  "The new fee schedule will harm small providers.",
  "Remote work improves how this service is delivered.")

# ---- Detect stance: the page -----------------------------------------------------

mod_stance_ui <- function(id) {
  ns <- NS(id)
  m <- getOption("stance.models")
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(
      width = 400,
      tags$h5("1. Connect to the model"),
      tags$p(class = "small mb-1", "Labels: ", tags$code(m$label$model),
             if (length(m$helpers)) tagList(". Helpers: ", tags$code(
               paste(purrr::map_chr(m$helpers, "model"), collapse = ", ")))),
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
      tags$p(class = "small text-muted",
             "To add labels to an earlier run, upload its file with labels."),
      uiOutput(ns("cols")),
      tags$h5("3. What to measure"),
      selectInput(ns("scheme"), NULL, width = "100%",
                  choices = stats::setNames(names(stance_schemes),
                                            purrr::map_chr(stance_schemes, "name"))),
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
      tags$h5("4. Label a sample"),
      numericInput(ns("n"), "Requests to send each model now", width = "100%", min = 3, step = 10,
                   value = getOption("stance.batch", 30L), max = m$label$limit),
      uiOutput(ns("ready")),
      actionButton(ns("go"), "Label passages", class = "btn-primary w-100"),
      tags$hr(),
      tags$h5("5. Download"),
      downloadButton(ns("dl_data"), "Your file with labels (CSV)",
                     class = "btn-outline-secondary w-100 mb-2"),
      downloadButton(ns("dl_est"), "Estimates (CSV)",
                     class = "btn-outline-secondary w-100 mb-2"),
      downloadButton(ns("dl_sheet"), "Passages to code by hand (CSV)",
                     class = "btn-outline-secondary w-100"),
      tags$p(class = "small text-muted mt-2",
             "Keep the file with labels: it holds the sample. Upload it again to add ",
             "labels on another day, or with the coded sheet to check the labels. ",
             "The app keeps nothing.")),
    uiOutput(ns("preview")),
    bslib::card(
      bslib::card_header(textOutput(ns("title"), inline = TRUE)),
      uiOutput(ns("summary")),
      uiOutput(ns("results")),
      uiOutput(ns("overall_head")),
      tableOutput(ns("overall")),
      uiOutput(ns("groups_head")),
      tableOutput(ns("groups")),
      uiOutput(ns("checks_head")),
      tableOutput(ns("checks")),
      tags$p(class = "small text-muted",
             "Intervals are 95 percent. They carry the sampling and the grouping of ",
             "passages in documents. They do not include error in the model's labels; ",
             "the Check the labels page is how to measure that.")))
}

# ---- Check the labels: the page --------------------------------------------------

mod_stance_check_ui <- function(id) {
  ns <- NS(id)
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(
      width = 400,
      tags$h5("1. Code the sheet by hand"),
      tags$p(class = "small",
             "Open the sheet from Detect stance. Put one of the ",
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
             "so they must come from the same run. Any day will do. A sheet from ",
             "before you added labels still matches.")),
    bslib::card(
      bslib::card_header("How many to code"),
      tags$p("The sheet holds the passages the model labeled, up to 400. Code as many ",
             "as you can: 100 hand codes put the overall agreement within about 10 ",
             "percentage points, 400 within about 5. That is enough to see whether the ",
             "labels are usable. It is ", tags$strong("not"), " enough to say much about ",
             "a label the model rarely uses: 20 cases carry an uncertainty of roughly ",
             "18 points. Read the per-label rows with their counts, and treat a row ",
             "marked thin as a hint, not a measurement."),
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
             "Rows are your labels, columns the model's, in counts of passages. The ",
             "diagonal is where you agreed."),
      tableOutput(ns("confusion")),
      tags$h6("By label"),
      tableOutput(ns("by_label")),
      tags$p(class = "small text-muted",
             tags$strong("Recall"), " is the share of your passages with that ",
             "label that the model also gave it. ", tags$strong("Precision"),
             " is the share of the model's passages with that label that you ",
             "agreed on.")))
}

# ---- the server ------------------------------------------------------------------

mod_stance_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    d0 <- stance_defaults
    workers <- max(1L, as.integer(getOption("stance.workers", 1L)))
    lab_model <- getOption("stance.models")$label
    chat_ids <- purrr::map_chr(chat_models(getOption("stance.models")), "model")
    k <- max(1L, as.integer(getOption("stance.per_request", 10L)))
    notify <- function(msg, type = "warning")
      showNotification(msg, type = type, duration = if (type == "error") NULL else 5)

    # ---- the key and the connection ------------------------------------------
    # key() is the pasted key, conn() the endpoint once a check has passed. A new
    # or forgotten key clears conn(), so a run never uses a key that was not
    # checked. used() counts the requests this session sent each chat model.
    key <- reactiveVal(NULL)
    conn <- reactiveVal(NULL)
    conn_msg <- reactiveVal(NULL)
    used <- reactiveVal(stats::setNames(numeric(length(chat_ids)), chat_ids))
    spend <- function(calls) used(replace(used(), names(calls), used()[names(calls)] + calls))
    disconnect <- function() {
      conn(NULL)
      conn_msg(NULL)
    }
    observeEvent(input$use_key, {
      k <- trimws(input$key %||% "")
      updateTextInput(session, "key", value = "")
      if (!nzchar(k)) return(notify("Nothing pasted."))
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
      res <- withProgress(message = "Checking the models", value = 0.5, stance_check(ep))
      spend(stats::setNames(rep(1, length(chat_ids)), chat_ids))  # one request to each
      conn(if (res$ok) ep)
      conn_msg(res)
    })
    output$conn <- renderUI({
      m <- conn_msg()
      tagList(
        if (is.null(m)) tags$p(class = "small text-muted mt-2", "Check the connection before a run.") else
          tags$p(class = paste("small mt-2", if (m$ok) "text-success" else "text-danger"), m$message),
        tags$p(class = "small text-warning",
          paste0("Your passages go to ", httr2::url_parse(getOption("stance.base_url"))$hostname,
                 ": upload only text that may go there.")))
    })

    purrr::iwalk(stance_examples, function(x, i)
      observeEvent(input[[paste0("ex", i)]], updateTextAreaInput(session, "prop", value = x)))

    sch <- reactive(stance_scheme(input$scheme %|_|% "favor"))
    output$scheme_help <- renderUI({
      s <- sch()
      means <- c(s$means, irrelevant = "does not address the claim")
      tags$div(class = "small text-muted mb-2",
        tags$p(class = "mb-1", s$use),
        tags$ul(class = "mb-0", purrr::map(stance_codes(s), function(l)
          tags$li(tags$strong(l, .noWS = "after"), ": ", means[[l]]))))
    })

    # ---- the uploaded file ---------------------------------------------------
    raw <- reactive({
      f <- req(input$file)
      out <- tryCatch(readr::read_csv(f$datapath, show_col_types = FALSE,
                                      progress = FALSE, guess_max = 10000),
                      error = function(e) e)
      if (inherits(out, "error")) {
        notify(paste("The file could not be read:", conditionMessage(out)), "error")
        return(NULL)
      }
      if (!nrow(out)) {
        notify("That file has no rows.", "error")
        return(NULL)
      }
      out
    })
    # An uploaded file with labels: the run it holds, and its claim on screen.
    saved <- reactive(if (!is.null(raw())) stance_saved(raw()))
    observeEvent(saved(), {
      s <- saved()
      if (!is.na(s$scheme) && s$scheme %in% names(stance_schemes))
        updateSelectInput(session, "scheme", selected = s$scheme)
      updateTextAreaInput(session, "prop", value = s$claim %|_|% "")
      updateTextInput(session, "kind", value = s$kind %|_|% "short text passages")
    })

    output$cols <- renderUI({
      r <- raw()
      if (is.null(r)) return(NULL)
      ns <- session$ns
      nm <- names(r)[!startsWith(names(r), "stance_")]  # the columns the app added
      was <- c(saved()$columns, "", "", "")[1:3]  # the columns of the earlier run
      # the longest character column is almost always the text
      chr <- nm[purrr::map_lgl(r[nm], function(x) is.character(x) | is.factor(x))]
      wide <- purrr::map_dbl(r[chr], function(x)
        suppressWarnings(mean(nchar(as.character(x)), na.rm = TRUE)))
      wide[!is.finite(wide)] <- -1
      guess <- if (length(chr)) chr[[which.max(wide)]] else nm[[1]]
      tagList(
        selectInput(ns("text_col"), "Text column", choices = nm,
                    selected = if (was[1] %in% nm) was[1] else guess),
        selectInput(ns("time_col"), "Time column (optional)",
                    choices = c("none" = "", nm), selected = was[2]),
        selectInput(ns("doc_col"), "Document column (optional)",
                    choices = c("each row is independent" = "", nm), selected = was[3]))
    })

    # One row per uploaded row: text, document, time, and whether it is coded.
    prep <- reactive({
      r <- raw()
      req(r, input$text_col)
      out <- tryCatch(stance_prepare(r, input$text_col, input$time_col %||% "",
                                     input$doc_col %||% ""),
                      error = function(e) e)
      if (inherits(out, "error")) {
        notify(conditionMessage(out), "error")
        return(NULL)
      }
      out
    })

    output$preview <- renderUI({
      p <- prep()
      if (is.null(p)) return(NULL)
      n_keep <- sum(p$keep)
      drops <- dplyr::count(dplyr::filter(p, !keep), why, name = "rows")
      big <- function(x) format(x, big.mark = ",")
      bslib::card(
        bslib::card_header("Your file"),
        bslib::layout_columns(
          bslib::value_box("Rows", big(nrow(p))),
          bslib::value_box("Within the word bounds", big(n_keep)),
          bslib::value_box("Documents", big(dplyr::n_distinct(p$cluster[p$keep]))),
          bslib::value_box("Periods", if ("time" %in% names(p))
            big(dplyr::n_distinct(p$period[p$keep])) else "none")),
        if (nrow(drops)) tagList(
          tags$p(class = "small mb-1", "Rows set aside:"),
          tags$ul(class = "small", purrr::map2(drops$why, drops$rows, function(w, n)
            tags$li(big(n), " ", w)))),
        if (n_keep) tagList(
          tags$p(class = "small text-muted",
                 sprintf("Words per passage: median %s, range %s to %s.",
                         stats::median(p$n_words[p$keep]),
                         min(p$n_words[p$keep]), max(p$n_words[p$keep]))),
          tags$p(class = "small", tags$strong("First passage: "),
                 substr(p$text[p$keep][1], 1, 400))))
    })

    # ---- the sample ----------------------------------------------------------
    # frame() holds the passages to code with their group, draw and labels, and
    # what they were labeled for. It carries on when the next request is for the
    # same passages, claim, scheme and description; anything else starts anew.
    frame <- reactiveVal(NULL)
    setup <- function(todo, s, prop, kind)
      list(text = todo$text, scheme = s$id, prop = prop, kind = kind, model = lab_model$model)

    # The frame the next run adds to: this session's, else the uploaded file's,
    # else NULL for a new sample.
    carried <- function(todo, now) {
      f <- frame()
      if (!is.null(f) && identical(f$setup, now)) return(f)
      s <- saved()
      if (is.null(s)) return(NULL)
      same <- identical(list(s$scheme, s$claim, s$kind, s$model),
                        list(now$scheme, now$prop, now$kind, now$model)) &&
        setequal(s$frame$stance_row, todo$stance_row)
      if (!same) return(NULL)
      list(setup = now, run = s$run,
           d = dplyr::left_join(dplyr::select(todo, stance_row, text), s$frame, by = "stance_row"))
    }

    output$ready <- renderUI({
      p <- prep()
      if (is.null(p)) return(tags$p(class = "small text-muted", "Upload a CSV to start."))
      n <- sum(p$keep)
      if (n == 0) return(tags$p(class = "small text-danger", "No row is within the word bounds."))
      ask <- max(input$n %||% 0, 0, na.rm = TRUE)
      solo <- if (k > 1) min(getOption("stance.solo_n", 10L), ask %/% 3) else 0
      n_lab <- (ask - solo) * k
      tagList(
        tags$p(class = "small text-muted", sprintf(
          "%s passages to estimate from. %s request(s), %s passages to a request: %s labels up to %s passages%s. That puts a share near one half within about %.0f points either way; ask again to add more.",
          format(n, big.mark = ","), ask, k, lab_model$model, format(n_lab, big.mark = ","),
          if (length(chat_ids) > 1) sprintf(", and the helpers read up to %s",
                                            format((length(chat_ids) - 1) * ask * k, big.mark = ",")) else "",
          98 / sqrt(max(n_lab, 1)))),
        tags$p(class = "small text-muted", sprintf(
          "Each model allows %s requests every %s. Sent this session: %s.",
          lab_model$limit, fmt_dur(lab_model$window_secs),
          paste0(names(used()), " ", used(), collapse = ", "))),
        if (!is.null(saved())) tags$p(class = "small text-success", sprintf(
          "This file holds %s labels from %s. The same claim, scheme and description add to them.",
          sum(!is.na(saved()$frame$label)), saved()$run)),
        if (is.null(conn())) tags$p(class = "small text-danger",
                                    "Check the connection first (step 1)."))
    })

    # ---- the run -------------------------------------------------------------
    run <- reactiveVal(NULL)
    observeEvent(input$go, {
      p <- prep()
      if (is.null(p)) return(notify("Upload a CSV first."))
      s <- sch()
      prop <- trimws(input$prop %||% "")
      kind <- trimws(input$kind %||% "") %|_|% "short text passages"
      n <- suppressWarnings(as.integer(input$n))
      if (lengths(strsplit(prop, "\\s+")) < 5) return(notify("Write the claim as a full sentence."))
      if (!sum(p$keep)) return(notify("No passage is within the word bounds."))
      if (is.na(n) || n < 3) return(notify("Send each model at least 3 requests."))
      n <- min(n, lab_model$limit)
      ep <- conn()
      if (is.null(ep)) return(notify("Check the connection to the model first."))
      todo <- dplyr::filter(p, keep)
      prompt <- stance_prompt(s, prop, kind)
      now <- setup(todo, s, prop, kind)
      t0 <- Sys.time()
      step <- function(stage, i, k) setProgress(i / k, message = stage, detail = sprintf("%s of %s", i, k))
      f <- withProgress(message = "Reading passages", value = 0, tryCatch({
        f <- carried(todo, now) %||% list(
          setup = now, run = stance_run_id(lab_model$model),
          # a file small enough to label whole needs no screen
          d = dplyr::bind_cols(dplyr::select(todo, stance_row, text), stance_frame(
            if (dplyr::n_distinct(todo$text) > (n - 3L) * k) stance_similarity(
              todo$text, prop, ep, workers, function(i, m) step("Screening passages", i, m)) else
              rep(NA_real_, nrow(todo)))))
        f$d <- stance_run(f$d, n, prompt, ep, s, k, workers = workers, on_step = step)
        f
      }, error = function(e) {
        notify(conditionMessage(e), "error")
        NULL
      }))
      req(f)
      frame(f)
      spend(attr(f$d, "calls"))
      d <- f$d
      d$w <- stance_weights(d)
      full <- dplyr::bind_cols(dplyr::select(todo, -why, -text, -stance_row), d)
      coded <- dplyr::filter(full, !is.na(label))
      # with helpers, the shares come from the passages both read, corrected
      # over everything the helpers read; without, from the labeled sample
      a <- stance_assist(d, s)
      static <- if (is.null(a)) stance_static(coded, s) else
        stance_static(full[a$both, ], s, c(a, list(cluster = full$cluster[a$rows])))
      trends <- if ("time" %in% names(coded)) stance_trends(coded, s) else NULL
      counts <- list(total = nrow(p), frame = nrow(d), labeled = nrow(coded),
                     helper = sum(!is.na(d$helper)), groups = max(d$stratum),
                     documents = dplyr::n_distinct(coded$cluster), per_request = k,
                     assisted = !is.null(a))
      labeled <- raw() |>
        dplyr::select(!dplyr::starts_with("stance_")) |>
        dplyr::mutate(stance_run = f$run, stance_row = dplyr::row_number()) |>
        dplyr::left_join(dplyr::transmute(
          d, stance_row, stance_label = label, stance_weight = w, stance_stratum = stratum,
          stance_draw = draw, stance_similarity = similarity, stance_solo = solo,
          stance_helper = helper, stance_helper_model = helper_model,
          stance_note = why), by = "stance_row") |>
        dplyr::left_join(dplyr::select(p, stance_row, stance_words = n_words,
                                       stance_excluded = why), by = "stance_row") |>
        dplyr::mutate(stance_scheme = s$id, stance_claim = prop, stance_kind = kind,
                      stance_model = lab_model$model, stance_date = as.character(Sys.Date()),
                      stance_columns = paste(input$text_col, input$time_col %||% "",
                                             input$doc_col %||% "", sep = "|"))
      run(list(scheme = s, prop = prop, counts = counts, coded = coded, static = static,
               trends = trends, groups = stance_groups(d), calls = attr(d, "calls"),
               unlabeled = stats::na.omit(d$why[is.na(d$label)]),
               checks = stance_checks(d, s), run_notes = attr(d, "notes"),
               notes = attr(trends, "notes"),
               minutes = as.numeric(difftime(Sys.time(), t0, units = "mins")),
               # the three files, built once so the buttons only write them
               labeled = labeled,
               estimates = stance_record(stance_table(static, trends), s, prop, prompt, ep, counts),
               sheet = stance_sheet(coded, s, prop, f$run)))
    })

    # ---- results -------------------------------------------------------------
    output$title <- renderText(
      if (is.null(run())) "Results appear here" else run()$prop)

    output$summary <- renderUI({
      r <- req(run())
      big <- function(x) format(x, big.mark = ",")
      left <- r$counts$frame - r$counts$labeled
      tagList(
        tags$p(sprintf(
          "%s labeled %s of %s passages, from %s document(s)%s. Requests this run: %s, in %s.",
          lab_model$model, big(r$counts$labeled), big(r$counts$frame), big(r$counts$documents),
          if (r$counts$helper) sprintf("; the helpers read %s", big(r$counts$helper)) else "",
          paste0(names(r$calls), " ", r$calls, collapse = ", "), fmt_dur(r$minutes * 60))),
        tags$p(class = "small", if (left > 0) sprintf(
          "The labels are a random sample, weighted to stand for all %s passages. To narrow the intervals, press Label passages again: it adds to this sample.",
          big(r$counts$frame)) else "Every passage is labeled, so nothing is estimated from a sample."),
        tags$p(class = "small", if (r$counts$assisted) paste(
          "The shares below use the helpers: their labels are totaled over everything they",
          "read, and the passages", lab_model$model, "also read measure and correct their error.") else
          if (length(chat_ids) > 1 && left > 0) sprintf(
            "The shares below rest on %s alone: the helpers are used once %d passages have been read by both.",
            lab_model$model, d0$min_assist_n)),
        if (length(r$run_notes)) tags$ul(class = "small text-danger", purrr::map(r$run_notes, tags$li)),
        # passages the model was sent without getting a label; say why, one line
        # per kind of reason with its first instance
        if (length(r$unlabeled)) {
          kinds <- split(r$unlabeled, sub(":.*", "", r$unlabeled))
          tagList(
            tags$p(class = "small text-danger mb-1", sprintf(
              "%s sampled passage(s) have no label yet:", big(length(r$unlabeled)))),
            tags$ul(class = "small text-danger", purrr::imap(kinds, function(w, k)
              tags$li(big(length(w)), " ", k, ", e.g. ",
                      substr(sub("^[^:]*: ", "", w[1]), 1, 200)))))
        },
        if (!stance_has_trend(r$trends)) tags$p(class = "small",
          tags$strong("Static estimate. "),
          if ("time" %in% names(r$coded))
            sprintf("A trend needs %d labeled passages over %d periods.", d0$min_trend_n,
                    d0$min_periods) else "No time column, so there is nothing to trend."),
        if (length(r$notes)) tags$ul(class = "small text-muted", purrr::map(r$notes, tags$li)))
    })

    output$results <- renderUI({
      r <- req(run())
      ns <- session$ns
      if (!stance_has_trend(r$trends)) return(plotOutput(ns("plot_static"), height = 260))
      tagList(plotOutput(ns("plot_sal"), height = 260), tags$hr(),
              plotOutput(ns("plot_dir"), height = 280))
    })
    output$plot_static <- renderPlot(stance_plot_static(req(run())$static, run()$scheme))
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
      tags$h6("The whole file")
    })
    output$overall <- renderTable({
      req(run())$static |>
        dplyr::transmute(quantity, `out of` = basis, `labeled passages` = n,
                         share = pct(share), `95% low` = pct(lo), `95% high` = pct(hi))
    })
    output$groups_head <- renderUI({
      req(run())
      tagList(tags$h6("Where the claim lives"),
              tags$p(class = "small text-muted",
                     "The groups the screen made, closest to the claim first. A group ",
                     "far from the claim that still holds passages addressing it is what ",
                     "a cutoff on similarity would have missed."))
    })
    output$groups <- renderTable({
      req(run())$groups |>
        dplyr::transmute(group = stratum, similarity = dplyr::coalesce(similarity, "not screened"),
                         passages, labeled,
                         `of the labeled, address the claim` = pct(addressing / labeled),
                         `read by helpers only` = helper)
    })
    output$checks_head <- renderUI({
      if (!NROW(req(run())$checks)) return(NULL)
      tagList(tags$h6("Do other readings agree?"),
              tags$p(class = "small text-muted",
                     "Against ", lab_model$model, "'s labels, on the passages both read. The first ",
                     "row is the same model reading a passage alone: if it disagrees with itself, ",
                     "several passages to a request is changing the answer, so set ",
                     tags$code("stance.per_request"), " to 1. The others compare models; none ",
                     "of this replaces hand coding."))
    })
    output$checks <- renderTable({
      ch <- req(run())$checks
      if (!NROW(ch)) return(NULL)
      dplyr::transmute(ch, reading, passages, agreement = pct(agree),
                       kappa = sprintf("%.2f", kappa),
                       `95%` = sprintf("%.2f to %.2f", kappa_lo, kappa_hi))
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
      labeled <- read_up(req(input$labeled))
      sheet <- read_up(req(input$hand))
      fail <- function(msg) {
        notify(msg, "error")
        NULL
      }
      if (inherits(labeled, "error"))
        return(fail(paste("The labeled file could not be read:", conditionMessage(labeled))))
      if (inherits(sheet, "error"))
        return(fail(paste("The sheet could not be read:", conditionMessage(sheet))))
      m <- tryCatch(stance_match(labeled, sheet), error = function(e) e)
      if (inherits(m, "error")) return(fail(conditionMessage(m)))
      if (length(attr(m, "ignored")))
        notify(paste("Ignoring labels that are not in this scheme:",
                     paste(attr(m, "ignored"), collapse = ", ")))
      a <- tryCatch(stance_agreement(m$hand_label, m$label, m$document, attr(m, "scheme"), m$w),
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
          "Agreement and kappa are weighted like the estimates, so they describe the ",
          "whole file and not only the sample, which leans toward passages close to ",
          "the claim. Intervals come from a bootstrap over documents. Kappa is ",
          "agreement beyond what the two of you would reach by chance given how ",
          "often each label is used; it falls well below raw agreement whenever one ",
          "label dominates."),
        if (!is.na(k) && k < 0.4) tags$p(class = "text-danger",
          "Kappa under 0.40: the labels disagree with you often enough that the ",
          "estimates should not be reported without saying so. Read the confusion ",
          "matrix, reword the claim, and run it again."))
    })

    output$confusion <- renderTable({
      m <- as.data.frame.matrix(req(check())$confusion)
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

# ---- Start here ----------------------------------------------------------------
# What the method is and why, how to use the tool and shape a file for it, a
# picture of the steps, the prompt, and how to write a claim the model can code.

li_conrad <- tags$a(
  href = "https://arxiv.org/abs/2406.07483", target = "_blank",
  "Li and Conrad 2024", .noWS = "outside")

# bold text followed by punctuation, without the space HTML would put between
b_ <- function(x) tags$strong(x, .noWS = "after")

stance_help_ui <- function() {
  d <- stance_defaults
  tagList(
    stance_flow_css(),
    bslib::layout_columns(
      col_widths = c(7, 5),
      bslib::card(
        bslib::card_header("What this tool does"),
        tags$p(
          tags$strong("Stance detection"), " measures where writers stand on a ",
          "claim. You give the tool a file of short passages and one sentence that ",
          "states a position. A language model reads a random sample of the passages ",
          "and gives each one of the labels of the scheme you ",
          "choose (favor, neutral, oppose, for the default), or marks it as not addressing the ",
          "claim at all. The sample is weighted back to the whole file and becomes two ",
          "kinds of estimate, each with a 95 percent interval: ", b_("salience"),
          ", the share of all passages that address the claim, and ", b_("direction"),
          ", the shares of each label among the passages that do. When the passages ",
          "are dated, both are traced over time."),
        tags$p(
          "It is needed because the alternatives do not scale or do not measure the ",
          "right thing. Coding tens of thousands of passages by hand is slow and ",
          "costly, and counting keywords confuses mentioning an issue with taking a ",
          "side on it. A model applies the same written rule to every passage it ",
          "reads, so the measurement can be repeated and a claim can be tracked as ",
          "new text arrives. Each model may be sent only 300 requests in four hours, ",
          "which is why the tool samples, sends several passages in a request, and ",
          "lets other models help: a well-chosen sample ",
          "estimates a file of any size, the way a survey estimates a population, and ",
          "you can add labels later to narrow the intervals. It is still an ",
          "instrument with error: models agree with ",
          "people when a position is stated plainly and disagree when it has to be ",
          "inferred (", li_conrad, "). That is why every run produces a sheet for ",
          "people to code by hand, and why the agreement belongs in any report."),
        tags$p(
          "For our work, this turns comments, speeches, and open-ended answers into ",
          "numbers that can sit beside survey estimates: whether an issue is gaining ",
          "attention, whether opinion on it is moving, and whether the two move ",
          "together. Because the analyst writes the claim, one corpus can answer many ",
          "questions, and a claim drafted from a topic model can be tested the same ",
          "day. The estimates describe the text in the file, not a population. Their ",
          "intervals carry the sampling but leave out labeling error, so they are best used to compare ",
          "over time and to decide where to look closer, reported together with the ",
          "hand-coded agreement.")),
      bslib::card(
        bslib::card_header("How it works"),
        stance_flowchart())),
    stance_scheme_card(),
    stance_prompt_card(),
    bslib::layout_columns(
      col_widths = c(7, 5),
      bslib::card(
        bslib::card_header("Using the tool"),
        tags$ol(
          tags$li(tags$strong("Prepare a CSV"), " in the format below."),
          tags$li("On ", b_("Detect stance"), ": paste your API key, ",
                  "press ", b_("Use this key"), ", then ", b_("Check connection"),
                  ". A run stays locked until the check passes. The key stays in your ",
                  "session only; it is not saved or written into any file."),
          tags$li("Upload the CSV, pick the columns, ",
                  "choose what to measure, write the claim, ",
                  "describe the passages in a few words, and run."),
          tags$li(tags$strong("Start small."), " Send each model a few dozen requests, read ",
                  "the estimates and their intervals, and send more if they are too wide. ",
                  "Each round adds to the same sample; nothing is labeled twice."),
          tags$li(tags$strong("Download all three files."), " Your file with a ",
                  tags$code("stance_label"), " column, the estimates, and a sheet of the ",
                  "labeled passages to code by hand. Keep the first one: it holds the ",
                  "sample. Upload it again another day to add labels to it, and the ",
                  "check needs it."),
          tags$li("Code the sheet by hand, without looking at the model's labels, ",
                  "which the sheet leaves out on purpose. Its choose_from column ",
                  "lists the labels you may use."),
          tags$li("On ", b_("Check the labels"), ", any day later: upload the ",
                  "file with labels and the coded sheet. Both carry the same run id, ",
                  "which is how they are matched; the app remembers nothing between ",
                  "visits.")),
        tags$h6("Your file"),
        tags$p(class = "small", "A CSV with a header row, one passage per row. Any other ",
               "columns are kept and come back untouched in the labeled file."),
        tags$dl(class = "small",
          tags$dt("Text (required)"),
          tags$dd(sprintf("A paragraph, between %d and %d words.", d$min_words, d$max_words),
                  " One label has to describe the whole passage, and a paragraph usually ",
                  "holds one position where a whole document holds several. Shorter ",
                  "rows rarely carry a stance, and longer ones may run past what the ",
                  "model reads. Rows outside the bounds are reported and left uncoded."),
          tags$dt("Time (optional)"),
          tags$dd("A year (", tags$code("2026"), "), a month (", tags$code("2026-08"),
                  "), or a date. Needed for a trend. A trend needs at least ",
                  d$min_trend_n, " labeled passages over at least ", d$min_periods,
                  " periods; with fewer, or no time column, the estimate is one ",
                  "number for the whole file, because a line through a handful of ",
                  "passages would show noise as change."),
          tags$dt("Document (optional)"),
          tags$dd("The comment, speech, or respondent a passage came from. Passages ",
                  "from one source tend to agree, so treating them as independent ",
                  "makes the intervals too narrow. Leave it blank only when every row ",
                  "really is a separate writer.")),
        tags$p(class = "small text-muted",
               "Every passage is sent to the embedding model, and the sampled ones to ",
               "the labeling model and the helpers. Upload only text you are permitted to send there.")),
      bslib::card(
        class = "border-primary",
        bslib::card_header(class = "bg-primary text-white", "Writing a good claim"),
        tags$ul(class = "small",
          tags$li(tags$strong("State one side, in one sentence. "),
                  tags$em("“The proposed rule should be withdrawn.”"),
                  " Not a question, not two claims, not “X rather than Y”."),
          tags$li(tags$strong("Ask about opinion, not knowledge. "),
                  "Models matched human coders far better on whether a writer favored a ",
                  "policy than on whether the writer knew a fact about it."),
          tags$li(tags$strong("Pick a claim writers state outright. "),
                  "Agreement is highest when the position is explicit and falls when it ",
                  "must be inferred. Read a dozen passages first: could a person tell the ",
                  "position without guessing?"),
          tags$li(tags$strong("Expect opposition to be harder. "),
                  "In that study, opposing views were more often implied than stated, ",
                  "and models caught them less often. Read the oppose row of the agreement table before ",
                  "trusting the oppose line."),
          tags$li(tags$strong("Pilot, then add. "),
                  "Send a handful of requests, read the labels in the downloaded file, and reword ",
                  "the claim before spending more requests on it."),
          tags$li(tags$strong("Test the wording. "),
                  "Run a paraphrase. If the answer moves, it depends on the wording, not ",
                  "only on the writers.")),
        tags$p(class = "small text-muted mb-0",
               "Points 2 to 5 follow ", li_conrad, ": ",
               tags$em("Advancing annotation of stance in social media posts: A ",
                       "comparative analysis of large language models and crowd ",
                       "sourcing", .noWS = "after"), ", arXiv:2406.07483."))))
}

# ---- choosing what to measure ------------------------------------------------
# Generated from stance_schemes, so a scheme added there appears here.

stance_scheme_card <- function() {
  one <- function(s) tags$tr(
    tags$td(tags$strong(s$name)),
    tags$td(tags$code(paste(s$labels, collapse = " / ")), " + ", tags$code("irrelevant")),
    tags$td(s$use))
  bslib::card(
    bslib::card_header("Choosing what to measure"),
    tags$p("Pick the scheme on ", b_("Detect stance"), ". The prompt the model ",
           "receives is built from it, so the labels, their definitions, and the ",
           "rules the model follows all change with the choice. The prompt is ",
           "saved with the estimates."),
    tags$table(class = "table table-sm small",
      tags$thead(tags$tr(tags$th("Scheme"), tags$th("Labels"), tags$th("Use it for"))),
      tags$tbody(purrr::map(unname(stance_schemes), one))),
    tags$ul(class = "small",
      tags$li(tags$strong("Check before relying on a scheme. "),
              "Agree and aligned use the same design as favor with different words. ",
              "How well models match people on them has not been checked here, so ",
              "run the hand check first."),
      tags$li(tags$strong("Changing the scheme changes the prompt. "),
              "Labels saved under another scheme or wording are not comparable, so ",
              "a changed claim, scheme, or description starts a new sample.")))
}

# ---- the flowchart -----------------------------------------------------------
# Plain HTML boxes and arrows, so it needs no package and follows the theme.

stance_flow_step <- function(n, title, ..., dashed = FALSE)
  div(class = paste("sf-step", if (dashed) "sf-later"),
      div(class = "sf-num", n),
      div(tags$strong(title), div(class = "small text-muted", ...)))

stance_flow_arrow <- function() div(class = "sf-arrow", "↓")

stance_flowchart <- function() {
  d <- stance_defaults
  div(class = "sf",
    stance_flow_step(1, "Your CSV", "One passage per row: text, and optionally time ",
                     "and document. ", sprintf("Passages under %d or over %d words are set ",
                                               d$min_words, d$max_words), "aside."),
    stance_flow_arrow(),
    stance_flow_step(2, "Screen", "An embedding model measures how close every passage ",
                     sprintf("sits to the claim and sorts them into %d groups. ", length(d$strata)),
                     "Nothing is dropped."),
    stance_flow_arrow(),
    stance_flow_step(3, "Sample and label", "The labeling model reads a random sample from ",
                     "every group, the same number from each, so the passages close to the ",
                     "claim are read most closely. Several passages go in each request."),
    stance_flow_arrow(),
    stance_flow_step(4, "Helpers", "Other models read the same passages and more. The ",
                     "labeling model's sample measures their error and corrects it, so ",
                     "they narrow the intervals without being trusted."),
    stance_flow_arrow(),
    stance_flow_step(5, "Weigh and estimate", "Each label stands for the unread passages ",
                     "of its group. Salience out of all passages; each label out of those ",
                     "that address the claim. Intervals carry the sampling and the documents."),
    div(class = "sf-branch",
        div(class = "sf-leaf", tags$strong("Trend"), div(class = "small text-muted",
            sprintf("dated, %d+ labels over %d+ periods", d$min_trend_n, d$min_periods))),
        div(class = "sf-leaf", tags$strong("Static"), div(class = "small text-muted",
            "otherwise: one number for the file"))),
    stance_flow_arrow(),
    stance_flow_step(6, "Download, or label more", "The file with labels, the estimates, ",
                     "and a sheet to code by hand. More labels narrow the intervals."),
    stance_flow_arrow(),
    stance_flow_step(7, "Check, later", "Upload the file with labels and the coded ",
                     "sheet: agreement, kappa, and where the model and you differ.",
                     dashed = TRUE))
}

stance_flow_css <- function() tags$style(HTML("
.sf { display: flex; flex-direction: column; }
.sf-step { display: flex; gap: .75rem; align-items: flex-start; padding: .5rem .75rem;
  border: 1px solid var(--bs-border-color); border-radius: .5rem;
  background: var(--bs-body-bg); }
.sf-later { border-style: dashed; }
.sf-num { flex: 0 0 1.6rem; height: 1.6rem; border-radius: 50%;
  background: var(--bs-primary); color: #fff; font-size: .8rem; font-weight: 600;
  display: flex; align-items: center; justify-content: center; margin-top: .1rem; }
.sf-later .sf-num { background: var(--bs-secondary); }
.sf-arrow { text-align: center; color: var(--bs-secondary-color); line-height: 1.1;
  font-size: 1.1rem; }
.sf-branch { display: flex; gap: .5rem; margin: .35rem 0 0 2.35rem; }
.sf-leaf { flex: 1; padding: .35rem .6rem; border-left: 3px solid var(--bs-primary);
  background: var(--bs-tertiary-bg); border-radius: .25rem; font-size: .9rem; }
"))

# ---- the prompt card -----------------------------------------------------------
# Prints the prompt exactly as the model receives it, one tab per scheme, built
# by the same stance_prompt() a run uses, so the page cannot drift from the code.

stance_prompt_card <- function() {
  m <- getOption("stance.models")
  tab <- function(s) bslib::nav_panel(
    s$name,
    tags$pre(class = "small mb-0 sp-pre", stance_prompt(s, "<your claim>", "<what the passages are>")))
  bslib::card(
    bslib::card_header("The prompt"),
    tags$style(HTML(".sp-pre { white-space: pre-wrap; background: var(--bs-tertiary-bg);
      padding: .75rem; border-radius: .375rem; }")),
    bslib::layout_columns(
      col_widths = c(7, 5),
      tags$div(
        tags$p(class = "small",
               "Every request carries this prompt as the system message. The ",
               "words in angle brackets are what you type on ", b_("Detect stance"),
               ". The passages follow as the user message, numbered, ",
               tags$code("Text 1: <a passage>", .noWS = "after"), ", ",
               sprintf("%s to a request in shuffled order, ", getOption("stance.per_request", 10)),
               "with no date and no document."),
        do.call(bslib::navset_card_underline,
                purrr::map(unname(stance_schemes), tab)),
        tags$p(class = "small text-muted mt-2 mb-0",
               tags$code(m$embed$model), " places the claim and every passage, which only ",
               "decides how closely each part of the file is sampled. ",
               tags$code(m$label$model), " labels the sampled passages with thinking off and a ",
               "short reply; its labels are the ones the estimates rest on. ",
               if (length(m$helpers)) tagList(
                 tags$code(paste(purrr::map_chr(m$helpers, "model"), collapse = ", ")),
                 " get the same prompt and read the same passages and more. "),
               "Claude models run at their default sampling (they take no temperature ",
               "setting); open models at temperature 0. The label after each number in the ",
               "reply is that passage's label; a number without one is left unlabeled and ",
               "reported. The full prompt and the models are saved with the estimates."),
        ),
      tags$div(
        tags$h6("Why it is written this way"),
        tags$ul(class = "small",
          tags$li(tags$strong("Relevance first, then direction. "),
                  "The model first decides whether the passage addresses the claim at ",
                  "all. That one step is what separates salience (is the claim ",
                  "discussed?) from direction (which way?), so a passage on another ",
                  "subject is never forced into favor or oppose."),
          tags$li(tags$strong("Every label is defined in the prompt. "),
                  "The model reads the same definitions a hand coder gets, so the two ",
                  "can be compared on Check the labels."),
          tags$li(tags$strong("Stance is not tone. "),
                  "An angry passage can favor the claim. The rule tells the model ",
                  "not to read negative wording as opposition."),
          tags$li(tags$strong("Ambiguous means neutral. "),
                  "Doubtful cases go to neutral rather than to a guessed side, so ",
                  "favor and oppose hold passages that take one."),
          tags$li(tags$strong("Only the text shown. "),
                  "No outside knowledge of the writer or the issue, so the label ",
                  "measures what the passage says, not what the model knows about it."),
          tags$li(tags$strong("The passage is data, not instructions. "),
                  "Comments can contain text that reads like an order to the model; ",
                  "the rule keeps it from being followed."),
          tags$li(tags$strong("One word per passage. "),
                  "A one-word label can be read without judgment. Passages go without ",
                  "their date, so a trend cannot come from the model knowing the year."),
          tags$li(tags$strong("Several to a request, each judged alone. "),
                  "The limit counts requests, not passages, so sending ten at once ",
                  "gives ten times the labels. The risk is that a passage's neighbors ",
                  "sway its label. The prompt forbids it, the order is shuffled, and ",
                  "every round rereads a few passages alone and reports whether the two ",
                  "readings agree."),
          tags$li(tags$strong("One prompt for any corpus. "),
                  "Only the claim, the scheme, and a few words on what the passages ",
                  "are change between runs. The role, rules, and output never do, so ",
                  "results from different claims rest on the same instrument.")),
        tags$h6("What it has been run on"),
        tags$ul(class = "small mb-0",
          tags$li("An earlier version of the prompt, one passage per request, with Gemma: ",
                  "about 6,000 English paragraphs from public comments at work, and 951 ",
                  "paragraphs from presidential inaugural addresses at home (October 2026)."),
          tags$li("The sampling was checked by simulation on files with a known answer: ",
                  "estimates were unbiased and their 95 percent intervals held the truth ",
                  "about 95 percent of the time, also with helpers that were wrong on one ",
                  "passage in five and leaned one way. Helpers narrowed the intervals by 10 ",
                  "to 30 percent; ten passages to a request narrows them to about a third."),
          tags$li("Not yet measured on real text: whether ten passages to a request changes ",
                  "the labels. The table under the results measures it on every run."),
          tags$li("Not yet measured here: agreement with hand coding on these runs, and the ",
                  "agree and aligned schemes. Each run's agreement comes from Check the labels.")))))
}
