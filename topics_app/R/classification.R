# classification.R: the classification banner and the office logo, shown above
# the navigation on every tab.

# The marking comes from an option, not the code, because it is a deployment
# decision: options(drsvyr.classification = "YOUR MARKING") in app.R. Unset, it
# shows UNCLASSIFIED rather than nothing, so a deployment that forgets shows a
# marking that is visibly wrong instead of no marking at all.
classification_banner <- function() {
  tags$div(
    style = paste("background:#b40404; color:#fff; text-align:center;",
                  "font-weight:700; letter-spacing:0.06em;",
                  "padding:5px 0; font-size:13px;"),
    getOption("drsvyr.classification", "UNCLASSIFIED"))
}

# The office logo sits under the banner. Put the image in www/ and name it in
# options(hot_topic.logo = "logo.png"). Until the file exists, a dashed box
# marks where it will go.
office_logo <- function() {
  f <- getOption("hot_topic.logo", "logo.png")
  office <- getOption("hot_topic.office", "")
  logo <- if (file.exists(file.path("www", f)))
    tags$img(src = f, alt = "Office logo", style = "height:48px;") else
    tags$div(style = paste("height:48px; width:160px; border:2px dashed #adb5bd;",
                           "border-radius:4px; color:#6c757d; font-size:12px;",
                           "display:flex; align-items:center; justify-content:center;"),
             "Office logo")
  tags$div(style = paste("display:flex; align-items:center; gap:12px;",
                         "padding:8px 16px; border-bottom:1px solid #dee2e6;"),
           logo,
           if (nzchar(office)) tags$span(style = "font-weight:600;", office))
}
