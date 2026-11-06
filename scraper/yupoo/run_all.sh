#!/bin/bash
# Superviseur : enchaîne tous les stores Yupoo, en boucle, jusqu'à stabilité.
# Chaque store est réessayé ; si un run plante (timeout réseau), la boucle
# suivante reprend où il s'était arrêté (scraper incrémental).
PY=/home/nou72025/.venvs/yupoo/bin/python
DIR=/home/nou72025/tchipa-app/scraper/yupoo
cd "$DIR"

STORES=(
  "https://oraclothing.x.yupoo.com/categories/5254178|--category Homme"
  "https://cutykids.x.yupoo.com/albums|--category Enfants"
  "https://pandavault.x.yupoo.com/albums|--category Boutique"
  "https://samluxuryfactory.x.yupoo.com/albums|--category Luxe"
  "https://tianjin-no1.x.yupoo.com/albums|--category Replicas"
  "https://tmf001.x.yupoo.com/albums|--category Replicas"
  "https://repsmaster.x.yupoo.com/albums|--category Replicas"
)

# résume oraclothing en tuant l'instance précédente si elle traîne
pkill -f "yupoo_scraper.py" 2>/dev/null; sleep 1

for round in 1 2 3; do
  echo "===== ROUND $round $(date) ====="
  for entry in "${STORES[@]}"; do
    url="${entry%%|*}"; extra="${entry#*|}"
    store=$(echo "$url" | sed 's|https://\([^.]*\)\..*|\1|')
    echo "--- $store $(date +%H:%M:%S) ---"
    $PY yupoo_scraper.py "$url" --out ./yupoo_data $extra >> "scrape_${store}.log" 2>&1
    rc=$?
    echo "store $store rc=$rc $(date +%H:%M:%S)"
    sleep 5
  done
done
echo "===== TERMINÉ $(date) ====="
