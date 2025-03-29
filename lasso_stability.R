# ============================================================================
# Stablecoin Stability LASSO/Ridge Analysis
# ============================================================================

library(tidyverse)
library(glmnet)      # For LASSO/Ridge regression
library(lubridate)   # For date handling
library(caret)       # For cross-validation
library(zoo)         # For rolling statistics
library(scales)      # For nice plotting

# ============================================================================
# 1. Data Preparation
# ============================================================================

prepare_stability_data <- function(results) {
  # Extract stability metrics and network metrics
  stability_data <- results$stability$daily
  network_data <- results$network_metrics
  
  # Print initial data summary
  cat("\nInitial data summary:\n")
  cat("Stability data rows:", nrow(stability_data), "\n")
  cat("Network data rows:", nrow(network_data), "\n")
  
  # First ensure period is properly assigned in stability_data
  stability_data <- stability_data %>%
    mutate(period = case_when(
      date < as.Date("2022-05-08") ~ "pre_crash",
      date <= as.Date("2022-05-15") ~ "crash_period",
      TRUE ~ "post_crash"
    ))
  
  # Create daily network metrics by interpolating between periods
  network_daily <- network_data %>%
    select(token, period, nodes, edges, density, reciprocity, modularity) %>%
    mutate(
      date = case_when(
        period == "pre_crash" ~ as.Date("2022-04-01"),
        period == "crash_period" ~ as.Date("2022-05-08"),
        period == "post_crash" ~ as.Date("2022-05-16")
      )
    ) %>%
    group_by(token) %>%
    complete(date = seq.Date(
      from = as.Date("2022-04-01"),
      to = as.Date("2022-06-15"),
      by = "day"
    )) %>%
    fill(nodes, edges, density, reciprocity, modularity, .direction = "down") %>%
    ungroup()
  
  # Join stability and network metrics
  combined_data <- stability_data %>%
    left_join(network_daily, by = c("token", "date"))
  
  # Print join results
  cat("\nAfter joining:\n")
  cat("Combined data rows:", nrow(combined_data), "\n")
  
  # Print detailed data summary before enhancement
  cat("\nData summary before enhancement:\n")
  for(tok in unique(stability_data$token)) {
    n_rows <- sum(stability_data$token == tok)
    cat(tok, ":", n_rows, "rows\n")
  }
  
  # More careful handling of missing values in feature creation
  enhanced_data <- combined_data %>%
    group_by(token) %>%
    arrange(date) %>%
    mutate(
      # Forward fill network metrics first
      across(c(nodes, edges, density, reciprocity, modularity), 
             ~na.locf(.x, na.rm = FALSE, fromLast = FALSE)),
      
      # Backward fill to handle any remaining NAs at the start
      across(c(nodes, edges, density, reciprocity, modularity), 
             ~na.locf(.x, na.rm = FALSE, fromLast = TRUE)),
      
      # Handle lagged variables with explicit NA handling
      peg_deviation_lag1 = lag(peg_deviation, 1),
      peg_deviation_lag2 = lag(peg_deviation, 2),
      peg_deviation_lag3 = lag(peg_deviation, 3),
      volatility_lag1 = lag(volatility, 1),
      volatility_lag2 = lag(volatility, 2),
      
      # Rolling statistics with explicit NA handling
      rolling_vol = rollapply(volatility, width = 7, 
                            FUN = function(x) if(all(is.na(x))) NA else mean(x, na.rm = TRUE), 
                            fill = NA, align = "right"),
      rolling_dev = rollapply(peg_deviation, width = 7, 
                            FUN = function(x) if(all(is.na(x))) NA else mean(x, na.rm = TRUE), 
                            fill = NA, align = "right"),
      
      # Safe transformations
      log_volume = log1p(replace_na(volume, 0)),
      log_nodes = log1p(replace_na(nodes, 0)),
      log_edges = log1p(replace_na(edges, 0)),
      
      # Period indicators (these should never be NA)
      is_crash_period = date >= as.Date("2022-05-08") & date <= as.Date("2022-05-15"),
      is_post_crash = date > as.Date("2022-05-15")
    ) %>%
    ungroup()
  
  # Print detailed missing value summary
  cat("\nMissing value patterns before final imputation:\n")
  for(tok in unique(enhanced_data$token)) {
    cat("\n", tok, ":\n")
    missing <- colSums(is.na(enhanced_data[enhanced_data$token == tok, ]))
    print(missing[missing > 0])
  }
  
  # Final imputation step
  enhanced_data <- enhanced_data %>%
    group_by(token) %>%
    mutate(
      across(where(is.numeric), ~if(all(is.na(.))) 0 else replace_na(., mean(., na.rm = TRUE)))
    ) %>%
    ungroup()
  
  # Remove any remaining rows with NA values
  enhanced_data <- enhanced_data %>%
    filter(!is.na(peg_deviation))  # Ensure target variable is not NA
  
  # Print final data summary
  cat("\nFinal data summary:\n")
  for(tok in unique(enhanced_data$token)) {
    n_rows <- sum(enhanced_data$token == tok)
    cat(tok, ":", n_rows, "rows\n")
    if(n_rows > 0) {
      na_counts <- colSums(is.na(enhanced_data[enhanced_data$token == tok,]))
      if(any(na_counts > 0)) {
        cat("  Missing values:\n")
        print(na_counts[na_counts > 0])
      }
    }
  }
  
  return(enhanced_data)
}

