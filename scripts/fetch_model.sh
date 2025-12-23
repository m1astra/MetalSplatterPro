#!/bin/bash
set -euo pipefail

MODEL_ZIP_URL="https://github.com/m1astra/MetalSplatterPro/releases/download/model-v1/sharp_model_dist.zip"
MODEL_ZIP_SHA256="8f9f94ccc483ae6c93d12aa038d95b9943996607e9bf6d6bd1737ccc390753a4"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENE_DIR="${REPO_ROOT}/SampleApp/Scene"
MODEL_DIR="${SCENE_DIR}/sharp.mlmodelc"
MARKER="${MODEL_DIR}/metadata.json"

CACHE_DIR="${REPO_ROOT}/.model-cache"
ZIP_PATH="${CACHE_DIR}/sharp_model_dist.zip"
UNZIP_DIR="${CACHE_DIR}/unzip"

if [ -f "${MARKER}" ]; then
  echo "Model already present: ${MODEL_DIR}"
  exit 0
fi

if [ "${MODEL_ZIP_URL}" = "__MODEL_ZIP_URL__" ] || [ "${MODEL_ZIP_SHA256}" = "__MODEL_ZIP_SHA256__" ]; then
  echo "ERROR: scripts/fetch_model.sh is not configured."
  echo "Set MODEL_ZIP_URL + MODEL_ZIP_SHA256."
  exit 2
fi

mkdir -p "${CACHE_DIR}"

echo "Downloading model (~1.26GB)..."
/usr/bin/curl -L --fail --retry 3 --retry-delay 2 -o "${ZIP_PATH}" "${MODEL_ZIP_URL}"

echo "Verifying sha256..."
echo "${MODEL_ZIP_SHA256}  ${ZIP_PATH}" | /usr/bin/shasum -a 256 -c -

rm -rf "${UNZIP_DIR}"
mkdir -p "${UNZIP_DIR}"
/usr/bin/ditto -x -k "${ZIP_PATH}" "${UNZIP_DIR}"

# Expected structure inside zip:
#   ModelDist/
#     sharp.mlmodelc/
#     LICENSE_MODEL
#     MODEL_ATTRIBUTION.txt
#     MODEL_DERIVATIVE_NOTES.md
SRC_MODEL_DIR="${UNZIP_DIR}/ModelDist/sharp.mlmodelc"

if [ ! -f "${SRC_MODEL_DIR}/metadata.json" ]; then
  echo "ERROR: Expected model not found at: ${SRC_MODEL_DIR}"
  exit 3
fi

rm -rf "${MODEL_DIR}"
/usr/bin/ditto "${SRC_MODEL_DIR}" "${MODEL_DIR}"

if [ ! -f "${MARKER}" ]; then
  echo "ERROR: Install failed; expected: ${MARKER}"
  exit 4
fi

echo "Installed model: ${MODEL_DIR}"

