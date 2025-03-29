# ============================================================================
# Stablecoin Market Regime Clustering Analysis
# ============================================================================

library(tidyverse)
library(cluster)      # For clustering algorithms
library(factoextra)   # For clustering visualization
library(mclust)       # For model-based clustering
library(zoo)          # For rolling windows

# ============================================================================
# Data Preparation
# ============================================================================

prepare_cluster_data <- function(results) {
  # Print initial data summary
  cat("\nInitial data summary:\n")
  print(str(results$stability$daily))
  
  # Create base features first with more diagnostics
  cat("\nCreating base features...\n")
  cluster_data <- results$stability$daily %>%
    left_join(results$network_metrics, by = c("token", "period")) %>%
    filter(token != "WLUNA")
  
  # Print data after join
  cat("\nData after join:\n")
  print(dim(cluster_data))
  print(names(cluster_data))
  
  # Create simple features first with explicit handling of problematic values
  cluster_data <- cluster_data %>%
    mutate(
      # Simple features with explicit NA handling
      abs_deviation = ifelse(is.finite(peg_deviation), abs(peg_deviation), 0),
      log_volume = ifelse(volume > 0, log1p(volume), 0),
      density = ifelse(is.finite(density), density, 0),
      reciprocity = ifelse(is.finite(reciprocity), reciprocity, 0),
      modularity = ifelse(is.finite(modularity), modularity, 0)
    )
  
  # Print summary of features
  cat("\nFeature summary before scaling:\n")
  print(summary(cluster_data[c("abs_deviation", "log_volume", "density", "reciprocity", "modularity")]))
  
  # Scale features individually with error checking
  features <- c("abs_deviation", "log_volume", "density", "reciprocity", "modularity")
  scaled_data <- data.frame(matrix(0, nrow = nrow(cluster_data), ncol = length(features)))
  names(scaled_data) <- features
  
  for(feat in features) {
    cat("\nScaling feature:", feat, "\n")
    x <- cluster_data[[feat]]
    cat("Raw summary:", "\n")
    print(summary(x))
    
    # Handle any infinites or NAs
    x[!is.finite(x)] <- median(x[is.finite(x)])
    
    # Scale with tryCatch
    tryCatch({
      scaled <- as.vector(scale(x))
      # Replace any non-finite values after scaling
      scaled[!is.finite(scaled)] <- 0
      scaled_data[[feat]] <- scaled
      cat("Scaled summary:", "\n")
      print(summary(scaled_data[[feat]]))
    }, error = function(e) {
      cat("Error scaling", feat, ":", e$message, "\n")
      # Use raw values if scaling fails
      scaled_data[[feat]] <- x - mean(x, na.rm = TRUE)
    })
  }
  
  # Combine scaled features
  final_data <- bind_cols(
    cluster_data %>% select(token, date),
    scaled_data
  )
  
  # Final verification
  cat("\nFinal data verification:\n")
  print(summary(final_data))
  
  # Check for any remaining issues
  problems <- sapply(final_data[,-c(1:2)], function(x) {
    c(na = sum(is.na(x)),
      inf = sum(!is.finite(x)))
  })
  
  if(any(as.matrix(problems) > 0)) {
    cat("\nProblematic columns found:\n")
    print(problems)
    
    # Fix any remaining problems
    cat("\nAttempting to fix remaining problems...\n")
    for(col in names(final_data)[-(1:2)]) {
      if(sum(is.na(final_data[[col]])) > 0 || sum(!is.finite(final_data[[col]])) > 0) {
        cat("Fixing column:", col, "\n")
        final_data[[col]][!is.finite(final_data[[col]])] <- 0
      }
    }
    
    # Verify fix
    problems_after <- sapply(final_data[,-c(1:2)], function(x) {
      c(na = sum(is.na(x)),
        inf = sum(!is.finite(x)))
    })
    
    if(any(as.matrix(problems_after) > 0)) {
      cat("\nStill have problems after fixing:\n")
      print(problems_after)
      stop("Could not fix all problematic values")
    } else {
      cat("\nAll problems fixed successfully\n")
    }
  }
  
  return(final_data)
}

# ============================================================================
# Optimal Cluster Analysis
# ============================================================================

