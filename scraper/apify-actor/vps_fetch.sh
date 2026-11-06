#!/usr/bin/env bash
# vps_fetch.sh — à exécuter SUR LE VPS pour télécharger tout le catalogue Yupoo
# depuis les datasets Apify (métadonnées déjà scrapées, stockées dans le cloud).
#
# Prérequis : node >= 18, apify-client, et le token dans APIFY_TOKEN (ou .env)
#
# Usage:
#   bash vps_fetch.sh                 # tout télécharger (tous les stores)
#   bash vps_fetch.sh --only-missing  # reprendre là où c'était arrêté
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

if [ ! -f .env ]; then
    echo "Fichier .env manquant — crée-le avec: echo 'APIFY_TOKEN=...' > .env"
    exit 1
fi

# datasets des runs terminés (10 = 1 test + 7 stores + tmf001/repsmaster)
declare -A RUNS=(
    [tianjin-no1]=WoxpYJl8urX3crRO8
    [cutykids]=zb1l0LT3c1Gjwf9vy
    [samluxuryfactory]=rKH6Z84ZQHhmcgANl
    [pandavault]=EI1HgNRYHMCkMlEtB
    [oraclothing]=HJ0bZE6xgXOkGmoPb
    [repsmaster]=JAm110VYghgm2dqFy
    [tmf001]=EOgE0bKJBBbgt7dUe
)

for store in "${!RUNS[@]}"; do
    echo "=== $store (run ${RUNS[$store]}) ==="
    node fetch_images.js "${RUNS[$store]}" ${1:+$1} || echo "!! échec $store — continuer"
done

echo "=== TOUT TÉLÉCHARGÉ ==="
for f in ~/tchipa-app/scraper/yupoo/yupoo_data/*/catalogue.csv; do
    echo "$(basename $(dirname $f)): $(($(wc -l < "$f") - 1)) produits"
done
