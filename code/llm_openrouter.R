# llm_openrouter.R: the home provider. At work, delete this file and set
# use_openrouter = FALSE in each script; the steps tables then decide the
# endpoint. The key lives in .Renviron as OPENROUTER_API_KEY.

make_chat_home <- function(model, system_prompt) {
  ellmer::chat_openrouter(model = sub("^openrouter/", "", model),
                          system_prompt = system_prompt,
                          params = ellmer::params(temperature = 0),
                          echo = "none")
}

embed_endpoint_home <- function(model) {
  list(url = "https://openrouter.ai/api/v1",
       key = Sys.getenv("OPENROUTER_API_KEY"),
       model = sub("^openrouter/", "", unname(model)))
}

# Model per step; replaces the model column of each script's steps table.
open_router_models <- c(
  embed = "openrouter/mistralai/mistral-embed-2312",
  codebook = "openrouter/meta-llama/llama-4-maverick",
  stance = "openrouter/google/gemma-4-31b-it")
