# ============================================================================
# FDR-Controlled Marginal Regression for Stablecoin Stability Analysis
# ============================================================================

library(tidyverse)
library(parallel)
library(foreach)
library(doParallel)
library(glmnet)
library(pROC)

# ============================================================================
# Data Preparation
# ============================================================================

# Source FDR utility functions
source("fdr.R")

# Function to prepare data for FDR analysis
prepare_fdr_data <- function(results) {
  # Extract daily data
  data <- results$stability$daily %>%
    left_join(results$network_metrics, by = c("token", "period")) %>%
    # Select relevant features
    select(token, period, peg_deviation, volatility, volume, 
           nodes, edges, density, reciprocity, modularity,
           starts_with("rolling_"),
           starts_with("peg_deviation_lag"),
           starts_with("volatility_lag")) %>%
    # Remove WLUNA
    filter(token != "WLUNA") %>%
    # Add period indicators if they don't exist
    mutate(
      is_crash_period = period >= as.Date("2022-05-08") & period <= as.Date("2022-05-15"),
      is_post_crash = period > as.Date("2022-05-15")
    ) %>%
    # Remove any NA values
    na.omit()
  
  return(data)
}

# ============================================================================
# Univariate Testing
# ============================================================================

run_univariate_tests <- function(data, target = "is_stable", alpha = 0.1) {
  cat("Running univariate tests with target:", target, "\n")
  
  # Get all numeric predictors
  predictors <- data %>%
    select(where(is.numeric)) %>%
    select(-any_of(c("is_stable"))) %>%
    names()
  
  cat("Testing", length(predictors), "predictors...\n")
  
  # Set up parallel processing
  cores <- detectCores() - 1
  cl <- makeCluster(cores)
  registerDoParallel(cl)
  
  # Run univariate tests in parallel
  results <- foreach(predictor = predictors, .combine = rbind, .packages = c("stats", "pROC")) %dopar% {
    # Formula for this predictor
    formula_str <- paste(target, "~", predictor)
    
    # Run logistic regression
    tryCatch({
      model <- glm(as.formula(formula_str), data = data, family = "binomial")
      summary_model <- summary(model)
      
      # Extract p-value for the predictor
      p_value <- summary_model$coefficients[2, 4]
      
      # Calculate AUC
      pred <- predict(model, type = "response")
      auc_value <- as.numeric(auc(data[[target]], pred))
      
      # Calculate coefficient
      coef_value <- summary_model$coefficients[2, 1]
      
      # Return results
      data.frame(
        predictor = predictor,
        p_value = p_value,
        coefficient = coef_value,
        auc = auc_value,
        stringsAsFactors = FALSE
      )
    }, error = function(e) {
      # Return NA for failed models
      data.frame(
        predictor = predictor,
        p_value = NA,
        coefficient = NA,
        auc = NA,
        stringsAsFactors = FALSE
      )
    })
  }
  
  # Stop parallel cluster
  stopCluster(cl)
  
  # Remove rows with NA p-values
  results <- results %>%
    filter(!is.na(p_value))
  
  # Apply Benjamini-Hochberg procedure
  results <- results %>%
    arrange(p_value) %>%
    mutate(
      rank = row_number(),
      total = n(),
      bh_critical = rank / total * alpha,
      significant = p_value <= bh_critical
    )
  
  # Also apply Bonferroni correction
  results$bonferroni_significant <- results$p_value <= (alpha / nrow(results))
  
  # Count significant predictors
  n_significant_bh <- sum(results$significant)
  n_significant_bonferroni <- sum(results$bonferroni_significant)
  
  cat("\nResults:\n")
  cat("- Total predictors tested:", nrow(results), "\n")
  cat("- Significant predictors (BH method):", n_significant_bh, "\n")
  cat("- Significant predictors (Bonferroni method):", n_significant_bonferroni, "\n")
  
  return(results)
}

# ============================================================================
# Visualization and Analysis
# ============================================================================