# ============================================================================
# 2. Model Training Functions
# ============================================================================

train_stability_model <- function(data, token_name, alpha = 1) {
  # Filter data for specific token and handle missing values upfront
  token_data <- data %>%
    filter(token == token_name) %>%
    select_if(is.numeric) %>%
    # Add back categorical variables
    mutate(
      is_crash_period = data$is_crash_period[data$token == token_name],
      is_post_crash = data$is_post_crash[data$token == token_name]
    )
  
  # Print initial diagnostics
  cat("\nInitial diagnostics for", token_name, ":\n")
  cat("Total observations:", nrow(token_data), "\n")
  cat("Number of features:", ncol(token_data), "\n")
  
  # Print missing value patterns
  missing_pattern <- sapply(token_data, function(x) sum(is.na(x)))
  cat("\nMissing values by column:\n")
  print(missing_pattern[missing_pattern > 0])
  
  # Handle missing values column by column
  for(col in names(token_data)) {
    if(sum(is.na(token_data[[col]])) > 0) {
      cat("\nHandling missing values in", col, "\n")
      
      if(col == "peg_deviation") {
        # For target variable, remove rows with missing values
        token_data <- token_data[!is.na(token_data[[col]]), ]
        cat("Removed rows with missing target values\n")
      } else {
        # For predictors, use mean imputation
        mean_val <- mean(token_data[[col]], na.rm = TRUE)
        token_data[[col]][is.na(token_data[[col]])] <- mean_val
        cat("Imputed missing values with mean:", mean_val, "\n")
      }
    }
  }
  
  # Verify no missing values remain
  if(any(is.na(token_data))) {
    cat("\nColumns still containing NAs:\n")
    still_missing <- sapply(token_data, function(x) sum(is.na(x)))
    print(still_missing[still_missing > 0])
    warning("Still have missing values after imputation")
    return(NULL)
  }
  
  # Check if we have enough data after handling missing values
  if(nrow(token_data) < 10) {
    warning("Insufficient data after handling missing values")
    return(NULL)
  }
  
  # Create train/test split
  n <- nrow(token_data)
  train_size <- floor(0.8 * n)
  set.seed(123)
  train_idx <- sample(1:n, train_size)
  
  # Prepare matrices for glmnet
  x <- as.matrix(token_data[, names(token_data) != "peg_deviation"])
  y <- token_data$peg_deviation
  
  # Verify matrices are complete
  cat("\nMatrix dimensions:\n")
  cat("X matrix:", dim(x), "\n")
  cat("y vector:", length(y), "\n")
  
  # Add before marginal screening
  # Check predictor matrix
  cat("\nPredictor matrix diagnostics:\n")
  cat("Number of predictors:", ncol(x), "\n")
  cat("Number of observations:", nrow(x), "\n")
  
  # Check for constant columns
  constant_cols <- apply(x, 2, function(col) length(unique(col)) == 1)
  if(any(constant_cols)) {
    cat("\nWarning: Found constant columns:", 
        paste(names(constant_cols)[constant_cols], collapse=", "), "\n")
    # Remove constant columns
    x <- x[, !constant_cols]
    cat("Removed", sum(constant_cols), "constant columns\n")
  }
  
  # Check for highly correlated predictors
  cor_matrix <- cor(x)
  high_cor <- which(abs(cor_matrix) > 0.95 & abs(cor_matrix) < 1, arr.ind = TRUE)
  if(nrow(high_cor) > 0) {
    cat("\nWarning: Found highly correlated predictors (>0.95):\n")
    for(i in 1:nrow(high_cor)) {
      if(high_cor[i,1] < high_cor[i,2]) {  # Print each pair only once
        cat(colnames(x)[high_cor[i,1]], "and", 
            colnames(x)[high_cor[i,2]], "\n")
      }
    }
  }
  
  # Check response variable
  cat("\nResponse variable diagnostics:\n")
  cat("Range:", range(y), "\n")
  cat("Mean:", mean(y), "\n")
  cat("SD:", sd(y), "\n")
  
  # First do marginal screening (like HW1)
  marginal_pvals <- sapply(colnames(x), function(var) {
    tryCatch({
      fit <- lm(y ~ x[,var])
      # Check if we have enough data for regression
      if(length(coef(fit)) < 2) {
        return(1)  # Return 1 if regression fails
      }
      # Get p-value safely
      coefs <- summary(fit)$coefficients
      if(nrow(coefs) < 2) {
        return(1)
      }
      return(coefs[2,4])
    }, error = function(e) {
      cat("Error in marginal regression for", var, ":", e$message, "\n")
      return(1)  # Return 1 if there's an error
    })
  })
  
  # Print marginal regression results
  cat("\nMarginal regression results:\n")
  cat("Number of variables tested:", length(marginal_pvals), "\n")
  cat("Range of p-values:", range(marginal_pvals), "\n")
  
  # Apply FDR control (from HW1) with error checking
  tryCatch({
    source("fdr.R")
    fdr_cutoff <- fdr_cut(marginal_pvals, q=0.1)
    significant_vars <- names(marginal_pvals)[marginal_pvals <= fdr_cutoff]
    
    cat("\nFDR Analysis Results:\n")
    cat("FDR cutoff:", fdr_cutoff, "\n")
    cat("Number of significant variables:", length(significant_vars), "\n")
    
    if(length(significant_vars) == 0) {
      cat("Warning: No significant variables found\n")
      # Use all variables if none are significant
      significant_vars <- colnames(x)
    }
  }, error = function(e) {
    cat("Error in FDR analysis:", e$message, "\n")
    # Use all variables if FDR fails
    significant_vars <- colnames(x)
  })
  
  # Set up cross-validation
  tryCatch({
    # Set up lambda grid
    lambda_grid <- exp(seq(log(0.1), log(1e-4), length.out=100))
    
    # K-fold cross-validation setup
    k_folds <- 5
    fold_size <- floor(train_size/k_folds)
    fold_indices <- sample(rep(1:k_folds, length.out=train_size))
    
    # Storage for CV errors
    cv_errors <- matrix(NA, nrow=length(lambda_grid), ncol=k_folds)
    
    # Perform k-fold CV
    for(i in 1:k_folds) {
      # Get indices for this fold
      fold_train <- train_idx[fold_indices != i]
      fold_valid <- train_idx[fold_indices == i]
      
      # Verify data
      cat("\nFold", i, "sizes - Train:", length(fold_train), 
          "Valid:", length(fold_valid), "\n")
      
      # Check for missing values in fold data
      if(any(is.na(x[fold_train,])) || any(is.na(y[fold_train]))) {
        cat("Missing values in training fold", i, "\n")
        next
      }
      
      # Fit models for each lambda
      for(j in seq_along(lambda_grid)) {
        tryCatch({
          # Fit model
          fold_model <- glmnet(
            x[fold_train,], 
            y[fold_train],
            alpha = alpha,
            lambda = lambda_grid[j],
            standardize = TRUE
          )
          
          # Make predictions
          pred <- predict(fold_model, x[fold_valid,])
          
          # Calculate MSE
          cv_errors[j,i] <- mean((y[fold_valid] - pred)^2)
        }, error = function(e) {
          cat("Error in fold", i, "lambda", j, ":", e$message, "\n")
        })
      }
    }
    
    # Calculate mean CV error for each lambda
    mean_cv_errors <- rowMeans(cv_errors, na.rm = TRUE)
    
    # Find optimal lambda (minimum CV error)
    lambda_min_idx <- which.min(mean_cv_errors)
    lambda_min <- lambda_grid[lambda_min_idx]
    
    # Find lambda within 1 SE
    se_cv <- apply(cv_errors, 1, sd, na.rm = TRUE) / sqrt(k_folds)
    cutoff <- min(mean_cv_errors) + se_cv[lambda_min_idx]
    lambda_1se_idx <- max(which(mean_cv_errors <= cutoff))
    lambda_1se <- lambda_grid[lambda_1se_idx]
    
    # Plot CV error curve
    png(paste0("img/cv_error_", token_name, ".png"), width=800, height=600)
    plot(log(lambda_grid), mean_cv_errors, type="l",
         xlab="log(lambda)", ylab="CV Mean Squared Error",
         main=paste("Cross-validation Error Curve for", token_name))
    abline(v=log(lambda_min), col="red", lty=2)
    abline(v=log(lambda_1se), col="blue", lty=2)
    legend("topright", 
           legend=c("lambda.min", "lambda.1se"),
           col=c("red", "blue"), 
           lty=2)
    dev.off()
    
    # Fit final models using optimal lambdas
    model_min <- glmnet(
      x[train_idx,], 
      y[train_idx],
      alpha = alpha,
      lambda = lambda_min,
      standardize = TRUE
    )
    
    model_1se <- glmnet(
      x[train_idx,], 
      y[train_idx],
      alpha = alpha,
      lambda = lambda_1se,
      standardize = TRUE
    )
    
    # Calculate metrics for both models
    test_pred_min <- predict(model_min, x[-train_idx,])
    test_pred_1se <- predict(model_1se, x[-train_idx,])
    test_actual <- y[-train_idx]
    
    rmse_min <- sqrt(mean((test_pred_min - test_actual)^2))
    rmse_1se <- sqrt(mean((test_pred_1se - test_actual)^2))
    r2_min <- 1 - sum((test_actual - test_pred_min)^2) / 
              sum((test_actual - mean(test_actual))^2)
    r2_1se <- 1 - sum((test_actual - test_pred_1se)^2) / 
              sum((test_actual - mean(test_actual))^2)
    
    # Compare coefficients (like HW2)
    coef_min <- coef(model_min)
    coef_1se <- coef(model_1se)
    
    # Create coefficient summary
    coef_summary <- data.frame(
      feature = rownames(coef_min),
      min_coef = as.vector(coef_min),
      se_coef = as.vector(coef_1se),
      significant = rownames(coef_min) %in% significant_vars
    ) %>%
      arrange(desc(abs(min_coef)))
    
    # Print model comparison
    cat("\nModel Comparison:\n")
    cat("Minimum lambda model:\n")
    cat("- Lambda:", lambda_min, "\n")
    cat("- Non-zero coefficients:", sum(coef_min != 0) - 1, "\n")
    cat("- Test R²:", round(r2_min, 3), "\n")
    cat("- Test RMSE:", round(rmse_min, 4), "\n")
    
    cat("\n1SE lambda model:\n")
    cat("- Lambda:", lambda_1se, "\n")
    cat("- Non-zero coefficients:", sum(coef_1se != 0) - 1, "\n")
    cat("- Test R²:", round(r2_1se, 3), "\n")
    cat("- Test RMSE:", round(rmse_1se, 4), "\n")
    
    # Choose final model based on HW2 approach
    # Use 1SE rule unless minimum lambda model is substantially better
    use_1se <- (r2_1se >= 0.9 * r2_min)
    
    final_model <- if(use_1se) model_1se else model_min
    final_coef <- if(use_1se) coef_1se else coef_min
    final_rmse <- if(use_1se) rmse_1se else rmse_min
    final_r2 <- if(use_1se) r2_1se else r2_min
    final_pred <- if(use_1se) test_pred_1se else test_pred_min
    
    # Add CV results to return object
    cv_results <- list(
      lambda_grid = lambda_grid,
      cv_errors = cv_errors,
      mean_cv_errors = mean_cv_errors,
      se_cv = se_cv,
      lambda_min = lambda_min,
      lambda_1se = lambda_1se,
      k_folds = k_folds
    )
    
    return(list(
      model = final_model,
      cv_fit = cv_results,  # Replace cv_fit with our custom CV results
      rmse = final_rmse,
      r2 = final_r2,
      coefficients = coef_summary,
      test_predictions = data.frame(
        actual = test_actual,
        predicted = as.vector(final_pred)
      ),
      features_used = colnames(x),
      fdr_results = list(
        significant_vars = significant_vars,
        pvalues = marginal_pvals,
        cutoff = fdr_cutoff
      ),
      lambda_comparison = list(
        min = list(lambda = lambda_min, 
                  rmse = rmse_min, 
                  r2 = r2_min),
        se = list(lambda = lambda_1se, 
                 rmse = rmse_1se, 
                 r2 = r2_1se)
      )
    ))
  }, error = function(e) {
    warning("Error in model fitting for ", token_name, ": ", e$message)
    print(traceback())
    return(NULL)
  })
}

