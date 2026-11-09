# What happens when the provider refuses with 429.

test_that("refusals are waited out, so every passage still gets its label", {
  # httr2's parallel queue, which ellmer uses, retries a 429 for as long as the
  # provider sends one, waiting the Retry-After it asks for. The mock refuses 3
  # requests, asking for 1 second each time, then answers again.
  mock_reset()
  truth <- rep(c("favor", "oppose", "neutral", "irrelevant"), 5)
  t0 <- Sys.time()
  lab <- stance_label_all(passage(truth), "P", ep(model = "opus-limited"), stance_scheme("favor"),
                          workers = 2)
  expect_equal(as.vector(lab), truth)
  expect_true(all(is.na(attr(lab, "why"))))
  expect_equal(length(mock_log()), 20 + 3)
  expect_gte(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
})
