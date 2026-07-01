#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"
rm -rf .build dist
echo "Removed Swift build artifacts and packaged app outputs from $ROOT_DIR"
