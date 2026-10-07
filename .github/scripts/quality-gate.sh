#!/usr/bin/env bash
# Quality Gate: lee los reportes de seguridad y falla si hay hallazgos HIGH/CRITICAL.
#
# Uso:  quality-gate.sh <dir-reportes> <herramienta>...
#       herramientas: semgrep | spotbugs | dependency-check | codeql
# NEEDS (opcional): JSON de `needs` del workflow; falla si algun job termino en failure.
#
# Local: bash .github/scripts/quality-gate.sh . semgrep spotbugs dependency-check
set -uo pipefail

dir=$1; shift
fail=0

log() {
  echo "$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "- $1" >> "$GITHUB_STEP_SUMMARY"; fi
}

# Semgrep: severidad ERROR
count_semgrep() { jq '[.results[] | select(.extra.severity == "ERROR")] | length' "$1"; }

# SpotBugs: rank 1-9 ("scariest" y "scary"). El XML usa comillas simples.
count_spotbugs() { grep -oE "<BugInstance[^>]* rank='[1-9]'" "$1" | wc -l; }

# Dependency-Check: severidad HIGH o CRITICAL (CVSS >= 7)
count_dependency_check() {
  jq '[.dependencies[]?.vulnerabilities[]? | select(.severity | ascii_upcase | . == "HIGH" or . == "CRITICAL")] | length' "$1"
}

# CodeQL (SARIF): reglas con security-severity >= 7.0
count_codeql() {
  jq '[.runs[]
       | ([.tool.driver.rules[]?, .tool.extensions[]?.rules[]?]
          | map({(.id): (.properties["security-severity"] // "0" | tonumber)}) | add // {}) as $sev
       | .results[] | select(($sev[.ruleId] // 0) >= 7)] | length' "$1"
}

check() { # check <etiqueta> <patron -path del reporte> <funcion de conteo>
  local label=$1 pattern=$2 counter=$3 f n
  f=$(find "$dir" -path "$pattern" -print -quit)
  if [[ -z "$f" ]]; then
    echo "::error::$label: no se encontro el reporte ($pattern)"
    log "❌ $label: reporte no encontrado"
    fail=1
    return
  fi
  n=$($counter "$f")
  if (( n > 0 )); then
    echo "::error::$label: $n hallazgos criticos en $f"
    log "❌ $label: $n hallazgos criticos"
    fail=1
  else
    log "✅ $label: sin hallazgos criticos"
  fi
}

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "## Quality Gate" >> "$GITHUB_STEP_SUMMARY"; fi

if [[ -n "${NEEDS:-}" ]]; then
  failed=$(jq -r 'to_entries[] | select(.value.result == "failure") | .key' <<<"$NEEDS" | paste -sd, -)
  if [[ -n "$failed" ]]; then
    echo "::error::Jobs fallidos: $failed"
    log "❌ Jobs fallidos: $failed"
    fail=1
  fi
fi

for tool in "$@"; do
  case $tool in
    semgrep)          check Semgrep          '*/semgrep-results.json'         count_semgrep ;;
    spotbugs)         check SpotBugs         '*/spotbugsXml.xml'              count_spotbugs ;;
    dependency-check) check Dependency-Check '*/dependency-check-report.json' count_dependency_check ;;
    codeql)           check CodeQL           '*/codeql-sarif/*.sarif'         count_codeql ;;
    *) echo "::error::Herramienta desconocida: $tool"; fail=1 ;;
  esac
done

if (( fail )); then log "**Quality Gate: FALLIDO**"; else log "**Quality Gate: APROBADO**"; fi
exit $fail
