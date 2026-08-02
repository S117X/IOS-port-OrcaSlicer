#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/local/bin:$PATH"
cd "$(dirname "$0")/.."
git remote remove origin 2>/dev/null || true
git remote add origin git@github.com:S117X/OrcaSlicer.git
git remote -v
echo "Pushing ios-port → git@github.com:S117X/OrcaSlicer.git"
git push -u origin ios-port
echo "Done: https://github.com/S117X/OrcaSlicer/tree/ios-port"
