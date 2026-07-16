#!/bin/bash
set -euo pipefail

MODEL_DIR="Resources/models"
MODEL_FILE="ggml-small.en.bin"
MODEL_PATH="${MODEL_DIR}/${MODEL_FILE}"
MODEL_REVISION="5359861c739e955e79d9a303bcbc70fb988958b1"
MODEL_SHA256="c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/${MODEL_REVISION}/${MODEL_FILE}"

verify_model() {
    local path="$1"
    local actual
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [ "$actual" = "$MODEL_SHA256" ]
}

if [ -f "${MODEL_PATH}" ]; then
    if verify_model "${MODEL_PATH}"; then
        echo "Model already exists at ${MODEL_PATH}"
        exit 0
    fi
    echo "Existing model failed checksum; replacing it."
    rm -f "${MODEL_PATH}"
fi

mkdir -p "${MODEL_DIR}"
echo "Downloading ${MODEL_FILE} (~466 MB)..."
TMP_MODEL="$(mktemp "${MODEL_PATH}.XXXXXX")"
trap 'rm -f "${TMP_MODEL}"' EXIT
curl -L --progress-bar -o "${TMP_MODEL}" "${MODEL_URL}"
if ! verify_model "${TMP_MODEL}"; then
    echo "ERROR: Downloaded model checksum did not match expected SHA-256." >&2
    exit 1
fi
mv "${TMP_MODEL}" "${MODEL_PATH}"
trap - EXIT
echo "Done. Model saved to ${MODEL_PATH}"
