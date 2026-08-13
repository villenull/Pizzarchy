#!/usr/bin/env bash
# test/unit/test-ci-workflow.sh -- the CI workflow, checked without running it.
#
# T5g owes ".github/workflows/ci.yml builds the ISO on tag and records its
# size" (docs/tasks/T5-iso-and-payload.md §4 and §5). The job that does it
# takes 1-3 hours, ~45 GB of disk and a privileged Docker daemon, so it CANNOT
# be exercised here -- and a workflow nobody can run is exactly where a silent
# mistake survives longest: a typo'd path, an env var the build refuses, a size
# gate whose expression matches nothing and therefore passes everything.
#
# So this suite asks, in seconds, everything that can be asked without running
# it:
#
#   1. it PARSES, with a real YAML parser (never a grep pretending to be one)
#   2. every path and script it names exists in this repo
#   3. its environment matches iso/bin/build's ACTUAL interface -- the vars
#      guard 6.1 refuses, the iso/PKGS-or-OMARCHY_DECK_PKGS_SRC requirement,
#      the submodule bin/build will not build without, the tools its guards
#      hard-fail without
#   4. 🔴 the size gate is EXECUTED. Extracted from the YAML and run against
#      synthetic build logs -- in range, under, over, absent, ambiguous -- so
#      the one part of the job that encodes a judgement is the one part that
#      has been seen to fail. A gate that cannot fail is not a gate.
#   5. the number the gate parses is the number iso/bin/build prints. Both
#      ends are read out of the two files, so changing the format in one
#      without the other goes red here rather than in an hour-long tag build.
#
# 🔴 WHAT THIS SUITE DOES NOT CLAIM. That the job works. Nothing in it has been
# executed by GitHub Actions: not the checkout, not the disk juggling, not
# `iso/bin/build` on a hosted runner. Green here means "authored coherently",
# not "proven". The workflow's own header says the same thing in the same
# words, on purpose.

set -euo pipefail

SUITE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SUITE_DIR/../.." && pwd)
WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
BUILD_SCRIPT="$REPO_ROOT/iso/bin/build"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[[ -f $WORKFLOW ]] || fail ".github/workflows/ci.yml exists" "not found at $WORKFLOW"

# ---------------------------------------------------------------------------
# 1. It parses -- with a parser, not a pattern.
#
# PyYAML if it is importable, else Ruby's stdlib Psych. Both are real YAML
# parsers and one of them is present on this dev machine and on
# ubuntu-latest. If NEITHER is, this suite fails rather than skipping: a
# workflow that was never parsed is precisely the artifact this file exists to
# refuse, and "the parser was missing" is not a reason to report a pass.
# ---------------------------------------------------------------------------

WORKFLOW_JSON="$work/ci.json"
yaml_parser=""
if python3 -c 'import yaml' 2>/dev/null; then
  yaml_parser="python3+PyYAML"
  python3 -c '
import json, sys, yaml
json.dump(yaml.safe_load(open(sys.argv[1])), open(sys.argv[2], "w"))
' "$WORKFLOW" "$WORKFLOW_JSON" ||
    fail "ci.yml parses as YAML (PyYAML)" "see the parser error above"
elif command -v ruby >/dev/null 2>&1 && ruby -ryaml -rjson -e 'exit 0' 2>/dev/null; then
  yaml_parser="ruby+psych"
  ruby -ryaml -rjson -e '
File.write(ARGV[1], YAML.load_file(ARGV[0]).to_json)
' "$WORKFLOW" "$WORKFLOW_JSON" ||
    fail "ci.yml parses as YAML (ruby/psych)" "see the parser error above"
else
  fail "a YAML parser is available" \
    "Neither python3-yaml nor ruby is installed. This suite will not fall back to grepping a workflow file -- install one (both exist on ubuntu-latest, so CI is unaffected)."
fi
pass "ci.yml parses as YAML ($yaml_parser)"

