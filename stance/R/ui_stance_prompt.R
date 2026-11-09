# ui_stance_prompt.R: the prompt card on the Start here page. It prints the
# prompt exactly as the model receives it, one tab per scheme, built by the
# same stance_prompt() a run uses, so the page cannot drift from the code.
# Then how the model is called, why each part is there, and what it has been
# run on.

stance_prompt_card <- function() {
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
               "Every passage is sent with this prompt as the system message. The ",
               "words in angle brackets are what you type on ", b_("Detect stance"),
               ". The passage itself follows as the user message, ",
               tags$code("Text: <the passage>", .noWS = "after"), ", alone, with ",
               "no date, no document, and no other passage."),
        do.call(bslib::navset_card_underline,
                purrr::map(unname(stance_schemes), tab)),
        tags$p(class = "small text-muted mt-2 mb-0",
               "Sent to ", tags$code(getOption("stance.model")), " through Anthropic ",
               "at its default sampling (it takes no temperature setting), with thinking ",
               sprintf("off and a reply of at most %d tokens, ", stance_reply_tokens),
               sprintf("no more than %s requests a minute. ", getOption("stance.rpm", 300)),
               "The first label word in the reply is the label; a reply with none is ",
               "left unlabeled and reported. The full prompt and the model are saved ",
               "with the estimates of every run.")),
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
                  "A one-word reply can be read without judgment. The model takes no ",
                  "temperature setting, so a repeat run can label a passage differently; ",
                  "identical passages within a run are sent once and share one label. ",
                  "Each passage goes alone, so its label cannot lean on its neighbors, ",
                  "and without its date, so a trend cannot come from the model knowing ",
                  "the year."),
          tags$li(tags$strong("One prompt for any corpus. "),
                  "Only the claim, the scheme, and a few words on what the passages ",
                  "are change between runs. The role, rules, and output never do, so ",
                  "results from different claims rest on the same instrument.")),
        tags$h6("What it has been run on"),
        tags$ul(class = "small mb-0",
          tags$li("Work endpoint: about 6,000 English paragraphs from public comments, 50 ",
                  "to 80 tokens each, in about ten minutes sent one at a time."),
          tags$li("Home, through Ollama: gemma4:12b-it-qat, favor scheme, on 951 paragraphs ",
                  "from 60 presidential inaugural addresses (877 within the word bounds), ",
                  "October 2026."),
          tags$li("Not yet measured here: agreement with hand coding on these runs, the ",
                  "agree and aligned schemes, and the model this app now uses. Each run's agreement ",
                  "comes from Check the labels.")))))
}