# ============================================================================
# 3. Visualization Functions
# ============================================================================

plot_feature_importance <- function(model_results, token_name) {
  # Get non-zero coefficients
  important_features <- model_results$coefficients %>%
    filter(feature != "(Intercept)" & abs(min_coef) > 0) %>%
    mutate(
      feature = factor(feature, levels = feature[order(abs(min_coef))]),
      importance = abs(min_coef),
      direction = ifelse(min_coef > 0, "Positive", "Negative")
    )
  
  # Create plot
  p <- ggplot(important_features, 
              aes(x = feature, y = importance, fill = direction)) +
    geom_bar(stat = "identity") +
    coord_flip() +
    scale_fill_manual(values = c("Positive" = "#4CAF50", "Negative" = "#F44336")) +
    labs(
      title = paste("Feature Importance for", token_name),
      subtitle = "LASSO Regression Coefficients (absolute value)",
      x = "Feature",
      y = "Coefficient Magnitude"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(face = "bold"),
      axis.text.y = element_text(size = 8)
    )
  
  return(p)
}

plot_predictions <- function(model_results, token_name) {
  # Create prediction plot
  p <- ggplot(model_results$test_predictions, 
              aes(x = actual, y = predicted)) +
    geom_point(alpha = 0.5, color = "#2196F3") +
    geom_abline(intercept = 0, slope = 1, 
                color = "red", linetype = "dashed") +
    labs(
      title = paste("Actual vs Predicted Peg Deviation for", token_name),
      subtitle = paste("R² =", round(model_results$r2, 3),
                      "RMSE =", round(model_results$rmse, 4)),
      x = "Actual Peg Deviation",
      y = "Predicted Peg Deviation"
    ) +
    theme_minimal() +
    theme(plot.title = element_text(face = "bold"))
  
  return(p)
}

