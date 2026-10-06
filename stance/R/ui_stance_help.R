# ui_stance_help.R: the Start here page. Everything a user has to know before
# reading a number: what the tool does, what it has been tried on, and what it
# does not measure.
#
# The deployment settings this page reads:
#   options(stance.tested = "...")      what the endpoint has been run on
#   options(stance.docs = "...")        where the method report lives
#   options(stance.max_rows = 10000)    the largest file the app will code
#   options(stance.sec_per_passage = 0.1)  measured rate, for the time estimate

stance_help_ui <- function() {
  ep <- tryCatch(stance_endpoint(), error = function(e) list(model = NULL, url = NULL))
  docs <- getOption("stance.docs",
                    "https://github.com/klinares/hot_topic/blob/main/stance/stance.pdf")
  tested <- getOption("stance.tested", paste(
    "English paragraphs from public comments, about 50 to 80 tokens each.",
    "One run of roughly 6,000 paragraphs took about ten minutes, which is",
    "where the time estimate on the next page comes from."))
  d <- stance_defaults
  tagList(
    bslib::card(
      bslib::card_header("What this tool does"),
      tags$p("You give it a claim and a file of short text passages. A language ",
             "model reads each passage on its own and decides whether the passage ",
             "addresses the claim, and if it does, whether it favors it, opposes ",
             "it, or is neutral. Every passage is read, so nothing is sampled."),
      tags$p("You get back your file with a ", tags$code("stance"), " column ",
             "added, the estimates with 95 percent intervals, and a sheet of 400 ",
             "passages to code by hand so you can check the model's labels."),
      tags$h5("Two numbers, not one"),
      tags$p("A share of all passages mixes two different things: how much the ",
             "claim is discussed at all, and which way the writers who discuss it ",
             "lean. They are reported separately, because"),
      tags$p(class = "ms-3 mb-2",
             tags$strong("P(favor) = P(addresses the claim) × P(favor | addresses the claim)")),
      tags$ul(
        tags$li(tags$strong("Salience"), " is the share of ", tags$em("all"),
                " passages that address the claim. It says whether the claim is live."),
        tags$li(tags$strong("Favor, neutral, oppose"), " are shares of the ",
                "passages that ", tags$em("do"), " address it. They say which way."),
        tags$li("Multiply the two to get a share of all passages. Reported ",
                "together they tell you whether a rising line means more ",
                "agreement or just more discussion; a single combined share ",
                "cannot tell you that.")),
      tags$p(class = "small text-muted",
             "The cost of splitting them is that the direction estimates rest on ",
             "a smaller, uneven base. When few passages address the claim, the ",
             "app says so instead of drawing a line.")),
    bslib::card(
      bslib::card_header("Preparing your file"),
      tags$p("A CSV with one passage per row."),
      tags$dl(
        tags$dt("Text column (required)"),
        tags$dd(tags$strong("Paragraphs, not documents."), " Between ",
                d$min_words, " and ", d$max_words, " words. A whole document ",
                "usually holds several positions at once, so one label for it ",
                "means little, and a long passage can also run past the model's ",
                "context. Rows outside the bounds are reported and left uncoded. ",
                "These bounds are a guard against the wrong unit of text, not a ",
                "tested range; the tested range is much narrower (see below)."),
        tags$dt("Time column (optional)"),
        tags$dd("A numeric year (", tags$code("2026"), "), a month (",
                tags$code("2026-08"), "), or a date. With no time column the ",
                "estimate is static: one number per quantity for the whole file. ",
                "A period needs at least ", d$min_period_n, " passages to appear ",
                "in a trend, and a trend needs at least ", d$min_periods,
                " such periods. Thinner periods are dropped from the trend but ",
                "stay in the static estimate; if too few periods are left, the ",
                "result is static and time is ignored."),
        tags$dt("Document column (optional)"),
        tags$dd(tags$strong("Pick this if several passages can come from the same ",
                            "writer or document."), " Passages from one document ",
                "are correlated, and the intervals are widened to account for ",
                "it. Left blank, every row counts as independent, which makes ",
                "the intervals too narrow when they are not."))),
    bslib::card(
      bslib::card_header("What has been tried, and what has not"),
      tags$dl(
        tags$dt("Model"),
        tags$dd(if (is.null(ep$model)) tags$span(class = "text-danger",
                  "Not configured: set STANCE_URL and STANCE_MODEL.") else
                  tagList(tags$code(ep$model), " at ", tags$code(ep$url))),
        tags$dt("Tried on"),
        tags$dd(tested),
        tags$dt("Not measured"),
        tags$dd(tags$strong("How often the model's label is right."), " The ",
                "intervals cover only the variation of the shares themselves. ",
                "They assume the labels are correct, and a model that is ",
                "systematically wrong in one direction will produce a confident ",
                "interval around the wrong number. The ",
                tags$strong("Check the labels"), " page is how you find out: ",
                "code 400 passages by hand and compare."),
        tags$dt("Not a sample"),
        tags$dd("There are no weights. Every estimate describes the file you ",
                "uploaded, not a wider population. If the file is not a census ",
                "of what you care about, say so when you report the numbers."),
        tags$dt("Other kinds of text"),
        tags$dd("The prompt is written to be general, and you describe your ",
                "passages on the next page so it reads them in the right light. ",
                "It has not been checked against speeches, survey answers, social ",
                "media, or a language other than English. Treat the first run on ",
                "a new kind of text as untested until you have hand-coded a check.")),
      tags$h5("Writing the claim"),
      tags$ul(
        tags$li("One sentence that states one side, so a writer could agree or ",
                "disagree with it: ", tags$em("“The proposed rule should be ",
                "withdrawn.”")),
        tags$li("Not a question, and not two things at once. ",
                tags$em("“X rather than Y”"), " gives a label that ",
                "cannot be read."),
        tags$li("Wording moves the answer. Run a paraphrase of the same claim and ",
                "compare before you rely on a result."),
        tags$li("The claim is recorded in every file you download, so a label ",
                "never travels without the claim it answers.")),
      tags$h5("Before uploading"),
      tags$p(class = "small text-muted",
             "Every passage is sent to the model named above. Check that the text ",
             "you are about to upload is permitted to go there."),
      tags$p(tags$a(href = docs, target = "_blank", "The method report (PDF)"))))
}
