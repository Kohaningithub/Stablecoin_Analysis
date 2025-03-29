# ============================================================================
# Stablecoin Stability Random Forest Analysis
# ============================================================================

library(tidyverse)
library(randomForest)
library(pdp)          # For partial dependence plots
library(vip)          # For variable importance plots
library(caret)        # For model training and evaluation

# ============================================================================
# Data Preparation
# ============================================================================

prepare_forest_data <- function(results) {
  # Create features with rolling windows and lags
  stability_data <- results$stability$daily %>%
    left_join(results$network_metrics, by = c("token", "period")) %>%
    group_by(token) %>%
    arrange(date) %>%
    mutate(
      # Target variable (future stability)
      future_deviation = lead(abs(peg_deviation), 1),
      
      # Lagged features
      prev_deviation = lag(peg_deviation),
      prev_volatility = lag(volatility),
      
      # Rolling windows
      roll_vol_7d = rollapply(volatility, 7, mean, fill = NA, align = "right"),
      roll_dev_7d = rollapply(abs(peg_deviation), 7, mean, fill = NA, align = "right"),
      roll_vol_std = rollapply(volatility, 7, sd, fill = NA, align = "right"),
      
      # Network features
      log_volume = log1p(volume),
      log_nodes = log1p(nodes),
      log_edges = log1p(edges),
      
      # Network changes
      node_growth = (nodes - lag(nodes))/lag(nodes),
      edge_growth = (edges - lag(edges))/lag(edges),
      density_change = density - lag(density),
      
      # Market stress indicators
      high_volatility = volatility > mean(volatility, na.rm = TRUE),
      deviation_trend = peg_deviation - lag(peg_deviation),
      volume_shock = volume > (mean(volume, na.rm = TRUE) + 2*sd(volume, na.rm = TRUE))
    ) %>%
    ungroup()
  
  # Print initial dimensions
  cat("\nInitial dimensions:", dim(stability_data), "\n")
  
  # Handle missing values
  stability_data <- stability_data %>%
    # First handle missing values in features
    group_by(token) %>%
    mutate(across(where(is.numeric), ~if(all(is.na(.))) 0 else replace_na(., median(., na.rm = TRUE)))) %>%
    ungroup() %>%
    # Then remove rows with missing target
    filter(!is.na(future_deviation))
  
  # Remove WLUNA
  stability_data <- stability_data %>%
    filter(token != "WLUNA")
  
  # Print final dimensions
  cat("\nFinal dimensions after handling NAs:", dim(stability_data), "\n")
  
  # Print summary of features
  cat("\nFeature summary:\n")
  print(summary(stability_data))
  
  return(stability_data)
}

# ============================================================================
# Model Training
# ============================================================================

train_forest <- function(data, token_name) {
  # Filter data for token
  token_data <- data %>%
    filter(token == token_name) %>%
    select(-token, -date, -period)  # Remove non-feature columns
  
  # Print data dimensions
  cat("\nData dimensions for", token_name, ":", dim(token_data), "\n")
  
  # Check for any remaining NAs
  na_counts <- colSums(is.na(token_data))
  if(any(na_counts > 0)) {
    cat("\nWarning: Found NAs in columns:\n")
    print(na_counts[na_counts > 0])
    
    # Remove columns with too many NAs
    token_data <- token_data[, na_counts == 0]
    cat("\nRemaining columns:", ncol(token_data), "\n")
  }
  
  # Split into training and testing
  set.seed(123)
  train_idx <- createDataPartition(token_data$future_deviation, p = 0.8, list = FALSE)
  train_data <- token_data[train_idx,]
  test_data <- token_data[-train_idx,]
  
  # Train random forest with simpler parameters first
  cat("\nTraining random forest for", token_name, "...\n")
  
  rf_model <- randomForest(
    future_deviation ~ .,
    data = train_data,
    ntree = 500,
    mtry = floor(sqrt(ncol(train_data))),
    importance = TRUE
  )
  
  # Make predictions
  predictions <- predict(rf_model, test_data)
  
  # Calculate performance metrics
  rmse <- sqrt(mean((predictions - test_data$future_deviation)^2))
  r2 <- cor(predictions, test_data$future_deviation)^2
  
  # Return results
  list(
    model = rf_model,
    predictions = data.frame(
      actual = test_data$future_deviation,
      predicted = predictions
    ),
    importance = importance(rf_model),
    rmse = rmse,
    r2 = r2
  )
}

# ============================================================================
# Visualization Functions
# ============================================================================

plot_forest_results <- function(forest_results, token_name) {
  # Create directory for plots
  dir.create("img/forest", recursive = TRUE, showWarnings = FALSE)
  
  # Plot 1: Actual vs Predicted
  png(paste0("img/forest/predictions_", token_name, ".png"), width = 800, height = 600)
  plot(forest_results$predictions$actual, 
       forest_results$predictions$predicted,
       main = paste("Random Forest Predictions for", token_name),
       xlab = "Actual",
       ylab = "Predicted",
       pch = 16,
       col = rgb(0, 0, 1, 0.5))
  abline(0, 1, col = "red", lty = 2)
  legend("topleft", 
         paste(c("R² =", "RMSE ="), 
               round(c(forest_results$r2, forest_results$rmse), 4)))
  dev.off()
  
  # Plot 2: Variable Importance
  png(paste0("img/forest/importance_", token_name, ".png"), width = 1000, height = 800)
  varImpPlot(forest_results$model,
             main = paste("Variable Importance for", token_name))
  dev.off()
}

# ============================================================================
# Run Analysis
# ============================================================================

# Load data
results <- readRDS("task1_results.rds")

# Prepare data
forest_data <- prepare_forest_data(results)

# Analyze each token
forest_results <- list()
for(token in unique(forest_data$token)) {
  cat("\nAnalyzing", token, "with Random Forest...\n")
  
  # Train model and get results
  forest_results[[token]] <- train_forest(forest_data, token)
  
  # Create visualizations
  plot_forest_results(forest_results[[token]], token)
  
  # Print results
  cat("\nResults for", token, ":\n")
  cat("R²:", round(forest_results[[token]]$r2, 3), "\n")
  cat("RMSE:", round(forest_results[[token]]$rmse, 4), "\n")
}

# Save results
saveRDS(forest_results, "forest_results.rds") 