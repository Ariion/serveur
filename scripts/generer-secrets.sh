#!/usr/bin/env bash
# Génère les 3 secrets cryptographiques requis par LobeChat en mode serveur.
#
#   ./scripts/generer-secrets.sh
#
# Chaque valeur est à coller telle quelle dans Vercel > Settings > Environment
# Variables. Ne les commite JAMAIS dans git, ne les envoie par aucun canal.
# Ne les régénère pas après le premier déploiement : changer KEY_VAULTS_SECRET
# rend illisibles les clés API déjà chiffrées en base, changer AUTH_SECRET
# déconnecte toutes les sessions.
set -euo pipefail

command -v node >/dev/null || { echo "node est requis" >&2; exit 1; }

echo "# ---- À coller dans Vercel (Production + Preview + Development) ----"
echo
echo "AUTH_SECRET=$(node -e 'console.log(require("node:crypto").randomBytes(32).toString("base64"))')"
echo
echo "KEY_VAULTS_SECRET=$(node -e 'console.log(require("node:crypto").randomBytes(32).toString("base64"))')"
echo
echo "JWKS_KEY=$(node "$(dirname "$0")/generer-jwks.mjs")"
echo
echo "# ------------------------------------------------------------------"
