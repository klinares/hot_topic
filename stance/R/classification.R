# The classification marking shown above every screen.

# The text comes from an option rather than being written into the code,
#   because it will not stay "UNCLASSIFIED": the marking is a deployment
#   decision and has to change without anyone editing R/. Set it wherever the
#   app is started --
#     options(drsvyr.classification = "YOUR MARKING")
#   -- and every screen picks it up. Unset, it falls back to UNCLASSIFIED
#   rather than to nothing, so a deployment that forgets shows a marking that
#   is visibly wrong instead of no marking at all.
classification_banner <- function() {
  tags$div(
    style = paste("background:#b40404; color:#fff; text-align:center;",
                  "font-weight:700; letter-spacing:0.06em;",
                  "padding:5px 0; font-size:13px;"),
    getOption("drsvyr.classification", "UNCLASSIFIED"))
}