# Flatten it once: a dotted-key dump for cheap assertions, plus every `run:`
# body written out as a file so the size gate can actually be executed.
python3 - "$WORKFLOW_JSON" "$work" <<'PY' || fail "ci.yml has the shape a workflow has" "see the error above"
import json, os, re, sys

doc = json.load(open(sys.argv[1]))
out = sys.argv[2]

# `on:` is YAML 1.1's boolean true unless quoted, and a JSON round trip turns
# that key into the STRING "true". Both parsers land there; accept all three
# spellings rather than reporting "no triggers" about a file that has them.
triggers = doc.get("on", doc.get(True, doc.get("true")))
if triggers is None:
    raise SystemExit("no `on:` triggers in the workflow")

lines = []
for name in sorted(triggers if isinstance(triggers, dict) else [triggers]):
    lines.append(f"trigger={name}")

jobs = doc["jobs"]
for job_name, job in jobs.items():
    lines.append(f"job={job_name}")
    lines.append(f"job.{job_name}.runs-on={job.get('runs-on','')}")
    lines.append(f"job.{job_name}.if={job.get('if','')}")
    lines.append(f"job.{job_name}.timeout-minutes={job.get('timeout-minutes','')}")
    for need in ([job["needs"]] if isinstance(job.get("needs"), str) else job.get("needs") or []):
        lines.append(f"job.{job_name}.needs={need}")
    for k, v in (job.get("env") or {}).items():
        lines.append(f"job.{job_name}.env.{k}={v}")
    for i, step in enumerate(job.get("steps") or []):
        label = step.get("name") or step.get("uses") or f"step{i}"
        lines.append(f"job.{job_name}.step={label}")
        if "uses" in step:
            lines.append(f"job.{job_name}.uses={step['uses']}")
        for k, v in (step.get("with") or {}).items():
            lines.append(f"job.{job_name}.with[{step.get('uses','')}].{k}={v}")
        for k, v in (step.get("env") or {}).items():
            lines.append(f"job.{job_name}.stepenv[{label}].{k}={v}")
        if "if" in step:
            lines.append(f"job.{job_name}.stepif[{label}]={step['if']}")
        if "run" in step:
            slug = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")
            path = os.path.join(out, f"run.{job_name}.{slug}.sh")
            with open(path, "w") as fh:
                fh.write(step["run"])
            lines.append(f"job.{job_name}.run[{label}]={os.path.basename(path)}")
            # Job env is what the step actually sees; merge it under the step's
            # own, which wins. Written beside the body so the runner below can
            # reproduce the step's real environment.
            merged = dict(job.get("env") or {})
            merged.update(step.get("env") or {})
            with open(path + ".env", "w") as fh:
                for k, v in merged.items():
                    fh.write(f"{k}={v}\n")

open(os.path.join(out, "facts.txt"), "w").write("\n".join(lines) + "\n")
PY

FACTS="$work/facts.txt"
fact() { grep -qxF "$1" "$FACTS"; }

# ---------------------------------------------------------------------------
# 2. The jobs, and the gate on the expensive one.
# ---------------------------------------------------------------------------

fact "job=lint-and-unit-test" || fail "the cheap job still exists" "$(cat "$FACTS")"
fact "job=iso-build" || fail "the ISO build job exists (T5g)" "$(cat "$FACTS")"
fact "trigger=workflow_dispatch" ||
  fail "the workflow can be dispatched by hand" "a 1-3 h job that only tags can start cannot be tried before a release"
pass "ci.yml declares both jobs and can be dispatched by hand"

iso_if=$(sed -n 's/^job\.iso-build\.if=//p' "$FACTS")
[[ $iso_if == *"refs/tags/"* ]] ||
  fail "the ISO build is gated on a tag" "got: '$iso_if' -- an unconditional 1-3 h job would run on every push"
[[ $iso_if == *"build_iso"* ]] ||
  fail "the ISO build can also be asked for explicitly" "got: '$iso_if'"