visualize_fdr_results <- function(fdr_results) {
  # Create directory for plots
  dir.create("img/fdr", recursive = TRUE, showWarnings = FALSE)
  
  # Plot 1: P-value distribution
  p1 <- ggplot(fdr_results, aes(x = p_value)) +
    geom_histogram(bins = 30, fill = "steelblue") +
    theme_minimal() +
    labs(title = "Distribution of P-values",
         x = "P-value", y = "Count")
  
  ggsave("img/fdr/p_value_distribution.png", p1, width = 8, height = 6)
  
  # Plot 2: BH procedure visualization
  p2 <- ggplot(fdr_results, aes(x = rank, y = p_value)) +
    geom_point() +
    geom_line(aes(y = bh_critical), color = "red") +
    theme_minimal() +
    labs(title = "Benjamini-Hochberg Procedure",
         x = "Rank", y = "P-value",
         subtitle = "Red line: BH critical values")
  
  ggsave("img/fdr/bh_procedure.png", p2, width = 8, height = 6)
  
  # Plot 3: Top significant predictors
  top_predictors <- fdr_results %>%
    filter(significant) %>%
    arrange(p_value) %>%
    head(20)
  
  p3 <- ggplot(top_predictors, aes(x = reorder(predictor, -p_value), y = -log10(p_value))) +
    geom_bar(stat = "identity", fill = "steelblue") +
    coord_flip() +
    theme_minimal() +
    labs(title = "Top Significant Predictors",
         x = "Predictor", y = "-log10(p-value)")
  
  ggsave("img/fdr/top_predictors.png", p3, width = 10, height = 8)
  
  # Plot 4: AUC vs p-value
  p4 <- ggplot(fdr_results, aes(x = auc, y = -log10(p_value), color = significant)) +
    geom_point(alpha = 0.7) +
    theme_minimal() +
    scale_color_manual(values = c("grey", "red")) +
    labs(title = "AUC vs. Statistical Significance",
         x = "AUC", y = "-log10(p-value)",
         color = "Significant")
  
  ggsave("img/fdr/auc_vs_significance.png", p4, width = 8, height = 6)
}

# ============================================================================
# Run Analysis
# ============================================================================

# Load data
results <- readRDS("task1_results.rds")

# Prepare data
fdr_data <- prepare_fdr_data(results)

# Run univariate tests
fdr_results <- run_univariate_tests(fdr_data, target = "is_stable", alpha = 0.1)

# Visualize results
visualize_fdr_results(fdr_results)

# Save significant predictors
significant_predictors <- fdr_results %>%
  filter(significant) %>%
  arrange(p_value)

write.csv(significant_predictors, "significant_predictors.csv", row.names = FALSE)

# Print top 10 significant predictors
cat("\nTop 10 significant predictors:\n")
print(head(significant_predictors, 10))

# Save full results
saveRDS(fdr_results, "fdr_results.rds")

cat("\nAnalysis complete. Check the img/fdr directory for visualizations.\n")

# Function to perform FDR-controlled regression analysis
fdr_regression <- function(data, token, q = 0.05) {
  # Filter data for specific token
  token_data <- data[data$token == token, ]
  
  # Get predictors (excluding response and non-numeric columns)
  predictors <- names(token_data)[sapply(token_data, is.numeric)]
  predictors <- setdiff(predictors, c("peg_deviation", "token"))
  
  # Store p-values and coefficients from marginal regressions
  results <- data.frame(
    predictor = predictors,
    p_value = NA,
    coefficient = NA,
    stringsAsFactors = FALSE
  )
  
  # Perform marginal regressions with error handling
  for(i in seq_along(predictors)) {
    tryCatch({
      # Safe extraction of predictor
      x <- token_data[[predictors[i]]]
      
      # Check for constant/NA predictors
      if(length(unique(na.omit(x))) <= 1) {
        next
      }
      
      # Fit model
      formula <- as.formula(paste("peg_deviation ~", predictors[i]))
      fit <- lm(formula, data = token_data)
      sum_fit <- summary(fit)
      
      # Extract results if available
      if(nrow(sum_fit$coefficients) >= 2) {
        results$p_value[i] <- sum_fit$coefficients[2,4]
        results$coefficient[i] <- sum_fit$coefficients[2,1]
      }
    }, error = function(e) {
      cat("Error analyzing predictor", predictors[i], ":", e$message, "\n")
    })
  }
  
  # Remove NA results
  results <- results[!is.na(results$p_value), ]
  
  if(nrow(results) == 0) {
    cat("No valid results found for", token, "\n")
    return(NULL)
  }
  
  # Apply FDR control
  cutoff <- fdr_cut(results$p_value, q = q, plotit = TRUE,
                    main = paste("FDR Analysis for", token))
  
  # Identify significant predictors
  results$significant <- results$p_value <= cutoff
  
  return(list(
    results = results,
    cutoff = cutoff
  ))
}

# Create directory for FDR plots
dir.create("img/fdr", showWarnings = FALSE, recursive = TRUE)

# Run analysis for each token
tokens <- c("USDT", "USDC", "DAI", "PAX", "USTC")
fdr_results <- list()

for(token in tokens) {
  cat("\nAnalyzing", token, "...\n")
  
  # Save FDR plot to file
  png(filename = paste0("img/fdr/", token, "_fdr.png"),
      width = 800, height = 600)
  fdr_results[[token]] <- fdr_regression(fdr_data, token)
  dev.off()
  
  if(!is.null(fdr_results[[token]])) {
    cat("Significant predictors:\n")
    print(subset(fdr_results[[token]]$results, significant))
  }
}

# Save results
saveRDS(fdr_results, "fdr_results.rds")
cat("\nAnalysis complete. Check the img/fdr directory for visualizations.\n") 