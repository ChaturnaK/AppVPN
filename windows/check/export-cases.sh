#!/bin/sh
# Writes every case of test-cases.sh as <n>.ovpn plus <n>.expect (allowed|refused, name, text the error must
# contain) into the folder given, for windows/check to run. Usage: export-cases.sh <folder>
set -eu
out=$1
mkdir -p "$out"
n=0
allowed() { n=$((n + 1)); printf %b "$pre$base$2" > "$out/$n.ovpn"; printf 'allowed\n%s\n' "$1" > "$out/$n.expect"; }
refused() { n=$((n + 1)); printf %b "$base$2" > "$out/$n.ovpn"; printf 'refused\n%s\n%s\n' "$1" "$3" > "$out/$n.expect"; }
cd "$(dirname "$0")/../.."
. ./test-cases.sh