plot_model_comparison <- function(stability_results) {
  # Combine coefficients from all tokens
  all_coefs <- data.frame()
  
  for(token_name in names(stability_results)) {
    # Get LASSO and Ridge results
    lasso_coefs <- stability_results[[token_name]]$lasso$coefficients
    ridge_coefs <- stability_results[[token_name]]$ridge$coefficients
    
    # Add model and token info
    lasso_coefs$model <- "LASSO"
    ridge_coefs$model <- "Ridge"
    lasso_coefs$token <- token_name
    ridge_coefs$token <- token_name
    
    # Combine
    all_coefs <- rbind(all_coefs, lasso_coefs, ridge_coefs)
  }
  
  # Remove intercept
  all_coefs <- all_coefs %>%
    filter(feature != "(Intercept)")
  
  # Create comparison plot
  p <- ggplot(all_coefs, 
              aes(x = reorder(feature, abs(min_coef)), 
                  y = min_coef, 
                  fill = model)) +
    geom_bar(stat = "identity", position = "dodge") +
    facet_wrap(~token, scales = "free_y") +
    coord_flip() +
    scale_fill_manual(values = c("LASSO" = "#2196F3", "Ridge" = "#FF9800")) +
    labs(
      title = "Feature Coefficients: LASSO vs Ridge",
      subtitle = "By Stablecoin",
      x = "Feature",
      y = "Coefficient Value"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(face = "bold"),
      axis.text.y = element_text(size = 8),
      legend.position = "top"
    )
  
  # Save plot
  ggsave("img/lasso_ridge_comparison.png", p, width = 15, height = 10)
  
  # Print summary of key predictors
  cat("\nKey predictors by token:\n")
  for(token_name in names(stability_results)) {
    cat("\n", token_name, ":\n")
    
    # Get LASSO non-zero coefficients
    lasso_important <- stability_results[[token_name]]$lasso$coefficients %>%
      filter(feature != "(Intercept)" & abs(min_coef) > 0) %>%
      arrange(desc(abs(min_coef)))
    
    cat("LASSO kept", nrow(lasso_important), "predictors\n")
    print(lasso_important)
    
    # Model performance
    cat("\nModel Performance:\n")
    cat("LASSO - R²:", round(stability_results[[token_name]]$lasso$r2, 3),
        "RMSE:", round(stability_results[[token_name]]$lasso$rmse, 4), "\n")
    cat("Ridge - R²:", round(stability_results[[token_name]]$ridge$r2, 3),
        "RMSE:", round(stability_results[[token_name]]$ridge$rmse, 4), "\n")
  }
}

