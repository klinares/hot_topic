# ui_stance_help.R: the Start here page. What the method is and why, how to
# use the tool and shape a file for it, a picture of the steps, and how to
# write a claim the model can code well.
#
# Deployment settings this page reads (set in app.R):
#   options(stance.tested = "...")   what the endpoint has been run on
#   options(stance.docs = "...")     where the method report lives

li_conrad <- tags$a(
  href = "https://arxiv.org/abs/2406.07483", target = "_blank",
  "Li and Conrad 2024", .noWS = "outside")

# bold text followed by punctuation, without the space HTML would put between
b_ <- function(x) tags$strong(x, .noWS = "after")

stance_help_ui <- function() {
  ep <- tryCatch(stance_endpoint(), error = function(e) list(model = NULL, url = NULL))
  docs <- getOption("stance.docs",
                    "https://github.com/klinares/hot_topic/blob/main/stance/stance.pdf")
  tested <- getOption("stance.tested", paste(
    "English paragraphs from public comments, about 50 to 80 tokens each;",
    "about 6,000 of them took ten minutes one at a time."))
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
          "states a position; a language model reads every passage on its own and ",
          "labels it with one of the labels of the scheme you choose (favor, neutral, ",
          "oppose, for the default), or as not addressing the claim at all. Those ",
          "labels become two kinds of estimate, each with a 95 percent ",
          "interval: ", b_("salience"), ", the share of all passages that ",
          "address the claim, and ", b_("direction"), ", the shares of each label ",
          "among the passages that do. When the passages are dated, both are traced ",
          "over time."),
        tags$p(
          "It is needed because the alternatives do not scale or do not measure the ",
          "right thing. Coding tens of thousands of passages by hand is slow and ",
          "costly, and counting keywords confuses mentioning an issue with taking a ",
          "side on it. A model applies the same written rule to every passage in ",
          "minutes, so the measurement can be repeated and a claim can be tracked as ",
          "new text arrives. It is still an instrument with error: models agree with ",
          "people when a position is stated plainly and disagree when it has to be ",
          "inferred (", li_conrad, "). That is why every run produces a sample for ",
          "people to code by hand, and why the agreement belongs in any report."),
        tags$p(
          "For our work, this turns comments, speeches, and open-ended answers into ",
          "numbers that can sit beside survey estimates: whether an issue is gaining ",
          "attention, whether opinion on it is moving, and whether the two move ",
          "together. Because the analyst writes the claim, one corpus can answer many ",
          "questions, and a claim drafted from a topic model can be tested the same ",
          "day. The estimates describe the text in the file, not a population, and ",
          "their intervals leave out labeling error, so they are best used to compare ",
          "over time and to decide where to look closer, reported together with the ",
          "hand-coded agreement.")),
      bslib::card(
        bslib::card_header("How it works"),
        stance_flowchart())),
    stance_scheme_card(),
    bslib::layout_columns(
      col_widths = c(7, 5),
      bslib::card(
        bslib::card_header("Using the tool"),
        tags$ol(
          tags$li(tags$strong("Prepare a CSV"), " in the format below."),
          tags$li("On ", b_("Detect stance"), ": upload it, pick the columns, ",
                  "choose what to measure, write the claim, ",
                  "describe the passages in a few words, and run."),
          tags$li(tags$strong("Download all three files."), " Your file with a ",
                  tags$code("stance"), " column, the estimates, and a sheet of 400 ",
                  "passages drawn at random. Keep the first one: the check needs it."),
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
                  "), or a date. Needed for a trend. A period needs at least ",
                  d$min_period_n, " passages and a trend at least ", d$min_periods,
                  " such periods; with fewer, or no time column, the estimate is one ",
                  "number for the whole file, because a line through a handful of ",
                  "passages would show noise as change."),
          tags$dt("Document (optional)"),
          tags$dd("The comment, speech, or respondent a passage came from. Passages ",
                  "from one source tend to agree, so treating them as independent ",
                  "makes the intervals too narrow. Leave it blank only when every row ",
                  "really is a separate writer.")),
        tags$p(class = "small text-muted",
               "Every passage is sent to the model named below. Upload only text you ",
               "are permitted to send there.")),
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
          tags$li(tags$strong("Pilot, then run. "),
                  "Run the claim on a few hundred passages, read the labels, and reword ",
                  "before running the whole file."),
          tags$li(tags$strong("Test the wording. "),
                  "Run a paraphrase. If the answer moves, it depends on the wording, not ",
                  "only on the writers.")),
        tags$p(class = "small text-muted mb-0",
               "Points 2 to 5 follow ", li_conrad, ": ",
               tags$em("Advancing annotation of stance in social media posts: A ",
                       "comparative analysis of large language models and crowd ",
                       "sourcing", .noWS = "after"), ", arXiv:2406.07483."))),
    tags$p(class = "small text-muted mt-2",
      tags$strong("Model: "),
      if (is.null(ep$model)) tags$span(class = "text-danger",
        "not configured; set stance.url and stance.model in app.R.") else
        tagList(tags$code(ep$model), " at ", tags$code(ep$url)),
      tags$br(), tags$strong("Tried on: "), tested, " ",
      tags$a(href = docs, target = "_blank", "Method report (PDF)")))
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
              "Labels saved under another scheme or wording are not comparable. In ",
              "the report (stance.qmd), delete the saved labels file when you change ",
              "scheme; the app starts fresh each run.")))
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
                     "and document."),
    stance_flow_arrow(),
    stance_flow_step(2, "Screen", sprintf("Passages under %d or over %d words are set ",
                                          d$min_words, d$max_words),
                     "aside and reported."),
    stance_flow_arrow(),
    stance_flow_step(3, "Label", "The model reads each passage alone, several at a ",
                     "time, with one of the labels of the chosen scheme or irrelevant. ",
                     "Identical passages are sent once."),
    stance_flow_arrow(),
    stance_flow_step(4, "Estimate", "Salience out of all passages; each label out of ",
                     "those that address the claim. Clustered by document."),
    div(class = "sf-branch",
        div(class = "sf-leaf", tags$strong("Trend"), div(class = "small text-muted",
            sprintf("dated, with %d+ periods of %d+ passages", d$min_periods,
                    d$min_period_n))),
        div(class = "sf-leaf", tags$strong("Static"), div(class = "small text-muted",
            "otherwise: one number for the file"))),
    stance_flow_arrow(),
    stance_flow_step(5, "Download", "The file with labels, the estimates, and 400 ",
                     "passages to code by hand."),
    stance_flow_arrow(),
    stance_flow_step(6, "Check, later", "Upload the file with labels and the coded ",
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
