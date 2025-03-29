# Stablecoin Stability Analysis: Terra/Luna Crash Case Study

## Overview

This repository contains a comprehensive analysis of stablecoin behavior during the Terra/Luna collapse of May 2022. The project examines how different stablecoin designs (algorithmic vs. collateralized) respond to extreme market stress by analyzing over 70 million transactions and daily price data across five major stablecoins (USDT, USDC, DAI, USTC, PAX).

## Key Findings

- **Binary Stability Pattern**: Stablecoin stability operates as a binary state rather than a spectrum, with algorithmic USTC exhibiting a "cliff edge" collapse pattern with minimal warning signs
- **Stability Paradox**: The most stable tokens (like USDC) were statistically least predictable due to their minimal, seemingly random deviations
- **Limited Contagion**: Despite USTC's catastrophic failure, other stablecoins showed remarkable resilience with minimal spillover effects
- **Design Implications**: Collateralized designs demonstrated superior stability compared to algorithmic mechanisms

## Methodology

This project employs a multi-model analytical framework with four complementary approaches:

1. **Decision Trees**: Identify threshold values and interpretable rules characterizing stability classes
2. **Random Forests**: Build high-performance predictive models capturing complex, non-linear relationships
3. **Clustering**: Discover distinct market regimes and stablecoin behavior patterns
4. **LASSO/Ridge Regression**: Perform feature selection while handling multicollinearity among predictors

## Research Questions

The analysis addresses five interconnected questions:

1. How do different stablecoins maintain their pegs during normal and stressed conditions?
2. What is the relationship between transaction network structure and stablecoin stability?
3. Can we develop effective early warning systems for stability issues?
4. What can we learn from a detailed case study of the USTC collapse?
5. What broader market behavior patterns emerge during stability events?

## Data

The dataset includes:
- Over 70 million ERC20 transactions between Ethereum addresses and smart contracts
- Daily OHLC (open, high, low, close) prices in USD for each token
- Event data with timestamps and descriptions of significant events
- Derived stability metrics (peg deviations, volatility measurements, trading volumes)
- Network metrics (density, reciprocity, modularity, centralization)

## Repository Structure

- `data/`: Raw and processed data files
- `scripts/`: R scripts for data processing and analysis
- `analysis.rmd`: Main R Markdown file containing the analysis
- `visualizations/`: Generated plots and visualizations
- `results/`: Output files from the analysis

## Key Visualizations

- Stability regime classifications across stablecoins
- Decision tree visualizations for stability prediction
- Network metrics over time
- Clustering results showing market regimes
- USTC collapse phase analysis

## Requirements

- R 4.0+
- Required packages: tidyverse, data.table, igraph, lubridate, ggplot2, factoextra, gridExtra, viridis, corrplot, rpart, rpart.plot, randomForest, glmnet

## Usage

1. Clone the repository
2. Install required R packages
3. Run the analysis.rmd file to reproduce the analysis

## Implications

This research has significant implications for:
- Stablecoin design (favoring robust external backing over purely algorithmic mechanisms)
- Monitoring systems (focusing on critical thresholds rather than gradual changes)
- Regulatory frameworks (distinguishing between algorithmic and collateralized stablecoins)
- Early warning systems (requiring sophisticated approaches beyond traditional metrics)

## License

[MIT License](LICENSE)

## Acknowledgements

Original dataset provided by researchers from University of Manitoba and University of Texas at Dallas.