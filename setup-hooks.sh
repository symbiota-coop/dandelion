#!/bin/bash

# Setup script for git hooks
# This script creates symlinks from .git/hooks to the version-controlled hooks in git-hooks/

# Get the absolute path of the repository root
REPO_ROOT=$(git rev-parse --show-toplevel)

# Create symlinks for all hooks in the git-hooks directory
for hook in "$REPO_ROOT/git-hooks"/*; do
  # Get the hook name (basename)
  hook_name=$(basename "$hook")
  
  # Create the symlink
  ln -sf "$hook" "$REPO_ROOT/.git/hooks/$hook_name"
  
  # Make the hook executable
  chmod +x "$REPO_ROOT/.git/hooks/$hook_name"
  
  echo "✅ $hook_name hook installed"
done

echo "🎉 All git hooks have been installed!" 