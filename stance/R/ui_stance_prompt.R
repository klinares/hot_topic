# ui_stance_prompt.R: the prompt card on the Start here page. It prints the
# prompt exactly as the model receives it, one tab per scheme, built by the
# same stance_prompt() a run uses, so the page cannot drift from the code.
# Then why each part is there, and what it has been run on.
#
# Deployment setting this card reads (set in app.R):
#   options(stance.tested = c("...", "..."))   one line per test, replacing the
#                                              defaults below

stance_tested_default <- c(
  paste("Work endpoint: about 6,000 English paragraphs from public comments, 50",
        "to 80 tokens each, in about ten minutes sent one at a time."),
  paste("Home, through Ollama: gemma4:12b-it-qat, favor scheme, on 951 paragraphs",
        "from 60 presidential inaugural addresses (877 within the word bounds),",
        "October 2026."),
  paste("Not yet measured here: agreement with hand coding on these runs, and the",
        "agree and aligned schemes. Each run's agreement comes from Check the labels."))

stance_prompt_card <- function() {
  ep <- tryCatch(stance_endpoint(), error = function(e) list(reasoning_effort = NULL))
  tested <- getOption("stance.tested", stance_tested_default)
  claim <- "<your claim>"
  kind <- "<what the passages are>"
  tab <- function(s) bslib::nav_panel(
    s$name,
    tags$pre(class = "small mb-0 sp-pre", stance_prompt(s, claim, kind)))
  bslib::card(
    bslib::card_header("The prompt"),
    tags$style(HTML(".sp-pre { white-space: pre-wrap; background: var(--bs-tertiary-bg);
      padding: .75rem; border-radius: .375rem; }")),
    bslib::layout_columns(
      col_widths = c(7, 5),
      tags$div(
        tags$p(class = "small",
               "Every passage is sent with this prompt as the system message. The ",
               "words in angle brackets are what you type on ", b_("Detect stance"),
               ". The passage itself follows as the user message, ",
               tags$code("Text: <the passage>", .noWS = "after"), ", alone, with ",
               "no date, no document, and no other passage."),
        do.call(bslib::navset_card_underline,
                purrr::map(unname(stance_schemes), tab)),
        tags$p(class = "small text-muted mt-2 mb-0", paste0(
               "Sent at temperature 0 with a reply of at most 20 tokens",
               if (!is.null(ep$reasoning_effort))
                 paste0(", and reasoning_effort = \"", ep$reasoning_effort, "\"") else "",
               ". The first label word in the reply is the label; a reply with none ",
               "is left unlabeled and reported. The full prompt is saved with the ",
               "estimates of every run."))),
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
          tags$li(tags$strong("One word, fixed settings. "),
                  "A one-word reply at temperature 0 can be read without judgment and ",
                  "gives the same label to the same text every time. Each passage ",
                  "goes alone, so its label cannot lean on its neighbors, and without ",
                  "its date, so a trend cannot come from the model knowing the year."),
          tags$li(tags$strong("One prompt for any corpus. "),
                  "Only the claim, the scheme, and a few words on what the passages ",
                  "are change between runs. The role, rules, and output never do, so ",
                  "results from different claims rest on the same instrument.")),
        tags$h6("What it has been run on"),
        tags$ul(class = "small mb-0", purrr::map(tested, tags$li)))))
}