# ============================================================================
# 4. Main Analysis Function
# ============================================================================

run_stability_analysis <- function(results) {
  # Prepare data
  cat("Preparing data for analysis...\n")
  analysis_data <- prepare_stability_data(results)
  
  # Store results
  all_results <- list()
  
  # Analyze each token
  for(token_name in unique(analysis_data$token)) {
    cat("\nAnalyzing", token_name, "...\n")
    
    # Skip WLUNA as it's not a stablecoin
    if(token_name == "WLUNA") {
      cat("Skipping WLUNA\n")
      next
    }
    
    # Train LASSO model
    lasso_results <- train_stability_model(analysis_data, token_name, alpha = 1)
    
    # Only proceed if we got valid results
    if(!is.null(lasso_results)) {
      # Train Ridge model
      ridge_results <- train_stability_model(analysis_data, token_name, alpha = 0)
      
      # Store results
      all_results[[token_name]] <- list(
        lasso = lasso_results,
        ridge = ridge_results
      )
      
      # Create and save plots only if we have valid results
      tryCatch({
        p1 <- plot_feature_importance(lasso_results, token_name)
        ggsave(paste0("img/lasso_importance_", token_name, ".png"), p1, 
               width = 10, height = 6)
        
        p2 <- plot_predictions(lasso_results, token_name)
        ggsave(paste0("img/lasso_predictions_", token_name, ".png"), p2, 
               width = 8, height = 6)
      }, error = function(e) {
        warning("Error creating plots for ", token_name, ": ", e$message)
      })
    } else {
      cat("No valid model results for", token_name, "\n")
    }
  }
  
  if(length(all_results) > 0) {
    plot_model_comparison(all_results)
  }
  
  return(all_results)
}

# ============================================================================
# 5. Run Analysis
# ============================================================================

# Load results if not already in environment
if(!exists("results")) {
  results <- readRDS("task1_results.rds")
}

# Add this before running the analysis
cat("\nChecking data availability:\n")
print(table(results$stability$daily$token))
cat("\nDate range in stability data:\n")
print(range(results$stability$daily$date))
cat("\nNetwork metrics periods:\n")
print(table(results$network_metrics$period))

# Run stability analysis
stability_results <- run_stability_analysis(results)

# Save results
saveRDS(stability_results, "stability_model_results.rds") 