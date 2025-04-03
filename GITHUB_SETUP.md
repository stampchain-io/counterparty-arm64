# GitHub Repository Setup Guide

Follow these steps to initialize and push this project to the StampChain.io GitHub organization.

## Prerequisites

- A GitHub account with access to the StampChain.io organization
- Git installed on your local machine
- The `gh` CLI tool (optional but recommended)

## Important Note About Sensitive Data

This repository uses a `.env` file to store AWS-specific configuration that shouldn't be committed to the repository:

- The `.env.example` file is a template that IS committed to the repository
- Your actual `.env` file is excluded via `.gitignore`
- Before pushing to GitHub, make sure no sensitive data is hardcoded in any files

**NEVER commit any AWS access keys, passwords, or sensitive information to the repository.**

## Step 1: Initialize the Local Repository

```bash
# Navigate to the project directory
cd /path/to/counterparty-arm64

# Initialize a new git repository
git init

# Add all files to the staging area
git add .

# Make the initial commit
git commit -m "Initial commit: Counterparty ARM64 setup project"
```

## Step 2: Create a New Repository on GitHub

### Option 1: Using the GitHub Web Interface

1. Go to https://github.com/stampchain-io
2. Click on "New" to create a new repository
3. Repository name: `counterparty-arm64`
4. Description: "Deploy Counterparty on ARM64 architecture, optimized for AWS Graviton instances"
5. Make it Public or Private according to your preference
6. Do NOT initialize with a README, .gitignore, or license (we already have these files)
7. Click "Create repository"

### Option 2: Using the GitHub CLI

```bash
# Install GitHub CLI if you haven't already
# macOS: brew install gh
# Ubuntu: sudo apt install gh

# Login to GitHub
gh auth login

# Create a repository in the stampchain-io organization
gh repo create stampchain-io/counterparty-arm64 --description "Deploy Counterparty on ARM64 architecture, optimized for AWS Graviton instances" --private
```

## Step 3: Push the Local Repository to GitHub

```bash
# Add the remote repository
git remote add origin https://github.com/stampchain-io/counterparty-arm64.git

# Push the code to the main branch
git push -u origin main
```

> **IMPORTANT**: Before pushing, make sure you've completed testing using the steps in `TESTING.md` to verify everything works correctly!

## Step 4: Configure Branch Protection (Optional)

1. Go to the repository settings on GitHub
2. Navigate to "Branches"
3. Add a branch protection rule for `main`
4. Enable options like "Require pull request reviews before merging" 
   and "Require status checks to pass before merging"

## Step 5: Set Up GitHub Actions (Optional)

You can add GitHub Actions workflows to:
- Validate CloudFormation templates
- Run linting on shell scripts
- Test Docker builds

To do this, create a `.github/workflows` directory and add workflow files there.

## Additional Notes

- Update the README.md with the correct GitHub repository URL once created
- Consider setting up GitHub Pages for the documentation
- Add collaborators as needed in the repository settings