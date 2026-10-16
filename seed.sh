#!/usr/bin/env bash
# Writes the scenario of the live demo into the demo project of a Kollaudo: a made-up shop with
# three components in three environments, where each cell shows one thing a verdict can say.
#
#   ./seed.sh            the whole scenario: the policy, deployments, test runs and the override
#   ./seed.sh override   only the override, which lasts at most 24 hours and is renewed every day
#
# Needs KOLLAUDO_URL, and the tokens of the demo project: DEMO_INGEST_TOKEN, DEMO_POLICY_TOKEN,
# DEMO_OVERRIDE_TOKEN and DEMO_GATE_TOKEN, a read token named after the gate, such as kargo. Each one
# can only touch that project.
set -euo pipefail
cd "$(dirname "$0")"

: "${KOLLAUDO_URL:?Set KOLLAUDO_URL to the URL of the Kollaudo of the demo.}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# The CLI of the same release as the server. KOLLAUDO_CLI runs another one, such as a local build.
kollaudo() {
  if [[ -n ${KOLLAUDO_CLI:-} ]]; then node "$KOLLAUDO_CLI" "$@"; else npx --yes "@kollaudo/cli@${KOLLAUDO_CLI_VERSION:-0.4.0}" "$@"; fi
}
as() { local token=$1; shift; KOLLAUDO_TOKEN=$token kollaudo "$@"; }

# Writes a CTRF report from lines on stdin, "<status> <name>", and prints its path. A status of
# "flaky" is a test that passed after a retry.
report() {
  local file tool=$1 tests="" count=0 status name extra
  file=$(mktemp "$OUT/report-XXXX.json")
  while read -r status name; do
    extra=""
    case $status in
      flaky) status=passed extra=', "retries": 1, "flaky": true' ;;
      failed) extra=', "retries": 1, "message": "Error: expect(received).toBe(expected)"' ;;
    esac
    tests+="${tests:+,}{\"name\": \"$name\", \"status\": \"$status\", \"duration\": $((800 + RANDOM % 4000))$extra}"
    count=$((count + 1))
  done
  printf '{"reportFormat": "CTRF", "specVersion": "0.0.0", "results": {"tool": {"name": "%s"}, "summary": {"tests": %d}, "tests": [%s]}}\n' \
    "$tool" "$count" "$tests" >"$file"
  echo "$file"
}

push() { as "$DEMO_INGEST_TOKEN" push "$@"; }
deployed() { as "$DEMO_INGEST_TOKEN" deployed --tool argocd "$@"; }
# The gate before production asks for the verdict in staging, as Kargo would. Its answer is recorded:
# a deployment to production without a pass given there first is ungated.
gate() { as "$DEMO_GATE_TOKEN" verdict --env staging "$@" >/dev/null || true; }

e2e_checkout() {
  report playwright <<EOF
passed adds a product to the cart
passed applies a discount code
passed changes the quantity in the cart
${1:-passed} pays with a credit card
passed pays with a saved card
passed shows the order summary
EOF
}
e2e_billing() {
  report playwright <<EOF
passed creates an invoice for an order
flaky sends the invoice by email
passed refunds an order
${1:-passed} runs the fraud check on a large order
passed exports the invoices of a month
EOF
}
e2e_search() {
  report playwright <<'EOF'
passed finds a product by name
passed suggests products while typing
passed filters by price
skipped filters by colour
EOF
}
smoke() {
  report k6 <<'EOF'
passed answers the health check
passed serves the home page
passed answers within 300 ms
EOF
}

override() {
  # Billing b7e21c4 goes to production although one of its e2e tests failed in staging: the fraud
  # check calls a payment sandbox that was down. The verdict passes, and says by whom and why.
  as "$DEMO_OVERRIDE_TOKEN" override --component billing --env staging --version b7e21c4 --for 24h \
    --reason "Fraud check test needs the card network sandbox, down since this morning. Checked by hand."
}

if [[ ${1:-} == override ]]; then
  override
  exit
fi

echo "## The rules"
as "$DEMO_POLICY_TOKEN" policy push policy.yaml

echo "## dev: everything passes"
for c in checkout:9d07e6b billing:b7e21c4 search:5c3a9f8; do
  deployed --component "${c%:*}" --env dev --version "${c#*:}"
done
push "$(e2e_checkout)" --component checkout --env dev --version 9d07e6b
push "$(e2e_billing)" --component billing --env dev --version b7e21c4
push "$(e2e_search)" --component search --env dev --version 5c3a9f8

echo "## search: 41d8e07 passed staging, then went to production"
deployed --component search --env staging --version 41d8e07
push "$(e2e_search)" --component search --env staging --version 41d8e07
push "$(smoke)" --component search --env staging --version 41d8e07 --kind smoke
gate --component search --version 41d8e07
deployed --component search --env production --version 41d8e07
push "$(smoke)" --component search --env production --version 41d8e07 --kind smoke

echo "## search: 5c3a9f8 is unknown in staging, its smoke tests never ran"
deployed --component search --env staging --version 5c3a9f8
push "$(e2e_search)" --component search --env staging --version 5c3a9f8

echo "## checkout: 9d07e6b fails in staging, and was deployed to production by hand anyway: ungated"
deployed --component checkout --env staging --version 9d07e6b
push "$(e2e_checkout failed)" --component checkout --env staging --version 9d07e6b
gate --component checkout --version 9d07e6b
as "$DEMO_INGEST_TOKEN" deployed --component checkout --env production --version 9d07e6b --tool kubectl
push "$(smoke)" --component checkout --env production --version 9d07e6b --kind smoke

echo "## billing: b7e21c4 failed in staging, passes through an override, then goes to production"
deployed --component billing --env staging --version b7e21c4
push "$(e2e_billing failed)" --component billing --env staging --version b7e21c4
push "$(smoke)" --component billing --env staging --version b7e21c4 --kind smoke
override
gate --component billing --version b7e21c4
deployed --component billing --env production --version b7e21c4
push "$(smoke)" --component billing --env production --version b7e21c4 --kind smoke

echo "The demo is ready."
