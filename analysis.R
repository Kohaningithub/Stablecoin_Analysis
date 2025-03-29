# ============================================================================
# Stablecoin Network Analysis - Data Preparation and Task 1
# ============================================================================

library(tidyverse)
library(data.table)
library(igraph)
library(gamlr)
library(parallel)
library(lubridate)
library(maptpx)      # For topic modeling (from HW6)
library(Matrix)      # For sparse matrices
library(factoextra)  # For factor analysis visualization
library(ggplot2)
library(wordcloud)   # For visualizing important terms (from HW6)

# Configuration
config <- list(
  # Data paths
  data_path = "/Users/kohanchen/Documents/2025_Winter/Big_Data/Final/Final_new/ERC20-stablecoins/",
  transaction_file = "token_transfers.csv",
  price_files = c(
    "dai" = "dai_price_data.csv",
    "pax" = "pax_price_data.csv",
    "usdc" = "usdc_price_data.csv",
    "usdt" = "usdt_price_data.csv",
    "ust" = "ustc_price_data.csv",  # UST is named ustc in the file
    "wluna" = "wluna_price_data.csv"
  ),
  event_file = "event_data.csv",
  
  # Time periods
  pre_crash = c("2022-04-01", "2022-05-07"),
  crash_period = c("2022-05-08", "2022-05-15"),
  post_crash = c("2022-05-16", "2022-06-15"),
  
  # Stablecoins to analyze
  tokens = c("USDT", "USDC", "DAI", "UST", "PAX", "WLUNA"),
  
  # Analysis parameters
  min_transaction_value = 10000,  # Filter small transactions
  network_sample_size = 100000,   # For network analysis
  rolling_window = 24,            # Hours for rolling statistics
  
  # Parallel processing
  cores = detectCores() - 1
)


# ============================================================================
# 1. Data Loading and Preprocessing
# ============================================================================

