#!/usr/bin/env bash
# Static validation of this repository. Run it from the repository root: it
# detects which artifact types are present and runs the right validator for
# each (bash -n, shellcheck, kubeconform, terraform, helm).
# Exits non-zero if any validation fails.
set -uo pipefail

FAILURES=0
fail()  { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }
ok()    { echo "  [ok] $1"; }
skip()  { echo "  [skipped] $1 (missing tool: install with 'brew install $2')"; }
run()   { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }

echo "== validate.sh — $(date '+%Y-%m-%d %H:%M') =="

# --- Shell scripts ---
while IFS= read -r s; do
  [ -n "$s" ] || continue
  run "bash -n $s" bash -n "$s"
  if command -v shellcheck >/dev/null; then
    run "shellcheck $s" shellcheck "$s"
  else skip "shellcheck $s" shellcheck; fi
done < <(find . -name '*.sh' -not -path './.terraform/*' | sort)

# --- Terraform ---
if find . -name '*.tf' -not -path './.terraform/*' | grep -q .; then
  if command -v terraform >/dev/null; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      if (cd "$d" \
        && terraform fmt -check >/dev/null \
        && terraform init -backend=false -input=false >/dev/null \
        && terraform validate >/dev/null); then
        ok "terraform fmt+init+validate in $d"
      else fail "terraform in $d"; fi
    done < <(find . -name '*.tf' -not -path './.terraform/*' -exec dirname {} \; | sort -u)
  else skip "terraform" terraform; fi
fi

# --- Kubernetes YAML ---
k8s_files=()
while IFS= read -r f; do k8s_files+=("$f"); done \
  < <(grep -rlE '^(apiVersion|kind):' --include='*.yaml' --include='*.yml' . 2>/dev/null | sort)
if [ "${#k8s_files[@]}" -gt 0 ]; then
  if command -v kubeconform >/dev/null; then
    # -ignore-missing-schemas: third-party CRDs (Karpenter etc.) validate fields against official docs
    run "kubeconform (${#k8s_files[@]} files)" \
      kubeconform -strict -summary -ignore-missing-schemas "${k8s_files[@]}"
  else skip "kubeconform" kubeconform; fi
fi

# --- Helm ---
while IFS= read -r chart; do
  [ -n "$chart" ] || continue
  if command -v helm >/dev/null; then
    run "helm lint $chart" helm lint "$chart"
    run "helm template $chart" helm template "$chart"
  else skip "helm $chart" helm; fi
done < <(find . -name Chart.yaml -exec dirname {} \; | sort)

# --- Repository-specific checks ---
# Every InferencePool states its failureMode; the checker first proves it
# catches the bad cases (missing, misspelled, misplaced) on fixtures.
run "check-failure-mode --self-test" bash tools/check-failure-mode.sh --self-test
run "every InferencePool sets spec.endpointPickerRef.failureMode" bash tools/check-failure-mode.sh
# Alert rules: promtool check + unit tests + mutation checks.
if [ -x bin/promtool ] || command -v promtool >/dev/null; then
  run "alert rules (promtool check, unit tests, mutations)" bash tools/test-alerts.sh
else
  echo "  [skipped] alert rules (missing tool: install with 'bash tools/install-cli.sh promtool')"
fi

echo "== result: $FAILURES failure(s) =="
[ "$FAILURES" -eq 0 ]
