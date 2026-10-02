# unga_openrouter.R: the home provider. At work, delete this file and set
# use_openrouter = FALSE in topics.qmd and stance.R; the steps tables then
# decide the endpoint. The key lives in .Renviron as OPENROUTER_API_KEY.

make_chat_home <- function(model, system_prompt) {
  ellmer::chat_openrouter(model = sub("^openrouter/", "", model),
                          system_prompt = system_prompt,
                          params = ellmer::params(temperature = 0),
                          echo = "none")
}

# Model per step; replaces the model column of each script's steps table.
open_router_models <- c(
  codebook = "openrouter/meta-llama/llama-4-maverick",
  stance = "openrouter/google/gemma-4-31b-it")
