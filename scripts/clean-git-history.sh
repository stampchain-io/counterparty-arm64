#!/bin/bash
# clean-git-history.sh - Script to remove sensitive information from git history

set -e

echo "WARNING: This script will rewrite git history."
echo "It should be run BEFORE pushing to a public repository."
echo "If you have already pushed to a public repository, all collaborators will need to clone a fresh copy."
echo ""
echo "Backup your repository before proceeding."
echo ""
read -p "Do you want to continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation canceled."
    exit 1
fi

# Create a backup of the current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_BRANCH="backup-before-cleaning-$TIMESTAMP"

echo "Creating backup branch: $BACKUP_BRANCH"
git branch $BACKUP_BRANCH

# Install BFG Repo-Cleaner if not present
if ! command -v bfg &> /dev/null; then
    echo "BFG Repo-Cleaner is required. Please install it first:"
    echo "Follow instructions at: https://rtyley.github.io/bfg-repo-cleaner/"
    exit 1
fi

# Create a text file with patterns to replace
cat > sensitive-patterns.txt << EOF
/Users/
/home/
~/.ssh/
*.pem
EOF

# Use BFG to remove sensitive data
echo "Removing sensitive data from git history..."
bfg --replace-text sensitive-patterns.txt

# Clean up and force garbage collection
echo "Cleaning up repository..."
git reflog expire --expire=now --all
git gc --prune=now --aggressive

echo ""
echo "Git history has been cleaned."
echo "Backup branch created: $BACKUP_BRANCH"
echo ""
echo "Next steps:"
echo "1. Verify your repository still works correctly"
echo "2. If everything looks good, you can push with 'git push origin $CURRENT_BRANCH --force'"
echo "3. To delete the backup branch later: 'git branch -D $BACKUP_BRANCH'"
echo ""
echo "IMPORTANT: If you've already shared this repository, inform all collaborators"
echo "that they need to clone a fresh copy after your force push."