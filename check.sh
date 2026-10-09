#!/bin/bash
# Repo self-check: syntax, placeholder guards, plist lint, shellcheck. Exit 0 only if every check passes.
# Usage: ./check.sh      (needs bash, python3; plutil and shellcheck are used when present)
cd "$(dirname "$0")" || exit 1
fail=0; ok(){ echo "ok    $*"; }; bad(){ echo "FAIL  $*"; fail=1; }
for f in templates/*.sh; do bash -n "$f" && ok "syntax $f" || bad "syntax $f"; done
python3 -c "import ast,sys; ast.parse(open('templates/spend.py').read())" && ok "syntax templates/spend.py" || bad "syntax templates/spend.py"
# Every placeholder guard must refuse (exit 1) while the placeholders are unfilled. These never reach gcloud.
guard(){ out=$("$@" 2>&1); rc=$?; [ $rc -eq 1 ] && grep -q "fill the placeholders" <<< "$out" && ok "guard $*" || bad "guard $* (rc=$rc)"; }
guard bash templates/run_tier.sh 0 1
guard bash templates/relaunch.sh templates/job.env.example
guard python3 templates/spend.py
if command -v plutil >/dev/null; then
  for p in templates/*.plist; do plutil -lint -s "$p" && ok "plist $p" || bad "plist $p"; done
else echo "skip  plist lint (no plutil)"; fi
if command -v shellcheck >/dev/null; then
  shellcheck -S warning templates/*.sh check.sh && ok "shellcheck (warning and above)" || bad "shellcheck"
else echo "skip  shellcheck (not installed)"; fi
[ $fail -eq 0 ] && echo "all checks passed" || echo "some checks failed"
exit $fail