find_optimal_clusters <- function(data, max_k = 10) {
  # Get numeric columns only
  numeric_cols <- sapply(data, is.numeric)
  features <- as.matrix(data[, numeric_cols])
  
  # Print dimensions
  cat("\nFeature matrix dimensions:", dim(features), "\n")
  
  # Basic checks
  cat("\nChecking for problems:\n")
  cat("NA values:", sum(is.na(features)), "\n")
  cat("Infinite values:", sum(!is.finite(features)), "\n")
  
  # Simple k-means for different k
  wss <- numeric(max_k)
  for(k in 1:max_k) {
    cat("Trying k =", k, "\n")
    km <- kmeans(features, centers = k, nstart = 25)
    wss[k] <- km$tot.withinss
  }
  
  # Plot elbow curve
  plot(1:max_k, wss, type = "b",
       xlab = "Number of Clusters",
       ylab = "Within groups sum of squares",
       main = "Elbow Method")
  
  # Return suggested k
  elbow_k <- which(diff(diff(wss)) > 0)[1] + 1
  if(is.na(elbow_k)) elbow_k <- 3  # default if no clear elbow
  
  return(list(optimal_k = elbow_k))
}

# ============================================================================
# Cluster Analysis
# ============================================================================

analyze_clusters <- function(data, k) {
  # Perform k-means clustering
  features <- data %>% select(-token, -date)
  km <- kmeans(features, centers = k, nstart = 25)
  
  # Add cluster assignments to data
  results <- data %>%
    mutate(cluster = factor(km$cluster))
  
  # Analyze cluster characteristics
  cluster_summary <- results %>%
    group_by(cluster) %>%
    summarise(across(where(is.numeric), list(
      mean = ~mean(., na.rm = TRUE),
      sd = ~sd(., na.rm = TRUE)
    )))
  
  # Analyze token distribution
  token_distribution <- results %>%
    group_by(token, cluster) %>%
    summarise(n = n(), .groups = "drop") %>%
    pivot_wider(names_from = cluster, values_from = n, values_fill = 0)
  
  # Analyze temporal patterns
  temporal_patterns <- results %>%
    group_by(date) %>%
    count(cluster) %>%
    pivot_wider(names_from = cluster, values_from = n, values_fill = 0)
  
  # Return results
  list(
    cluster_assignments = results,
    cluster_summary = cluster_summary,
    token_distribution = token_distribution,
    temporal_patterns = temporal_patterns,
    kmeans_obj = km
  )
}

# ============================================================================
# Visualization
# ============================================================================

plot_cluster_results <- function(cluster_results, data) {
  # Create directory for plots
  dir.create("img/clusters", recursive = TRUE, showWarnings = FALSE)
  
  # Plot 1: PCA visualization of clusters
  pca <- prcomp(data %>% select(-token, -date))
  pca_data <- bind_cols(
    data %>% select(token, date),
    as_tibble(pca$x[,1:2]),
    cluster = factor(cluster_results$kmeans_obj$cluster)
  )
  
  p1 <- ggplot(pca_data, aes(x = PC1, y = PC2, color = cluster)) +
    geom_point(alpha = 0.6) +
    theme_minimal() +
    labs(title = "Cluster Visualization (PCA)")
  
  ggsave("img/clusters/pca_visualization.png", p1, width = 10, height = 8)
  
  # Plot 2: Temporal evolution of clusters
  p2 <- ggplot(cluster_results$cluster_assignments, 
               aes(x = date, fill = cluster)) +
    geom_bar(position = "fill") +
    theme_minimal() +
    labs(title = "Market Regime Evolution Over Time",
         y = "Proportion")
  
  ggsave("img/clusters/temporal_evolution.png", p2, width = 12, height = 6)
  
  # Plot 3: Token distribution across clusters
  p3 <- cluster_results$token_distribution %>%
    gather(cluster, count, -token) %>%
    ggplot(aes(x = token, y = count, fill = cluster)) +
    geom_bar(stat = "identity", position = "fill") +
    theme_minimal() +
    labs(title = "Token Distribution Across Clusters",
         y = "Proportion") +
    theme(axis.text.x = element_text(angle = 45, hjust = 1))
  
  ggsave("img/clusters/token_distribution.png", p3, width = 10, height = 6)
}

# ============================================================================
# Run Analysis
# ============================================================================

# Load data
results <- readRDS("task1_results.rds")

# Prepare data
cluster_data <- prepare_cluster_data(results)

# Find optimal number of clusters
optimal_k <- find_optimal_clusters(cluster_data)
print("Optimal number of clusters:")
print(optimal_k)

# Perform clustering with optimal k
k <- optimal_k$optimal_k  # Or choose based on domain knowledge
cluster_results <- analyze_clusters(cluster_data, k)

# Create visualizations
plot_cluster_results(cluster_results, cluster_data)

# Save results
saveRDS(cluster_results, "cluster_results.rds") 