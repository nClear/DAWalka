#!/usr/bin/env bash
# Setup helper for the DAWalka Python backend.
#
# Creates a virtual environment and installs the inference dependencies
# for the pure-MLX Stable Audio 3 backend.  Run from inside the
# `python_backend/` directory:
#
#     ./setup.sh
#
# On Apple Silicon it also installs MLX (Metal acceleration).  No
# PyTorch is needed at runtime.
set -euo pipefail

cd "$(dirname "$0")"

VENV="${VENV:-./venv}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

echo "Creating virtualenv at $VENV using $PYTHON_BIN"
$PYTHON_BIN -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"

echo "Upgrading pip / wheel"
pip install --upgrade pip wheel 2>&1 | tail -3

echo "Installing base requirements"
pip install -r requirements.txt 2>&1 | tail -5

# Apple Silicon -> MLX
if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
    echo "Apple Silicon detected - installing MLX"
    if pip install "mlx" 2>&1 | tee /tmp/mlx-install.log | tail -8; then
        # verify
        if "$VENV/bin/python3" -c "import mlx.core" 2>/dev/null; then
            echo "mlx import OK"
        else
            echo "mlx install completed but import FAILED; reinstalling verbose"
            pip install --force-reinstall "mlx" 2>&1 | tail -20
        fi
    else
        echo "   (mlx install failed; inference requires Apple Silicon)"
        tail -30 /tmp/mlx-install.log
        exit 1
    fi
else
    echo "WARNING: this backend requires Apple Silicon (MLX).  No MLX installed."
fi

echo
echo "DAWalka backend environment ready."
echo "  Activate with: source $VENV/bin/activate"
echo "  Run with:      $VENV/bin/python3 server.py --models \"$HOME/Library/Application Support/DAWalka/models\""
