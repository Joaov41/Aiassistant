#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/Aiassistant"
PYTHON_BIN="${PYTHON_BIN:-/opt/homebrew/bin/python3.12}"
LM_VENV="$APP_SUPPORT/mlx-venv"
VLM_VENV="$APP_SUPPORT/mlx-vlm-venv"

if [[ ! -x "$PYTHON_BIN" ]]; then
  cat >&2 <<EOF
Python 3.12 was not found at:
  $PYTHON_BIN

Install it with Homebrew:
  brew install python@3.12

Or rerun with PYTHON_BIN=/path/to/python3.12.
EOF
  exit 1
fi

mkdir -p "$APP_SUPPORT"

create_venv() {
  local venv="$1"
  rm -rf "$venv"
  "$PYTHON_BIN" -m venv "$venv"
  "$venv/bin/python" -m pip install -U pip setuptools wheel
}

echo "Creating MLX text runtime at $LM_VENV"
create_venv "$LM_VENV"
"$LM_VENV/bin/python" -m pip install --force-reinstall \
  "mlx-lm==0.31.2" \
  "mlx==0.31.1" \
  "transformers==5.12.1" \
  "huggingface-hub==1.19.0"

echo "Creating MLX vision runtime at $VLM_VENV"
create_venv "$VLM_VENV"
"$VLM_VENV/bin/python" -m pip install --force-reinstall \
  "mlx-vlm==0.6.3" \
  "mlx-lm==0.31.3" \
  "mlx==0.31.2" \
  "transformers==5.12.1"

echo
echo "Installed MLX runtime:"
"$LM_VENV/bin/python" -m pip show mlx-lm mlx transformers huggingface-hub | grep -E 'Name:|Version:'
echo
"$VLM_VENV/bin/python" -m pip show mlx-vlm mlx-lm mlx transformers | grep -E 'Name:|Version:'
echo
echo "Text server:   $LM_VENV/bin/mlx_lm.server"
echo "Vision server: $VLM_VENV/bin/mlx_vlm.server"