fact "job.iso-build.needs=lint-and-unit-test" ||
  fail "the ISO build waits for the cheap tier" \
    "PLAN.md §9's ordering is cheapest-first for a reason: spending 1-3 h of runner time to discover a shellcheck finding inverts it."
iso_timeout=$(sed -n 's/^job\.iso-build\.timeout-minutes=//p' "$FACTS")
[[ -n $iso_timeout && $iso_timeout != "" ]] ||
  fail "the ISO build job sets a timeout" "the default 360 min cap kills it with no diagnosis; an explicit number is a stated expectation"
pass "the ISO build runs on tags or on request only, with an explicit ${iso_timeout}-minute timeout"

# ---------------------------------------------------------------------------
# 3. The submodule split, which is a real coupling in both directions.
#
# iso/bin/build refuses to build unless iso/upstream is a clean checkout
# exactly at iso/UPSTREAM's pin, so the build job MUST fetch it. The lint job
# deliberately does not -- two unit suites skip submodule-dependent assertions
# there and say so in their skip lines. Both halves are asserted, because
# either drifting silently makes a suite's skip message a lie.
# ---------------------------------------------------------------------------

grep -q '^job\.iso-build\.with\[actions/checkout@v4\]\.submodules=True$\|^job\.iso-build\.with\[actions/checkout@v4\]\.submodules=true$' "$FACTS" ||
  fail "the ISO build job checks out iso/upstream" \
    "iso/bin/build verifies the submodule is exactly at iso/UPSTREAM and refuses otherwise, so 'submodules: true' is load-bearing here. Facts: $(grep 'iso-build.with' "$FACTS" || true)"
! grep -q '^job\.lint-and-unit-test\.with\[actions/checkout@v4\]\.submodules=' "$FACTS" ||
  fail "the lint job still does NOT fetch submodules" \
    "test/unit/test-iso-build.sh and test/unit/test-omarchy-deck-package.sh both explain their skipped assertions by citing this. If it changed on purpose, change those skip messages in the same commit."
pass "submodules are fetched for the build job and deliberately not for the lint job"

# ---------------------------------------------------------------------------
# 4. Every path the job names exists.
# ---------------------------------------------------------------------------

cat "$work"/run.iso-build.*.sh >"$work/iso-build-runs.txt"

for path in iso/bin/build test/vm/vm-install-test.sh iso/UPSTREAM iso/RUNTIME; do
  grep -qF "$path" "$work/iso-build-runs.txt" ||
    fail "the ISO build job references $path" "if the job stopped naming it, this assertion is stale rather than satisfied"
  [[ -e "$REPO_ROOT/$path" ]] || fail "$path exists in the repo" "the workflow names a path that is not there"
done
[[ -x "$REPO_ROOT/iso/bin/build" ]] || fail "iso/bin/build is executable" "the job invokes it as ./iso/bin/build"
pass "every repo path the ISO build job names exists, and iso/bin/build is executable"

# ---------------------------------------------------------------------------
# 5. The environment matches what iso/bin/build actually accepts.
# ---------------------------------------------------------------------------

# Guard 6.1 REFUSES a build whose environment disagrees with its own pins, so
# setting either of these in CI turns every tag build red at the first guard.
for forbidden in OMARCHY_ISO_REF OMARCHY_MIRROR; do
  grep -q "^job\.iso-build\.env\.$forbidden=\|^job\.iso-build\.stepenv\[[^]]*\]\.$forbidden=" "$FACTS" &&
    fail "the job does not set $forbidden" \
      "guard 6.1 refuses a build whose environment disagrees with iso/bin/build's own ref/mirror pins rather than silently overriding it."
  grep -q "export $forbidden=\|$forbidden=" "$work/iso-build-runs.txt" &&
    fail "no run body sets $forbidden either" "guard 6.1 would refuse the build"
done
pass "the job sets neither OMARCHY_ISO_REF nor OMARCHY_MIRROR (guard 6.1 refuses a disagreeing environment)"