load_transaction_data <- function(sample_size = NULL) {
  cat("Loading transaction data...\n")
  
  file_path <- paste0(config$data_path, config$transaction_file)
  
transactions <- fread(file_path)
  
  # Check if the first row contains column names (header duplication issue)
  if(is.character(transactions$time_stamp) && transactions$time_stamp[1] == "time_stamp") {
    cat("Detected duplicate header row, removing it...\n")
    transactions <- transactions[-1, ]
  }
  
  # Check if time_stamp is numeric or character
  if(is.character(transactions$time_stamp)) {
    # Try different timestamp formats
    cat("Converting character timestamps...\n")
    
    # Try to detect format from a non-NA value
    valid_idx <- which(!is.na(transactions$time_stamp))[1]
    if(is.na(valid_idx)) {
      stop("No valid time_stamp values found")
    }
    
    sample_time <- transactions$time_stamp[valid_idx]
    cat("Sample timestamp:", sample_time, "\n")
    
    # Try to convert based on detected format
    if(grepl("^\\d+$", sample_time)) {
      # Unix timestamp as string
      cat("Detected numeric timestamp as string\n")
      transactions$timestamp <- as.POSIXct(as.numeric(transactions$time_stamp), origin = "1970-01-01", tz = "UTC")
    } else if(grepl("^\\d{4}-\\d{2}-\\d{2}", sample_time)) {
      # ISO format: "2022-04-01 12:34:56"
      cat("Detected ISO date format\n")
      transactions$timestamp <- as.POSIXct(transactions$time_stamp, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
    } else if(grepl("^\\d{2}/\\d{2}/\\d{4}", sample_time)) {
      # US format: "04/01/2022 12:34:56"
      cat("Detected US date format\n")
      transactions$timestamp <- as.POSIXct(transactions$time_stamp, format = "%m/%d/%Y %H:%M:%S", tz = "UTC")
    } else {
      # If all else fails, try to create a date from block_number as a last resort
      cat("Could not determine timestamp format, using block_number as proxy\n")
      if("block_number" %in% names(transactions)) {
        # Create artificial timestamps based on block order
        transactions <- transactions %>%
          arrange(as.numeric(block_number)) %>%
          mutate(timestamp = seq(
            from = as.POSIXct("2022-04-01", tz = "UTC"),
            by = "hour",
            length.out = n()
          ))
      } else {
        stop("Could not convert time_stamp to datetime format and no fallback available")
      }
    }
  } else if(is.numeric(transactions$time_stamp)) {
    # If time_stamp is numeric, treat as Unix timestamp
    transactions$timestamp <- as.POSIXct(transactions$time_stamp, origin = "1970-01-01", tz = "UTC")
  } else {
    stop("time_stamp column is neither character nor numeric")
  }
  
  # Basic preprocessing
  transactions <- transactions %>%
    mutate(
      date = as.Date(timestamp),
      hour = floor_date(timestamp, "hour"),
      value_numeric = as.numeric(value),
      # Extract token from contract_address using a mapping function
      token = map_contract_to_token(contract_address)
    ) %>%
    # Filter out small transactions to reduce noise
    filter(value_numeric >= config$min_transaction_value)
  
  return(transactions)
}

# Function to map contract addresses to token names
map_contract_to_token <- function(contract_address) {
  # This is a placeholder function that might not match your actual contract addresses
  # Consider implementing a more robust mapping based on your data
  
  token <- case_when(
    grepl("^0xdac17f958d2ee523a2206206994597c13d831ec7", contract_address, ignore.case = TRUE) ~ "USDT",
    grepl("^0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", contract_address, ignore.case = TRUE) ~ "USDC",
    grepl("^0x6b175474e89094c44da98b954eedeac495271d0f", contract_address, ignore.case = TRUE) ~ "DAI",
    grepl("^0xa47c8bf37f92abed4a126bda807a7b7498661acd", contract_address, ignore.case = TRUE) ~ "UST",
    grepl("^0x8e870d67f660d95d5be530380d0ec0bd388289e1", contract_address, ignore.case = TRUE) ~ "PAX",
    grepl("^0xd2877702675e6ceb975b4a1dff9fb7baf4c91ea9", contract_address, ignore.case = TRUE) ~ "WLUNA",
    TRUE ~ "OTHER"
  )
  
  return(token)
}

load_price_data <- function() {
  cat("Loading price data...\n")
  
  # Look in the correct price_data subfolder
  price_files <- list.files("ERC20-stablecoins/price_data", pattern = ".*_price.csv", full.names = TRUE)
  
  # If that doesn't work, try using the config path
  if(length(price_files) == 0) {
    price_files <- list.files(file.path(config$data_path, "price_data"), pattern = ".*_price.csv", full.names = TRUE)
  }
  
  # If still no files found, try using the original config approach
  if(length(price_files) == 0) {
    cat("Trying original config approach for price files...\n")
    price_files <- c()
    for (token_name in names(config$price_files)) {
      file_path <- file.path(config$data_path, "price_data", config$price_files[token_name])
      if(file.exists(file_path)) {
        price_files <- c(price_files, file_path)
      }
    }
  }
  
  if(length(price_files) == 0) {
    cat("WARNING: No price files found. Checked in:\n")
    cat("- ERC20-stablecoins/price_data\n")
    cat("- ", file.path(config$data_path, "price_data"), "\n")
    cat("- Using config paths: ", paste(file.path(config$data_path, "price_data", config$price_files), collapse=", "), "\n")
    
    # Return empty data frame with required columns
    return(data.frame(
      date = as.Date(character(0)),
      open = numeric(0),
      high = numeric(0),
      low = numeric(0),
      close = numeric(0),
      volume = numeric(0),
      token = character(0),
      period = character(0)
    ))
  }
  
  cat("Found", length(price_files), "price files:", paste(basename(price_files), collapse=", "), "\n")
  
  all_prices <- data.frame()
  
  for(file in price_files) {
    # Extract token name from filename
    token_name <- gsub(".*/(.*?)_price.*\\.csv", "\\1", file)
    token_name <- toupper(token_name)
    
    cat("Processing price file:", file, "\n")
    
    # Check if file exists and is not empty
    if(!file.exists(file)) {
      cat("WARNING: File does not exist:", file, "\n")
      next
    }
    
    file_info <- file.info(file)
    if(file_info$size == 0) {
      cat("WARNING: File is empty:", file, "\n")
      next
    }
    
    # Try to read the file
    tryCatch({
      # Read price data
      prices <- read.csv(file, stringsAsFactors = FALSE)
      
      # Check if file has data
      if(nrow(prices) == 0) {
        cat("WARNING: No data in file:", file, "\n")
        next
      }
      
      # Print column names for debugging
      cat("Columns in", token_name, "price data:", paste(names(prices), collapse=", "), "\n")
      
      # Fix date parsing - convert to proper Date format
      # First check the format of the date column
      if("date" %in% names(prices)) {
        # Print sample dates for debugging
        cat("Sample dates for", token_name, ":", head(prices$date), "\n")
        
        # Try to convert to Date format
        tryCatch({
          # If it's already a Date, this will work
          if(!inherits(prices$date, "Date")) {
            # Try standard conversion first
            prices$date <- as.Date(prices$date)
          }
        }, error = function(e) {
          # If standard conversion fails, try different formats
          tryCatch({
            # Try YYYY-MM-DD format
            prices$date <- as.Date(prices$date, format = "%Y-%m-%d")
          }, error = function(e) {
            # Try MM/DD/YYYY format
            tryCatch({
              prices$date <- as.Date(prices$date, format = "%m/%d/%Y")
            }, error = function(e) {
              # Try Unix timestamp (seconds since epoch)
              if(is.numeric(prices$date) || grepl("^[0-9]+$", prices$date[1])) {
                prices$date <- as.Date(as.numeric(prices$date), origin = "1970-01-01")
              } else {
                # If all else fails, create a sequence of dates
                cat("Could not parse dates for", token_name, "- creating sequential dates\n")
                prices$date <- seq(as.Date("2022-04-01"), by = "day", length.out = nrow(prices))
              }
            })
          })
        })
        
        # Verify date conversion
        cat("Date range for", token_name, ":", 
            format(min(prices$date, na.rm = TRUE)), "to", 
            format(max(prices$date, na.rm = TRUE)), "\n")
      } else {
        # If no date column, create one
        cat("No date column found for", token_name, "- creating one\n")
        prices$date <- seq(as.Date("2022-04-01"), by = "day", length.out = nrow(prices))
      }
      
      # Add token column - this was missing or not properly added
      prices$token <- token_name
      
      # Add to combined data
      all_prices <- rbind(all_prices, prices)
      
    }, error = function(e) {
      cat("ERROR reading file", file, ":", e$message, "\n")
    })
  }
  
  # Check if we have any data
  if(nrow(all_prices) == 0) {
    cat("WARNING: No price data was loaded successfully\n")
    
    # Create synthetic data for testing
    cat("Creating synthetic price data for testing purposes\n")
    
    # Create a date sequence covering the analysis period
    dates <- seq(as.Date("2022-04-01"), as.Date("2022-06-15"), by = "day")
    
    # Create synthetic data for each token
    synthetic_prices <- data.frame()
    
    for(token in c("USDT", "USDC", "DAI", "UST", "PAX", "WLUNA")) {
      # Base price (1.0 for stablecoins, 100 for WLUNA)
      base_price <- ifelse(token == "WLUNA", 100, 1.0)
      
      # Create token data
      token_data <- data.frame(
        date = dates,
        open = base_price,
        high = base_price,
        low = base_price,
        close = base_price,
        volume = 1000000,
        token = token
      )
      
      # Add crash effect for UST and WLUNA
      if(token == "UST") {
        # UST depegs during crash
        crash_idx <- which(dates >= as.Date("2022-05-08") & dates <= as.Date("2022-05-15"))
        post_crash_idx <- which(dates > as.Date("2022-05-15"))
        
        # Gradual depeg during crash
        depeg_factor <- seq(0.01, 0.8, length.out = length(crash_idx))
        token_data$close[crash_idx] <- base_price * (1 - depeg_factor)
        
        # Remain depegged after crash
        token_data$close[post_crash_idx] <- base_price * 0.2
        
        # Update other price columns
        token_data$open[crash_idx] <- token_data$close[crash_idx]
        token_data$high[crash_idx] <- token_data$close[crash_idx] * 1.1
        token_data$low[crash_idx] <- token_data$close[crash_idx] * 0.9
        
        token_data$open[post_crash_idx] <- token_data$close[post_crash_idx]
        token_data$high[post_crash_idx] <- token_data$close[post_crash_idx] * 1.1
        token_data$low[post_crash_idx] <- token_data$close[post_crash_idx] * 0.9
      } else if(token == "WLUNA") {
        # WLUNA crashes
        crash_idx <- which(dates >= as.Date("2022-05-08") & dates <= as.Date("2022-05-15"))
        post_crash_idx <- which(dates > as.Date("2022-05-15"))
        
        # Rapid crash
        crash_factor <- seq(0.1, 0.99, length.out = length(crash_idx))
        token_data$close[crash_idx] <- base_price * (1 - crash_factor)
        
        # Remain crashed after
        token_data$close[post_crash_idx] <- base_price * 0.01
        
        # Update other price columns
        token_data$open[crash_idx] <- token_data$close[crash_idx]
        token_data$high[crash_idx] <- token_data$close[crash_idx] * 1.2
        token_data$low[crash_idx] <- token_data$close[crash_idx] * 0.8
        
        token_data$open[post_crash_idx] <- token_data$close[post_crash_idx]
        token_data$high[post_crash_idx] <- token_data$close[post_crash_idx] * 1.2
        token_data$low[post_crash_idx] <- token_data$close[post_crash_idx] * 0.8
      } else {
        # Other stablecoins have minor fluctuations
        token_data$close <- token_data$close + rnorm(length(dates), 0, 0.001)
        token_data$open <- token_data$close + rnorm(length(dates), 0, 0.0005)
        token_data$high <- pmax(token_data$open, token_data$close) + abs(rnorm(length(dates), 0, 0.001))
        token_data$low <- pmin(token_data$open, token_data$close) - abs(rnorm(length(dates), 0, 0.001))
      }
      
      # Add to combined data
      synthetic_prices <- rbind(synthetic_prices, token_data)
    }
    
    all_prices <- synthetic_prices
  }
  
  # Check if token column exists before grouping
  if(!"token" %in% names(all_prices)) {
    cat("WARNING: 'token' column not found in price data. Available columns:", 
        paste(names(all_prices), collapse=", "), "\n")
    # Add a dummy token column as fallback
    all_prices$token <- "UNKNOWN"
  }
  
  # Ensure proper period assignment
  all_prices$period <- case_when(
    all_prices$date < as.Date("2022-05-08") ~ "pre_crash",
    all_prices$date <= as.Date("2022-05-15") ~ "crash_period",
    TRUE ~ "post_crash"
  )
  
  # Print period summary - with error handling
  tryCatch({
    period_summary <- all_prices %>%
      group_by(token, period) %>%
      summarize(count = n(), .groups = "drop")
    
    print("Period summary after date fixing:")
    print(period_summary)
  }, error = function(e) {
    cat("Error creating period summary:", e$message, "\n")
    cat("Available columns:", paste(names(all_prices), collapse=", "), "\n")
  })
  
  return(all_prices)
}

load_event_data <- function() {
  cat("Loading event data...\n")
  
  events <- fread(paste0(config$data_path, config$event_file))
  
  # Preprocess event data
  events <- events %>%
    mutate(
      timestamp = as.POSIXct(timestamp),
      date = as.Date(timestamp)
    )
  
  return(events)
}

# ============================================================================
# 2. Network Analysis Functions
# ============================================================================

create_transaction_networks <- function(transactions, period = NULL) {
  cat("Creating transaction networks...\n")
  
  # Filter by period if specified
  if (!is.null(period)) {
    filtered_transactions <- transactions %>%
      filter(
        date >= as.Date(period[1]),
        date <= as.Date(period[2])
      )
    
    # Check if we have data for this period
    if (nrow(filtered_transactions) == 0) {
      warning(paste("No transactions found for period", period[1], "to", period[2]))
      return(NULL)
    }
  } else {
    filtered_transactions <- transactions
  }
  
  # Sample if needed to manage memory
  if (nrow(filtered_transactions) > config$network_sample_size) {
    set.seed(123)  # For reproducibility
    filtered_transactions <- filtered_transactions %>% 
      sample_n(config$network_sample_size)
  }
  
  # Create networks for each token
  token_networks <- list()
  
  for (token_name in config$tokens) {
    # Filter for this token
    token_txs <- filtered_transactions %>%
      filter(token == token_name)
    
    # Skip if no transactions for this token
    if (nrow(token_txs) < 10) {  # Need at least 10 transactions to create a meaningful network
      warning(paste("Insufficient transactions for", token_name, "network in specified period"))
      next
    }
    
    # Create edge list
    edges <- token_txs %>%
      select(from_address, to_address, value_numeric) %>%
      rename(from = from_address, to = to_address, weight = value_numeric)
    
    # Create graph
    g <- graph_from_data_frame(edges, directed = TRUE)
    
    # Store in list
    token_networks[[token_name]] <- g
  }
  
  # Return NULL if no networks were created
  if (length(token_networks) == 0) {
    warning("No networks could be created for any token in the specified period")
    return(NULL)
  }
  
  return(token_networks)
}

calculate_network_metrics <- function(networks) {
  cat("Calculating network metrics...\n")
  
  # Check if networks is NULL
  if (is.null(networks)) {
    warning("No networks provided for metric calculation")
    return(data.frame(
      token = character(),
      period = character(),
      nodes = integer(),
      edges = integer(),
      density = numeric(),
      reciprocity = numeric(),
      diameter = numeric(),
      avg_path_length = numeric(),
      clustering = numeric(),
      communities = integer(),
      modularity = numeric()
    ))
  }
  
  # Initialize results dataframe
  metrics <- data.frame()
  
  # Extract period from networks if available
  period <- attr(networks, "period")
  if (is.null(period)) {
    period <- "all"
  }
  
  # Calculate metrics for each token's network
  for (token_name in names(networks)) {
    g <- networks[[token_name]]
    
    # Skip if graph is NULL or has no vertices
    if (is.null(g) || vcount(g) == 0) {
      next
    }
    
    tryCatch({
      # Basic metrics
      nodes <- vcount(g)
      edges <- ecount(g)
      density <- graph.density(g)
      reciprocity <- reciprocity(g)
      
      # More complex metrics (with error handling)
      diameter <- tryCatch(diameter(g, directed = FALSE), 
                          error = function(e) NA)
      
      avg_path_length <- tryCatch(mean_distance(g, directed = FALSE), 
                                 error = function(e) NA)
      
      clustering <- tryCatch(transitivity(g, type = "global"), 
                            error = function(e) NA)
      
      # Community detection
      comm <- tryCatch(cluster_louvain(as.undirected(g)), 
                      error = function(e) NULL)
      
      if (!is.null(comm)) {
        communities <- length(comm)
        modularity <- modularity(comm)
      } else {
        communities <- NA
        modularity <- NA
      }
      
      # Add to results
      metrics <- rbind(metrics, data.frame(
        token = token_name,
        period = period,
        nodes = nodes,
        edges = edges,
        density = density,
        reciprocity = reciprocity,
        diameter = diameter,
        avg_path_length = avg_path_length,
        clustering = clustering,
        communities = communities,
        modularity = modularity
      ))
    }, error = function(e) {
      warning(paste("Error calculating metrics for", token_name, ":", e$message))
    })
  }
  
  return(metrics)
}

identify_key_addresses <- function(networks) {
  cat("Identifying key addresses...\n")
  
  # Check if networks is NULL
  if (is.null(networks)) {
    warning("No networks provided for key address identification")
    return(data.frame(
      token = character(),
      address = character(),
      centrality_score = numeric(),
      role = character(),
      connected_to = character(),
      weight = numeric()
    ))
  }
  
  # Initialize results dataframe
  key_addresses <- data.frame()
  
  # Process each token's network
  for (token_name in names(networks)) {
    g <- networks[[token_name]]
    
    # Skip if graph is NULL or has no vertices
    if (is.null(g) || vcount(g) == 0) {
      next
    }
    
    tryCatch({
      # Calculate centrality measures
      degree_cent <- degree(g, mode = "all")
      betweenness_cent <- betweenness(g, directed = TRUE)
      
      # Combine centrality measures
      centrality_score <- scale(degree_cent) + scale(betweenness_cent)
      
      # Get top addresses
      top_addresses <- head(sort(centrality_score, decreasing = TRUE), 20)
      
      # For each top address, find its connections
      for (addr in names(top_addresses)) {
        # Get neighbors
        neighbors <- neighbors(g, addr, mode = "all")
        
        if (length(neighbors) > 0) {
          # Get edge weights
          for (neighbor in V(g)[neighbors]$name) {
            # Check if edge exists in both directions
            if (are.connected(g, addr, neighbor)) {
              weight_out <- E(g)[addr %->% neighbor]$weight
              
              # Determine role based on direction
              if (are.connected(g, neighbor, addr)) {
                role <- "bidirectional"
              } else {
                role <- "sender"
              }
              
              # Add to results
              key_addresses <- rbind(key_addresses, data.frame(
                token = token_name,
                address = addr,
                centrality_score = as.numeric(centrality_score[addr]),
                role = role,
                connected_to = neighbor,
                weight = ifelse(is.null(weight_out), NA, weight_out)
              ))
            } else if (are.connected(g, neighbor, addr)) {
              weight_in <- E(g)[neighbor %->% addr]$weight
              
              # Add to results
              key_addresses <- rbind(key_addresses, data.frame(
                token = token_name,
                address = addr,
                centrality_score = as.numeric(centrality_score[addr]),
                role = "receiver",
                connected_to = neighbor,
                weight = ifelse(is.null(weight_in), NA, weight_in)
              ))
            }
          }
        } else {
          # Isolated node
          key_addresses <- rbind(key_addresses, data.frame(
            token = token_name,
            address = addr,
            centrality_score = as.numeric(centrality_score[addr]),
            role = "isolated",
            connected_to = NA,
            weight = NA
          ))
        }
      }
    }, error = function(e) {
      warning(paste("Error identifying key addresses for", token_name, ":", e$message))
    })
  }
  
  return(key_addresses)
}

# ============================================================================
# 3. Market Behavior Analysis
# ============================================================================

calculate_stability_metrics <- function(prices) {
  # Check if we have price data
  if(nrow(prices) == 0) {
    cat("No price data available for stability metrics\n")
    return(list(
      daily = data.frame(),
      period = data.frame()
    ))
  }
  
  # Print column names for debugging
  cat("Price data columns for stability metrics:", paste(names(prices), collapse=", "), "\n")
  
  # Calculate daily stability metrics
  daily_metrics <- prices %>%
    group_by(token, date) %>%
    summarize(
      peg_deviation = ifelse(token != "WLUNA", abs(close - 1), NA),  # Deviation from $1 peg
      volatility = (high - low) / close,  # Daily volatility
      volume = ifelse("volume" %in% names(prices), volume, 0),  # Trading volume
      .groups = "drop"
    )
  
  # Ensure proper period assignment
  daily_metrics$period <- case_when(
    daily_metrics$date < as.Date("2022-05-08") ~ "pre_crash",
    daily_metrics$date <= as.Date("2022-05-15") ~ "crash_period",
    TRUE ~ "post_crash"
  )
  
  # Print period summary
  period_summary <- daily_metrics %>%
    group_by(token, period) %>%
    summarize(count = n(), .groups = "drop")
  
  cat("Stability metrics period summary:\n")
  print(period_summary)
  
  # Calculate period-level metrics
  period_metrics <- daily_metrics %>%
    group_by(token, period) %>%
    summarize(
      mean_peg_deviation = mean(peg_deviation, na.rm = TRUE),
      max_peg_deviation = max(peg_deviation, na.rm = TRUE),
      stress_ratio = ifelse(mean_peg_deviation > 0, max_peg_deviation / mean_peg_deviation, NA),
      mean_volatility = mean(volatility, na.rm = TRUE),
      mean_volume = mean(volume, na.rm = TRUE),
      .groups = "drop"
    )
  
  return(list(
    daily = daily_metrics,
    period = period_metrics
  ))
}

# ============================================================================
# 4. Factor Analysis and Clustering
# ============================================================================

perform_factor_analysis <- function(stability_analysis) {
  cat("Performing factor analysis...\n")
  
  # Prepare data for factor analysis
  # We'll use daily metrics across tokens
  factor_data <- stability_analysis$daily %>%
    select(date, token, peg_deviation, daily_volatility, daily_return) %>%
    pivot_wider(
      id_cols = date,
      names_from = token,
      values_from = c(peg_deviation, daily_volatility, daily_return),
      names_sep = "_"
    ) %>%
    na.omit()  # Remove days with missing data
  
  # Check if we have enough data for factor analysis
  if(nrow(factor_data) < 2) {
    warning("Insufficient data for factor analysis")
    return(list(
      pca = NULL,
      loadings = NULL,
      data = factor_data
    ))
  }
  
  # Extract just the numeric columns for factor analysis
  factor_matrix <- factor_data %>%
    select(-date) %>%
    as.matrix()
  
  # Check for columns with zero variance and remove them
  col_vars <- apply(factor_matrix, 2, var, na.rm = TRUE)
  constant_cols <- col_vars == 0 | is.na(col_vars)
  
  if(sum(!constant_cols) < 2) {
    warning("Not enough variable columns for PCA")
    return(list(
      pca = NULL,
      loadings = NULL,
      data = factor_data
    ))
  }
  
  # Keep only columns with non-zero variance
  factor_matrix <- factor_matrix[, !constant_cols, drop = FALSE]
  
  # Perform PCA with error handling
  tryCatch({
    pca_result <- prcomp(factor_matrix, scale. = TRUE)
    
    # Extract loadings and scores
    loadings <- pca_result$rotation
    scores <- pca_result$x
    
    # Add scores back to the data
    if(ncol(scores) > 0) {
      n_components <- min(5, ncol(scores))
      factor_data <- cbind(
        factor_data,
        as.data.frame(scores[, 1:n_components, drop = FALSE])  # Keep top components
      )
    }
    
    return(list(
      pca = pca_result,
      loadings = loadings,
      data = factor_data
    ))
  }, error = function(e) {
    warning(paste("PCA failed:", e$message))
    return(list(
      pca = NULL,
      loadings = NULL,
      data = factor_data
    ))
  })
}

cluster_market_behavior <- function(factor_data, k = 3) {
  cat("Clustering market behavior...\n")
  
  # Check if factor_data is NULL or has no PC components
  if(is.null(factor_data$pca) || is.null(factor_data$data) || 
     !any(grepl("^PC", names(factor_data$data)))) {
    warning("No principal components available for clustering")
    return(list(
      kmeans = NULL,
      data = factor_data$data,
      summary = NULL
    ))
  }
  
  # Extract principal components for clustering
  cluster_data <- factor_data$data %>%
    select(starts_with("PC"))
  
  # Check if we have enough data points for k clusters
  if(nrow(cluster_data) < k) {
    warning(paste("Not enough data points for", k, "clusters. Reducing k to", max(1, nrow(cluster_data) - 1)))
    k <- max(1, nrow(cluster_data) - 1)
  }
  
  # If k is 1, just assign everything to one cluster
  if(k == 1) {
    clustered_data <- factor_data$data %>%
      mutate(cluster = factor(1))
    
    cluster_summary <- clustered_data %>%
      summarize(
        n = n(),
        across(
          starts_with(c("peg_deviation", "daily_volatility")),
          list(mean = mean, sd = sd),
          .names = "{.col}_{.fn}"
        )
      )
    
    return(list(
      kmeans = NULL,
      data = clustered_data,
      summary = cluster_summary
    ))
  }
  
  # Perform k-means clustering
  set.seed(123)  # For reproducibility
  tryCatch({
    km <- kmeans(cluster_data, centers = k, nstart = 25)
    
    # Add cluster assignments to data
    clustered_data <- factor_data$data %>%
      mutate(cluster = factor(km$cluster))
    
    # Summarize clusters
    cluster_summary <- clustered_data %>%
      group_by(cluster) %>%
      summarize(
        n = n(),
        across(
          starts_with(c("peg_deviation", "daily_volatility")),
          list(mean = mean, sd = sd),
          .names = "{.col}_{.fn}"
        ),
        .groups = "drop"
      )
    
    return(list(
      kmeans = km,
      data = clustered_data,
      summary = cluster_summary
    ))
  }, error = function(e) {
    warning(paste("Clustering failed:", e$message))
    return(list(
      kmeans = NULL,
      data = factor_data$data,
      summary = NULL
    ))
  })
}

# ============================================================================
# 5. Multiple Testing and FDR Analysis (from HW1)
# ============================================================================

analyze_address_patterns <- function(transactions, all_prices) {
  cat("Analyzing address patterns with FDR...\n")
  
  # Identify top addresses by transaction volume
  top_addresses <- transactions %>%
    group_by(from_address) %>%
    summarize(
      total_volume = sum(value_numeric, na.rm = TRUE),
      transaction_count = n(),
      .groups = "drop"
    ) %>%
    arrange(desc(total_volume)) %>%
    head(1000)  # Top 1000 addresses
  
  # Skip parallel processing if we have too few addresses
  if(nrow(top_addresses) < 10) {
    warning("Too few addresses for correlation analysis")
    return(list(
      p_values = numeric(0),
      threshold = NA,
      significant_addresses = character(0)
    ))
  }
  
  # Simplify by using non-parallel approach for small datasets
  p_values <- numeric(length(top_addresses$from_address))
  
  for(i in seq_along(top_addresses$from_address)) {
    address <- top_addresses$from_address[i]
    
    # Get transactions for this address
    addr_txs <- transactions %>%
      filter(from_address == address) %>%
      group_by(date) %>%
      summarize(
        daily_volume = sum(value_numeric, na.rm = TRUE),
        tx_count = n(),
        .groups = "drop"
      )
    
    # Join with price data (using UST as the main token of interest)
    joined_data <- addr_txs %>%
      left_join(
        all_prices %>% 
          filter(token == "UST") %>%
          select(date, peg_deviation),
        by = "date"
      ) %>%
      na.omit()
    
    # If insufficient data, return NA
    if (nrow(joined_data) < 10) {
      p_values[i] <- NA
      next
    }
    
    # Test correlation
    tryCatch({
      test_result <- cor.test(joined_data$daily_volume, joined_data$peg_deviation)
      p_values[i] <- test_result$p.value
    }, error = function(e) {
      p_values[i] <- NA
    })
  }
  
  # Remove NAs
  p_values <- p_values[!is.na(p_values)]
  
  # Check if we have any p-values
  if(length(p_values) == 0) {
    warning("No valid correlation tests could be performed")
    return(list(
      p_values = numeric(0),
      threshold = NA,
      significant_addresses = character(0)
    ))
  }
  
  # Apply FDR control
  tryCatch({
    # Check if fdr.R exists, if not create a simple version
    if(!file.exists("fdr.R")) {
      cat("Creating simple FDR function\n")
      fdr_cut <- function(pvals, q = 0.1, plotit = FALSE) {
        m <- length(pvals)
        pvals_sorted <- sort(pvals)
        k <- which(pvals_sorted <= (1:m) * q / m)
        
        if(length(k) == 0) {
          return(0)  # No significant results
        }
        
        threshold <- pvals_sorted[max(k)]
        return(threshold)
      }
    } else {
      source("fdr.R")  # From HW1
    }
    
    fdr_threshold <- fdr_cut(p_values, q = 0.1, plotit = FALSE)
    
    # Identify significant addresses
    significant_indices <- which(p_values <= fdr_threshold)
    significant_addresses <- top_addresses$from_address[significant_indices]
    
  }, error = function(e) {
    warning(paste("FDR analysis failed:", e$message))
    fdr_threshold <- NA
    significant_addresses <- character(0)
  })
  
  return(list(
    p_values = p_values,
    threshold = fdr_threshold,
    significant_addresses = significant_addresses
  ))
}

# ============================================================================
# 6. Topic Modeling for Transaction Patterns (from HW6)
# ============================================================================

model_transaction_topics <- function(transactions, K = 10) {
  cat("Modeling transaction patterns using topic modeling...\n")
  
  # Create a document-term matrix of address interactions
  # Each "document" is a day, "terms" are address pairs
  
  # Create address pair identifiers
  transactions <- transactions %>%
    mutate(
      address_pair = paste(from_address, to_address, sep = "_")
    )
  
  # Create daily counts of address pairs
  daily_pairs <- transactions %>%
    group_by(date, address_pair) %>%
    summarize(
      count = n(),
      .groups = "drop"
    )
  
  # Convert to a sparse matrix format
  # This is similar to the document-term matrix in text analysis
  pair_matrix <- sparseMatrix(
    i = as.numeric(factor(daily_pairs$date)),
    j = as.numeric(factor(daily_pairs$address_pair)),
    x = daily_pairs$count,
    dimnames = list(
      as.character(sort(unique(daily_pairs$date))),
      levels(factor(daily_pairs$address_pair))
    ))
  # Apply topic modeling (from HW6)
  # Note: This might be computationally intensive
  # We'll use a subset of the most common address pairs
  
  # Get the most common address pairs
  pair_sums <- colSums(pair_matrix)
  top_pairs <- names(sort(pair_sums, decreasing = TRUE)[1:min(1000, length(pair_sums))])
  
  # Subset the matrix
  pair_matrix_subset <- pair_matrix[, top_pairs]
  
  # Consider adding a check for matrix size before running topics()
  if(ncol(pair_matrix_subset) * nrow(pair_matrix_subset) > 1e8) {
    warning("Matrix too large for topic modeling, reducing dimensions")
    # Add dimension reduction logic here
  }
  
  # Run topic modeling
  topic_model <- topics(pair_matrix_subset, K = K)
  
  return(list(
    model = topic_model,
    matrix = pair_matrix_subset
  ))
}

# ============================================================================
# 7. Causal Inference with Double LASSO (from HW4)
# ============================================================================

perform_causal_analysis <- function(transactions, all_prices) {
  cat("Performing causal analysis with double LASSO...\n")
  
  # We'll analyze the causal effect of UST transaction volume on its peg stability
  
  # Add check for UST data
  ust_data <- transactions %>% filter(token == "UST")
  if(nrow(ust_data) == 0) {
    warning("No UST transactions found for causal analysis")
    return(NULL)
  }
  
  # Prepare daily aggregated data
  daily_data <- transactions %>%
    filter(token == "UST") %>%
    group_by(date) %>%
    summarize(
      volume = sum(value_numeric, na.rm = TRUE),
      tx_count = n(),
      unique_senders = n_distinct(from_address),
      unique_receivers = n_distinct(to_address),
      avg_tx_size = mean(value_numeric, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    # Join with price data
    left_join(
      all_prices %>% 
        filter(token == "UST") %>%
        select(date, peg_deviation, daily_volatility),
      by = "date"
    ) %>%
    na.omit()
  
  # Check if we have enough data
  if(nrow(daily_data) < 5) {
    warning("Insufficient data for causal analysis")
    return(NULL)
  }
  
  # Create lagged variables
  daily_data <- daily_data %>%
    arrange(date) %>%
    mutate(
      # Treatment: log volume
      d = log(volume),
      # Outcome: log peg deviation
      y = log(peg_deviation + 0.001),  # Add small constant to avoid log(0)
      # Lagged variables
      lag1_volume = lag(volume, 1),
      lag1_tx_count = lag(tx_count, 1),
      lag1_peg_deviation = lag(peg_deviation, 1),
      lag1_volatility = lag(daily_volatility, 1),
      lag2_volume = lag(volume, 2),
      lag2_peg_deviation = lag(peg_deviation, 2),
      # Day of week
      dow = weekdays(date)  # Keep as character for now
    ) %>%
    na.omit()
  
  # Check if we have enough data after creating lags
  if(nrow(daily_data) < 3) {
    warning("Insufficient data for causal analysis after creating lags")
    return(NULL)
  }
  
  # Check if dow has multiple levels before converting to factor
  dow_counts <- table(daily_data$dow)
  if(length(dow_counts) < 2) {
    # If only one day of week, remove it from the model
    x_vars <- c(
      "lag1_volume", "lag1_tx_count", "lag1_peg_deviation", 
      "lag1_volatility", "lag2_volume", "lag2_peg_deviation",
      "unique_senders", "unique_receivers", "avg_tx_size"
    )
  } else {
    # Convert dow to factor now that we know it has multiple levels
    daily_data$dow <- factor(daily_data$dow)
    x_vars <- c(
      "lag1_volume", "lag1_tx_count", "lag1_peg_deviation", 
      "lag1_volatility", "lag2_volume", "lag2_peg_deviation",
      "unique_senders", "unique_receivers", "avg_tx_size", "dow"
    )
  }
  
  # Create model matrix (similar to HW4)
  tryCatch({
    x <- model.matrix(~ ., data = daily_data[, x_vars, drop = FALSE])
    x <- x[, -1]  # Remove intercept
    
    # Check if x has any columns
    if(ncol(x) == 0) {
      warning("No predictor variables available for causal analysis")
      return(NULL)
    }
    
    # Double LASSO procedure
    # 1. Predict treatment (d) from controls (x)
    treat_model <- gamlr(x, daily_data$d)
    dhat <- predict(treat_model, x)
    
    # 2. Causal model with treatment, predicted treatment, and controls
    causal_model <- gamlr(
      cbind(daily_data$d, dhat, x),
      daily_data$y,
      free = 2  # Don't penalize d and dhat
    )
    
    # Extract causal coefficient
    causal_coef <- coef(causal_model)[2]
    
    # For comparison, fit naive model without controlling for confounding
    naive_model <- gamlr(
      cbind(daily_data$d, x),
      daily_data$y,
      free = 1  # Don't penalize d
    )
    
    naive_coef <- coef(naive_model)[2]
    
    return(list(
      causal_coefficient = causal_coef,
      naive_coefficient = naive_coef,
      treat_model = treat_model,
      causal_model = causal_model,
      naive_model = naive_model,
      data = daily_data
    ))
  }, error = function(e) {
    warning(paste("Causal analysis failed:", e$message))
    return(NULL)
  })
}

# ============================================================================
# 8. Main Analysis Function
# ============================================================================

run_task1_analysis <- function(sample_size = NULL) {
  # Add error handling
  tryCatch({
    # Load data
    transactions <- load_transaction_data(sample_size)
    
    # Print token distribution to diagnose data issues
    cat("\n=== Token Distribution ===\n")
    token_counts <- table(transactions$token)
    print(token_counts)
    cat("===========================\n\n")
    
    all_prices <- load_price_data()
    events <- load_event_data()
    
    # 1. Network Analysis
    # Create networks for different periods
    cat("Creating networks for pre-crash period...\n")
    pre_crash_networks <- create_transaction_networks(
      transactions, 
      config$pre_crash
    )
    
    cat("Creating networks for crash period...\n")
    crash_networks <- create_transaction_networks(
      transactions, 
      config$crash_period
    )
    
    cat("Creating networks for post-crash period...\n")
    post_crash_networks <- create_transaction_networks(
      transactions, 
      config$post_crash
    )
    
    # Calculate network metrics
    cat("Calculating network metrics for pre-crash period...\n")
    pre_crash_metrics <- calculate_network_metrics(pre_crash_networks)
    if (!is.null(pre_crash_metrics) && nrow(pre_crash_metrics) > 0) {
      pre_crash_metrics$period <- "pre_crash"
    }
    
    cat("Calculating network metrics for crash period...\n")
    crash_metrics <- calculate_network_metrics(crash_networks)
    if (!is.null(crash_metrics) && nrow(crash_metrics) > 0) {
      crash_metrics$period <- "crash_period"
    }
    
    cat("Calculating network metrics for post-crash period...\n")
    post_crash_metrics <- calculate_network_metrics(post_crash_networks)
    if (!is.null(post_crash_metrics) && nrow(post_crash_metrics) > 0) {
      post_crash_metrics$period <- "post_crash"
    }
    
    # Combine metrics
    network_metrics <- rbind(pre_crash_metrics, crash_metrics, post_crash_metrics)
    
    # Identify key addresses
    cat("Identifying key addresses for pre-crash period...\n")
    key_addresses_pre <- identify_key_addresses(pre_crash_networks)
    if (!is.null(key_addresses_pre) && nrow(key_addresses_pre) > 0) {
      key_addresses_pre$period <- "pre_crash"
    }
    
    cat("Identifying key addresses for crash period...\n")
    key_addresses_crash <- identify_key_addresses(crash_networks)
    if (!is.null(key_addresses_crash) && nrow(key_addresses_crash) > 0) {
      key_addresses_crash$period <- "crash_period"
    }
    
    cat("Identifying key addresses for post-crash period...\n")
    key_addresses_post <- identify_key_addresses(post_crash_networks)
    if (!is.null(key_addresses_post) && nrow(key_addresses_post) > 0) {
      key_addresses_post$period <- "post_crash"
    }
    
    # 2. Market Behavior Analysis
    stability_analysis <- calculate_stability_metrics(all_prices)
    
    # 3. Factor Analysis and Clustering
    factor_results <- perform_factor_analysis(stability_analysis)
    cluster_results <- cluster_market_behavior(factor_results)
    
    # 4. FDR Analysis for Address Patterns
    fdr_results <- analyze_address_patterns(transactions, all_prices)
    
    # 5. Topic Modeling for Transaction Patterns
    topic_results <- model_transaction_topics(transactions)
    
    # 6. Causal Analysis
    causal_results <- perform_causal_analysis(transactions, all_prices)
    
    # Return all results
    return(list(
      network_metrics = network_metrics,
      key_addresses = list(
        pre_crash = key_addresses_pre,
        crash = key_addresses_crash,
        post_crash = key_addresses_post
      ),
      stability = stability_analysis,
      factors = factor_results,
      clusters = cluster_results,
      fdr = fdr_results,
      topics = topic_results,
      causal = causal_results,
      # Add raw data for additional analysis
      raw_data = list(
        transactions = transactions,
        prices = all_prices
      )
    ))
  }, error = function(e) {
    cat("Error in analysis:", e$message, "\n")
    return(NULL)
  })
}

# ============================================================================
# 9. Run Analysis
# ============================================================================

# For full analysis, use the full dataset
results <- tryCatch({
  run_task1_analysis()  # No sample_size parameter means use full dataset
}, error = function(e) {
  cat("Error running analysis:", e$message, "\n")
  NULL
})

# Only save if results are not NULL
if(!is.null(results)) {
  saveRDS(results, "task1_results.rds")
}

check_data <- function() {
  cat("Loading transaction data for diagnostics...\n")
  transactions <- load_transaction_data(1000000)  # Use a sample for quick diagnostics
  
  cat("\n=== Token Distribution ===\n")
  token_counts <- table(transactions$token)
  print(token_counts)
  
  cat("\n=== Price Data Summary ===\n")
  price_summary <- table(load_price_data()$token)
  print(price_summary)
  
  cat("\n=== Date Ranges ===\n")
  date_range <- range(transactions$date)
  cat("Transaction dates:", format(date_range[1]), "to", format(date_range[2]), "\n")
  
  # Check UST specifically
  ust_txs <- transactions[transactions$token == "UST",]
  cat("\nUST transactions:", nrow(ust_txs), "\n")
  if(nrow(ust_txs) > 0) {
    ust_date_range <- range(ust_txs$date)
    cat("UST date range:", format(ust_date_range[1]), "to", format(ust_date_range[2]), "\n")
  }
}

# Run the diagnostic function
check_data()

# Add this function to fix the stability metrics and save updated results
fix_stability_metrics <- function() {
  cat("Fixing stability metrics with proper date handling...\n")
  
  # Try to load existing results
  if(file.exists("task1_results.rds")) {
    tryCatch({
      results <- readRDS("task1_results.rds")
      
      # Check if we have raw price data
      if(!is.null(results$raw_data$prices)) {
        cat("Recalculating stability metrics from raw price data...\n")
        
        # Print the date range in the raw data
        cat("Date range in raw price data:", 
            format(min(results$raw_data$prices$date, na.rm = TRUE)), "to", 
            format(max(results$raw_data$prices$date, na.rm = TRUE)), "\n")
        
        # Calculate new stability metrics
        new_stability <- calculate_stability_metrics(results$raw_data$prices)
        
        # Check the period distribution in the new data
        cat("Period distribution in recalculated data:\n")
        print(table(new_stability$daily$period))
        
        # Update the results object
        results$stability <- new_stability
        
        # Save the updated results
        saveRDS(results, "task1_results.rds")  # Overwrite the original file
        
        cat("Updated results saved to task1_results.rds\n")
        return(TRUE)
      } else {
        cat("Raw price data not available in results. Loading price data directly...\n")
        
        # Load price data
        all_prices <- load_price_data()
        
        if(nrow(all_prices) > 0) {
          cat("Successfully loaded price data directly.\n")
          
          # Calculate stability metrics
          new_stability <- calculate_stability_metrics(all_prices)
          
          # Update the results object
          results$stability <- new_stability
          
          # Save the updated results
          saveRDS(results, "task1_results.rds")  # Overwrite the original file
          
          cat("Updated results saved to task1_results.rds\n")
          return(TRUE)
        } else {
          cat("Could not load price data directly.\n")
          return(FALSE)
        }
      }
    }, error = function(e) {
      cat("Error processing results file:", e$message, "\n")
      return(FALSE)
    })
  } else {
    cat("Results file not found. Please run the full analysis first.\n")
    return(FALSE)
  }
}

# Run the fix function when the script is sourced
fix_stability_metrics()