# ============================================================================
# Stablecoin Stability Decision Tree Analysis
# ============================================================================

library(tidyverse)
library(rpart)
library(rpart.plot)

# ============================================================================
# Data Preparation
# ============================================================================

prepare_data <- function(results) {
  # First analyze peg deviation distribution by token
  stability_data <- results$stability$daily %>%
    group_by(token) %>%
    summarise(
      q33 = quantile(abs(peg_deviation), 0.33, na.rm = TRUE),
      q67 = quantile(abs(peg_deviation), 0.67, na.rm = TRUE),
      median = median(abs(peg_deviation), na.rm = TRUE)
    )
  
  cat("\nPeg deviation distribution by token:\n")
  print(stability_data)
  
  # Create stability classes with token-specific thresholds
  stability_data <- results$stability$daily %>%
    left_join(results$network_metrics, by = c("token", "period")) %>%
    group_by(token) %>%
    arrange(date) %>%
    mutate(
      # Get token-specific thresholds
      token_median = median(abs(peg_deviation), na.rm = TRUE),
      token_q75 = quantile(abs(peg_deviation), 0.75, na.rm = TRUE),
      
      # Create stability classes using relative thresholds
      stability_class = factor(
        case_when(
          abs(peg_deviation) <= token_median ~ "stable",
          abs(peg_deviation) <= token_q75 ~ "unstable",
          TRUE ~ "depegged"
        ),
        levels = c("stable", "unstable", "depegged")
      )
    ) %>%
    # Create more features
    mutate(
      # Lagged features
      prev_deviation = lag(peg_deviation),
      rolling_vol_7d = rollapply(volatility, width = 7, 
                                FUN = mean, fill = NA, align = "right"),
      rolling_dev_7d = rollapply(peg_deviation, width = 7, 
                                FUN = mean, fill = NA, align = "right"),
      
      # Market stress indicators
      high_volatility = volatility > mean(volatility, na.rm = TRUE),
      deviation_trend = peg_deviation - lag(peg_deviation),
      
      # Derived features
      log_volume = log1p(volume),
      vol_change = (volume - lag(volume))/lag(volume),
      
      # Network features
      log_nodes = log1p(nodes),
      log_edges = log1p(edges),
      network_growth = (nodes - lag(nodes))/lag(nodes),
      
      # Time features
      is_weekend = weekdays(date) %in% c("Saturday", "Sunday"),
      month = month(date),
    ) %>%
    ungroup() %>%
    # Handle any missing values
    mutate(across(where(is.numeric), ~replace_na(., mean(., na.rm = TRUE))))
  
  # Print class distribution by token
  cat("\nClass distribution by token:\n")
  print(table(stability_data$token, stability_data$stability_class))
  
  # Print feature summary
  cat("\nAvailable features:\n")
  print(names(stability_data))
  
  return(stability_data)
}

# ============================================================================
# Train and Plot Tree
# ============================================================================