build_dir=$(sed -n 's/^job\.iso-build\.env\.OMARCHY_DECK_ISO_BUILD_DIR=//p' "$FACTS")
[[ -n $build_dir ]] ||
  fail "the job points the build at an explicit scratch root" \
    "the default is \$HOME/.cache/omarchy-deck/iso-build; on a hosted runner that is the small volume"
[[ $build_dir == /* ]] || fail "the scratch root is an absolute path" "got: $build_dir"
# shellcheck disable=SC2016  # matching the LITERAL text in the YAML, unexpanded -- that is the point.
case $build_dir in
  *'$GITHUB_WORKSPACE'*|*'${{'*)
    fail "the scratch root is a literal path" "got: '$build_dir' -- bin/build refuses a scratch root inside the repo, and a workspace-relative one is exactly that" ;;
esac
pass "the job builds into an explicit absolute scratch root outside the checkout ($build_dir)"

# The third pin. bin/build hard-fails when iso/PKGS is absent AND
# OMARCHY_DECK_PKGS_SRC is unset -- so exactly one of the two must hold, and
# which one it is may change.
if [[ -f "$REPO_ROOT/iso/PKGS" ]]; then
  grep -q 'OMARCHY_DECK_PKGS_SRC' "$work/iso-build-runs.txt" &&
    fail "with iso/PKGS present the job need not set OMARCHY_DECK_PKGS_SRC" \
      "bin/build clones omacom-io/omarchy-pkgs at the pin itself; an override here would silently un-pin the third input"
  pass "iso/PKGS pins the PKGBUILDs, so the job correctly leaves OMARCHY_DECK_PKGS_SRC unset"
else
  grep -q 'OMARCHY_DECK_PKGS_SRC' "$work/iso-build-runs.txt" ||
    fail "without iso/PKGS the job MUST set OMARCHY_DECK_PKGS_SRC" \
      "iso/bin/build refuses to run with neither -- the tag build would fail at step 2b, after checkout, for a reason nobody would guess"
  pass "iso/PKGS is absent, and the job supplies OMARCHY_DECK_PKGS_SRC as bin/build requires"
fi

# The tools the guards refuse to run without. bsdtar is the sharp one: guards
# 6.4b and 6.5b both hard-fail without it rather than skipping, so a runner
# that lacks it fails AFTER the whole build.
grep -q 'bsdtar' "$BUILD_SCRIPT" || fail "iso/bin/build still needs bsdtar" "this assertion has gone stale"
grep -q 'libarchive-tools' "$work/iso-build-runs.txt" ||
  fail "the job installs bsdtar (libarchive-tools)" \
    "guards 6.4b and 6.5b refuse to run without it -- and they run after the ~6 GB build, so a missing package costs the whole job"
grep -q 'rsync' "$BUILD_SCRIPT" || fail "iso/bin/build still uses rsync" "this assertion has gone stale"
grep -q 'rsync' "$work/iso-build-runs.txt" || fail "the job installs rsync" "bin/build rsyncs the overlay over the scratch tree"
pass "the job installs the tools bin/build's guards hard-fail without (bsdtar, rsync)"

# ---------------------------------------------------------------------------
# 6. 🔴 The size gate, executed.
# ---------------------------------------------------------------------------

GATE="$work/run.iso-build.iso-size-gate.sh"
[[ -f $GATE ]] ||
  fail "there is a step named 'ISO size gate'" "found: $(grep '^job\.iso-build\.step=' "$FACTS" | sed 's/^.*=//' | tr '\n' '|')"

# It has to be plain bash to be testable AND to be honest: a ${{ }} expression
# inside a run body is substituted by the runner, so what is tested here would
# not be what executes there.
# shellcheck disable=SC2016  # searching for the literal ${{ }} in the extracted body.
! grep -q '\${{' "$GATE" ||
  fail "the gate body contains no \${{ }} expressions" \
    "GitHub substitutes those before bash sees them, so this suite would be executing something the runner never runs. Keep expressions in the step's env:."

GATE_MIN=$(sed -n 's/^ISO_SIZE_MIN_BYTES=//p' "$GATE.env")
GATE_MAX=$(sed -n 's/^ISO_SIZE_MAX_BYTES=//p' "$GATE.env")
[[ -n $GATE_MIN && -n $GATE_MAX ]] ||
  fail "the gate declares its bounds in the step's env" "got min='$GATE_MIN' max='$GATE_MAX'"
(( GATE_MIN < GATE_MAX )) || fail "the gate's bounds are a range" "min=$GATE_MIN max=$GATE_MAX"

# The bounds are anchored to MEASURED artifacts, not to taste. Each of these
# was weighed on a real image; if a bound ever excludes one, the bound moved
# somewhere its evidence does not support.
#   6,390,581,248  the stock reference ISO           docs/PROGRESS.md §1.1
#   6,273,040,384  our pinned build before T5c       T5a-parity.md Appendix A1
#   6,843,465,728  that + T5c's measured +544 MiB    T5-fork-plan.md §7
for anchor in 6390581248 6273040384 6843465728; do
  (( anchor >= GATE_MIN && anchor <= GATE_MAX )) ||
    fail "the gate accepts every ISO this project has actually measured ($anchor)" \
      "bounds are $GATE_MIN..$GATE_MAX. A gate that rejects a known-good artifact is a false positive, and false positives are how checks get ignored (docs/PROGRESS.md §5.17)."
done
pass "the size gate's bounds ($GATE_MIN..$GATE_MAX) contain all three measured ISO sizes"

# The line the gate parses is BUILT FROM iso/bin/build's own format string, so
# the two files cannot drift apart quietly.
build_prog=$(sed -n 's/^BUILD_PROG=//p' "$BUILD_SCRIPT" | head -n1)
size_fmt=$(sed -n 's/^build_log "\(iso size: .*\)"$/\1/p' "$BUILD_SCRIPT" | head -n1)
[[ -n $build_prog ]] || fail "iso/bin/build still declares BUILD_PROG" "the gate's expression is anchored on it"
[[ -n $size_fmt ]] ||
  fail "iso/bin/build still prints an 'iso size:' line" \
    "the gate parses it; if the build stopped printing it, the gate matches nothing -- and a gate that matches nothing passes everything"

# make_size_line <bytes> -- exactly what bin/build would print for that size.
make_size_line() {
  local rendered=${size_fmt//\$iso_bytes/$1}
  rendered=${rendered//\$iso_gib/5.84}
  printf '[%s] %s\n' "$build_prog" "$rendered"
}

GATE_OUT=""
GATE_STATUS=0
run_gate() {
  # $1 = log path (may not exist), rest = extra environment
  local log=$1; shift
  GATE_OUT=""
  GATE_STATUS=0
  GATE_OUT=$(env -i PATH="$PATH" \
    ISO_BUILD_LOG="$log" \
    ISO_SIZE_MIN_BYTES="$GATE_MIN" \
    ISO_SIZE_MAX_BYTES="$GATE_MAX" \
    "$@" bash "$GATE" 2>&1) || GATE_STATUS=$?
  return 0
}

in_range=$(( GATE_MIN + (GATE_MAX - GATE_MIN) / 2 ))

# --- 6a. the positive case, and its denominator ----------------------------
log_ok="$work/log-ok"
{ printf '[%s] guard 6.4b OK: whatever\n' "$build_prog"; make_size_line "$in_range"; } >"$log_ok"
run_gate "$log_ok"
[[ $GATE_STATUS -eq 0 ]] || fail "an in-range ISO passes the gate" "status=$GATE_STATUS $GATE_OUT"
[[ $GATE_OUT == *"$in_range bytes"* ]] ||
  fail "the gate echoes the size it read, so a green run is evidence rather than reassurance" "$GATE_OUT"
pass "🔴 the size gate reads iso/bin/build's own line format and passes an in-range ISO ($in_range bytes)"

# --- 6b. 🔴 the gate can fail: under, and over -----------------------------
log_small="$work/log-small"
make_size_line "$(( GATE_MIN - 1 ))" >"$log_small"
run_gate "$log_small"
[[ $GATE_STATUS -ne 0 ]] || fail "🔴 an ISO below the floor must FAIL the gate" "$GATE_OUT"
[[ $GATE_OUT == *"below the"* ]] || fail "the failure says which bound was crossed" "$GATE_OUT"
[[ $GATE_OUT == *"offline mirror"* ]] ||
  fail "the failure names the likely cause rather than only the number" "$GATE_OUT"

log_big="$work/log-big"
make_size_line "$(( GATE_MAX + 1 ))" >"$log_big"
run_gate "$log_big"
[[ $GATE_STATUS -ne 0 ]] || fail "🔴 an ISO above the ceiling must FAIL the gate" "$GATE_OUT"
[[ $GATE_OUT == *"above the"* ]] || fail "the failure says which bound was crossed" "$GATE_OUT"
pass "🔴 the size gate rejects an ISO one byte below its floor and one byte above its ceiling"

# --- 6c. the ways a gate silently stops gating -----------------------------
#
# All three of these would otherwise look identical to a pass: no number
# parsed, two numbers parsed, or no log at all.
log_none="$work/log-none"
printf '[%s] build complete: /tmp/x.iso\n' "$build_prog" >"$log_none"
run_gate "$log_none"
[[ $GATE_STATUS -ne 0 ]] ||
  fail "🔴 a log with NO size line must fail, not pass" \
    "This is the drift case: bin/build's format changes, the expression matches nothing, and every ISO passes forever. $GATE_OUT"
[[ $GATE_OUT == *"found 0"* ]] || fail "the failure says it found none" "$GATE_OUT"

log_two="$work/log-two"
{ make_size_line "$in_range"; make_size_line "$(( in_range + 1 ))"; } >"$log_two"
run_gate "$log_two"
[[ $GATE_STATUS -ne 0 ]] ||
  fail "two size lines must fail -- the gate cannot tell which artifact is the artifact" "$GATE_OUT"
[[ $GATE_OUT == *"found 2"* ]] || fail "the failure says how many it found" "$GATE_OUT"

run_gate "$work/log-does-not-exist"
[[ $GATE_STATUS -ne 0 ]] || fail "a missing build log must fail the gate" "$GATE_OUT"
[[ $GATE_OUT == *"no build log"* ]] || fail "the failure says the log was absent" "$GATE_OUT"
pass "🔴 the gate fails on a log with no size line, on two of them, and on no log at all"

# --- 6d. the coupling, from the other end ----------------------------------
#
# A line in bin/build's shape but from a DIFFERENT program must not satisfy it:
# the gate is anchored, not a loose grep for three digits.
log_foreign="$work/log-foreign"
printf '[some-other-tool] iso size: %s bytes (5.84 GiB)\n' "$in_range" >"$log_foreign"
run_gate "$log_foreign"
[[ $GATE_STATUS -ne 0 ]] ||
  fail "the gate must not accept a size line printed by something else" "$GATE_OUT"
pass "the gate is anchored on iso/bin/build's own prefix, not on any 'iso size' text in the log"

# ---------------------------------------------------------------------------
# 7. The honesty assertions: the job says, in the file, that it is unproven,
#    and it does not quietly upload six gigabytes.
# ---------------------------------------------------------------------------

grep -q 'NOTHING IN THE iso-build JOB HAS EVER RUN' "$WORKFLOW" ||
  fail "the workflow states that its build job is unproven" \
    "Delete that warning only when a tag build has actually run -- and then say WHICH one, with its number."
grep -q "if: github.event.inputs.upload_iso == 'true'" "$WORKFLOW" ||
  fail "uploading the ~6 GB ISO is opt-in" \
    "A private repo's free Actions storage is 500 MB; an unconditional upload fails the job after a successful build, which reads as 'the build broke'."
pass "the workflow records that the build job is unproven, and keeps the 6 GB upload opt-in"

printf '\nall ci-workflow tests passed\n'
