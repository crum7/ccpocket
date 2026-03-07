#!/usr/bin/env bash
# daily-metrics.sh - Fetch daily metrics and post to Discord
#
# Required env:
#   DISCORD_WEBHOOK_URL - Discord webhook URL
#
# Optional env:
#   DRY_RUN=1 - Print payload without posting

set -euo pipefail

REPO="K9i-0/ccpocket"
NPM_PACKAGE="@ccpocket/bridge"
TODAY=$(date -u +"%Y-%m-%d")

# ── npm downloads (yesterday) ─────────────────────────────────
npm_response=$(curl -sf "https://api.npmjs.org/downloads/point/last-day/${NPM_PACKAGE}" || echo '{}')
npm_downloads=$(echo "$npm_response" | jq -r '.downloads // 0')

# ── GitHub stats ──────────────────────────────────────────────
gh_response=$(curl -sf "https://api.github.com/repos/${REPO}" || echo '{}')
gh_stars=$(echo "$gh_response" | jq -r '.stargazers_count // 0')
gh_forks=$(echo "$gh_response" | jq -r '.forks_count // 0')
gh_open_issues=$(echo "$gh_response" | jq -r '.open_issues_count // 0')

# ── Open PRs (open_issues_count includes PRs, so fetch PR count separately) ──
gh_prs_response=$(curl -sf "https://api.github.com/repos/${REPO}/pulls?state=open&per_page=1" \
  -I 2>/dev/null | grep -i '^link:' || echo '')
# Simple approach: just count open PRs via search API
gh_prs_count=$(curl -sf "https://api.github.com/search/issues?q=repo:${REPO}+type:pr+state:open" \
  | jq -r '.total_count // 0' || echo '0')
gh_issues_count=$((gh_open_issues - gh_prs_count))

# ── Latest release download count ────────────────────────────
release_response=$(curl -sf "https://api.github.com/repos/${REPO}/releases?per_page=5" || echo '[]')
latest_release=$(echo "$release_response" | jq -r '.[0].tag_name // "none"')
latest_release_downloads=$(echo "$release_response" | jq '[.[0].assets[]?.download_count // 0] | add // 0')

# ── Build Discord Embed ──────────────────────────────────────
description=$(cat <<EOF
📦 **npm** (\`${NPM_PACKAGE}\`): **${npm_downloads}** downloads (yesterday)
⭐ **GitHub**: **${gh_stars}** stars / **${gh_forks}** forks
🔧 **Open Issues**: ${gh_issues_count} / **Open PRs**: ${gh_prs_count}
🏷️ **Latest Release**: \`${latest_release}\` (${latest_release_downloads} asset downloads)
EOF
)

payload=$(jq -n \
  --arg title "📊 ccpocket Daily Report (${TODAY})" \
  --arg description "$description" \
  --argjson color 5814783 \
  '{
    embeds: [{
      title: $title,
      description: $description,
      color: $color,
      footer: { text: "ccpocket metrics bot" },
      timestamp: (now | todate)
    }]
  }')

# ── Post or dry-run ──────────────────────────────────────────
if [[ "${DRY_RUN:-}" == "1" ]]; then
  echo "=== DRY RUN ==="
  echo "$payload" | jq .
  exit 0
fi

if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
  echo "Error: DISCORD_WEBHOOK_URL is not set" >&2
  exit 1
fi

http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d "$payload" \
  "$DISCORD_WEBHOOK_URL")

if [[ "$http_code" =~ ^2 ]]; then
  echo "✅ Posted daily metrics to Discord (HTTP ${http_code})"
else
  echo "❌ Failed to post to Discord (HTTP ${http_code})" >&2
  exit 1
fi