train_tree <- function(data, token_name) {
  # Filter data for token and include more features
  token_data <- data %>%
    filter(token == token_name) %>%
    select(
      stability_class,
      peg_deviation,
      volatility,
      volume,
      nodes,
      edges,
      density,
      reciprocity,
      modularity,
      is_weekend,
      month
    )
  
  # Print available features
  cat("\nFeatures used for", token_name, ":\n")
  print(names(token_data))
  
  # Split into training and testing (80/20)
  set.seed(123)
  train_idx <- sample(1:nrow(token_data), 0.8 * nrow(token_data))
  train_data <- token_data[train_idx,]
  test_data <- token_data[-train_idx,]
  
  # Check class distribution
  class_counts <- table(train_data$stability_class)
  cat("\nClass distribution in training data:\n")
  print(class_counts)
  
  # Only proceed if we have enough samples in each class
  min_samples <- 2  # Reduced minimum samples
  if(any(class_counts < min_samples)) {
    cat("\nSkipping tree creation - need at least", min_samples, "samples per class\n")
    cat("Current class counts:\n")
    print(class_counts)
    return(NULL)
  }
  
  # Fit tree with more lenient parameters
  tree <- rpart(stability_class ~ ., 
                data = train_data, 
                method = "class",
                control = rpart.control(
                  cp = 0.005,      # More lenient complexity parameter
                  minsplit = 10,   # Allow smaller splits
                  minbucket = 3,   # Allow smaller leaf nodes
                  maxdepth = 5     # Reasonable depth
                ))
  
  # Print tree complexity
  cat("\nTree complexity:\n")
  cat("Number of terminal nodes:", length(unique(tree$where)), "\n")
  cat("Variables actually used:", paste(tree$frame$var[tree$frame$var != "<leaf>"], collapse=", "), "\n")
  
  # Make predictions
  pred <- predict(tree, test_data, type = "class")
  
  # Calculate accuracy
  accuracy <- mean(pred == test_data$stability_class)
  
  # Plot tree with most basic parameters
  tryCatch({
    # Basic tree structure plot
    png(paste0("img/tree_", token_name, ".png"), width = 1200, height = 800)
    par(xpd = TRUE)  # Allow plotting outside the plot region
    plot(tree, 
         uniform = TRUE, 
         main = paste("Decision Tree for", token_name),
         margin = 0.1)
    text(tree, 
         use.n = TRUE,    # Show number of observations
         all = TRUE,      # Show all nodes
         cex = 0.8)      # Smaller text size
    dev.off()
    
    # Print summary information
    cat("\nTree Summary for", token_name, ":\n")
    summary(tree)
    
    # Print rules in text format
    cat("\nDecision Rules:\n")
    print(rpart.rules(tree, style = "wide"))
    
  }, error = function(e) {
    cat("\nError plotting tree for", token_name, ":", e$message, "\n")
  })
  
  # Print confusion matrix
  conf_matrix <- table(Actual = test_data$stability_class, 
                      Predicted = pred)
  cat("\nConfusion Matrix:\n")
  print(conf_matrix)
  
  # Return results
  list(
    tree = tree,
    accuracy = accuracy,
    confusion_matrix = conf_matrix,
    predictions = data.frame(
      actual = test_data$stability_class,
      predicted = pred
    )
  )
}

# ============================================================================
# Run Analysis
# ============================================================================

# Create img directory
dir.create("img", showWarnings = FALSE)

# Load data
results <- readRDS("task1_results.rds")

# Prepare data
data <- prepare_data(results)

# Analyze each token
tree_results <- list()
for(token in unique(data$token)) {
  if(token != "WLUNA") {  # Skip WLUNA
    cat("\n====================================")
    cat("\nAnalyzing", token, "...\n")
    
    # Check class distribution for this token
    token_dist <- table(data$stability_class[data$token == token])
    cat("\nClass distribution for", token, ":\n")
    print(token_dist)
    
    # Only proceed if we have at least two classes
    if(length(token_dist) >= 2) {
      tree_results[[token]] <- train_tree(data, token)
      
      # Create high-resolution plot for this tree with adjusted margins
      png(filename = paste0("img/tree_", token, ".png"),
          width = 1600, height = 1400,  # Increased height
          res = 300)
      
      # Set larger margins to accommodate accuracy text
      par(mar = c(6, 4, 4, 4))  # Bottom, left, top, right margins
      
      # Plot the tree with improved visibility
      rpart.plot(tree_results[[token]]$tree,
                 extra = 1,  # Show classification percentages
                 box.palette = "Blues",  # Using allowed palette
                 fallen.leaves = TRUE,  # Align leaf nodes
                 roundint = FALSE,  # Fix the warning
                 type = 2,  # More detailed node information
                 varlen = 0,  # Don't truncate variable names
                 faclen = 0,  # Don't truncate factor levels
                 cex = 1.5,  # Larger text
                 main = paste("Decision Tree for", token),
                 box.col = list("lightblue", "skyblue", "steelblue"),
                 shadow.col = "gray80",
                 branch.lwd = 2,
                 compress = FALSE,  # Don't compress the tree
                 yesno = FALSE,     # Remove yes/no labels
                 split.prefix = "",  # Remove split prefix
                 space = 1.2,       # More vertical space between nodes
                 branch.lty = 1,    # Solid lines
                 split.cex = 1.2,   # Larger split text
                 split.space = 0.5, # More space for split labels
                 split.round = 6,   # Round split values to 6 decimals
                 uniform = TRUE,    # Uniform node heights
                 gap = 0.5)        # Add gap between branches
      
      # Add accuracy annotation with more space
      mtext(sprintf("Accuracy: %.1f%%", tree_results[[token]]$accuracy * 100),
            side = 1,  # Bottom
            line = 5,  # Further down
            cex = 1.2) # Larger text
      
      dev.off()
      
      cat("Accuracy:", tree_results[[token]]$accuracy, "\n")
    } else {
      cat("Skipping", token, "- insufficient class variation\n")
    }
  }
}

# Save results
saveRDS(tree_results, "tree_results.rds")