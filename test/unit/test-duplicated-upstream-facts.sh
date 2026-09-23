#!/usr/bin/env bash
# Unit tests for the four upstream facts this repo writes down TWICE.
#
# WHY THIS EXISTS
#
# docs/findings/T9-coupling-inventory.md §8.1 found four facts about upstream
# that are stated in two files each, with nothing keeping them in step:
#
#   1. Limine's five config-path candidates
#        src/omarchy-deck-kernel.sh  <->  test/lib/vm-assertions.sh
#   2. The Valve repo / mirror / SigLevel block
#        src/omarchy-deck-kernel.sh  <->  test/images/vm-neptune-image.sh
#   3. (Retired 2026-09-17: the firmware-collision regex pair died with
#      stage_firmware_swap -- linux-omarchy uses Arch's own firmware, so
#      there is no swap and nothing to collide. The section below asserts
#      the retirement, not the pair.)
#   4. The Deck kernel package name
#        src/omarchy-deck-kernel.sh  <->  test/images/vm-neptune-image.sh
#
# Each one is a place where the TEST can stay green after the PRODUCT has been
# fixed, or the product can be fixed while the test still asserts the old
# world.
#
# Two of the four turned out to have MORE than two copies. Those extra copies
# are asserted here too, and flagged in the report:
#
#   - the Valve mirror's HOSTNAME is repeated in three VM suites' network
#     pre-check
#   - the Valve repo NAMES are repeated in vm-kernel-stage-test.sh's awk
#     stripper, which is what makes its "no Valve repos" precondition case
#     mean anything
#
# HOW IT REACHES THE CODE
#
# None of these can be sourced. Two live inside an unquoted heredoc that is
# written out and executed inside a Docker container; the other two live in a
# script that validates argv at load time. So each side is scraped out of its
# file as text, normalised for what is genuinely incidental (quoting style,
# indentation, blank lines), and compared.
#
# ⚠️ Scraping is why require_extract() is the most important function in this
# file. A renamed variable, a moved function or a reflowed heredoc makes a
# scrape return nothing -- and comparing two empty strings PASSES. "Found
# nothing" reading as "found no problems" is the exact bug class this suite
# exists to close, so nothing is compared before it has been through that
# guard. Every assertion below was mutation-tested by editing ONE side of its
# pair, and by breaking its own extraction, before being trusted.
#
# No Docker, no VM, no root, no network: this suite only reads files.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
KERNEL="$REPO_ROOT/src/omarchy-deck-kernel.sh"      # the product
ASSERTIONS="$REPO_ROOT/test/lib/vm-assertions.sh"   # copy of fact 1
BUILDER="$REPO_ROOT/test/images/vm-neptune-image.sh" # copy of facts 2, 3, 4

# The three VM suites that drive the product script, and therefore repeat its
# facts a third time. Listed rather than globbed: vm-gamepad-spike-test.sh has
# its own (Arch, not Valve) mirror pre-check and must not be swept up.
KERNEL_VM_SUITES=(
  "$REPO_ROOT/test/vm/vm-kernel-hook-test.sh"
  "$REPO_ROOT/test/vm/vm-kernel-stage-test.sh"
  "$REPO_ROOT/test/vm/vm-kernel-idempotency-test.sh"
)
STAGE_SUITE="$REPO_ROOT/test/vm/vm-kernel-stage-test.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

for f in "$KERNEL" "$ASSERTIONS" "$BUILDER" "${KERNEL_VM_SUITES[@]}"; do
  [[ -f $f ]] ||
    fail "every file holding a duplicated fact still exists" \
      "missing: $f -- if it moved, this suite's cross-checks are now vacuous and the path must be updated here"
done
pass "all six files holding duplicated upstream facts are present"

# --- the guard ---------------------------------------------------------------
#
# require_extract <what> <which-file> <min-lines> <value>
#
# ⚠️ THE LOAD-BEARING FUNCTION. Refuses to let an empty or implausibly short
# scrape reach a comparison. Both arguments of every pair below go through
# this, individually, so a failure names WHICH side stopped being findable
# rather than reporting a cheerful match between two nothings.
require_extract() {
  local what=$1 where=$2 min=$3 value=$4 lines
  if [[ -z ${value//[[:space:]]/} ]]; then
    fail "EXTRACTION FAILED (empty): ${what}" \
      "scraped nothing out of ${where}.
This is NOT a pass. The text this suite looks for was renamed, moved or
reflowed, so the comparison it feeds would have compared two empty strings.
Fix the extraction in $(basename "${BASH_SOURCE[0]}") to match the new shape,
then re-run -- do not delete the assertion."
  fi
  lines=$(wc -l <<<"$value")
  if ((lines < min)); then
    fail "EXTRACTION FAILED (too short): ${what}" \
      "scraped only ${lines} line(s) from ${where}, expected at least ${min}:
${value}
A partial scrape passes as easily as an empty one. See the note above."
  fi
}

# extract_bash_array <file> <array-name>
# Prints one element per line. Handles both the one-line form
# `readonly -a X=(a b)` and the multi-line form, and strips indentation,
# trailing comments and quoting style -- the three things that are genuinely
# incidental when comparing two copies of the same list.
extract_bash_array() {
  local file=$1 name=$2
  awk -v name="$name" '
    !inside && $0 ~ "^readonly -a " name "=\\(" {
      inside = 1
      sub("^readonly -a " name "=\\(", "")
    }
    inside {
      line = $0
      sub(/#.*/, "", line)
      if (line ~ /\)/) { sub(/\).*/, "", line); print line; exit }
      print line
    }
  ' "$file" |
    tr -s '[:space:]' '\n' |
    sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//" |
    grep -v '^$' || true
}

# normalise_conf <<<text
# For comparing two copies of a pacman.conf fragment: drop blank lines, trim
# the ends, and collapse whitespace runs. `[section]` is what starts a pacman
# section, not the blank line before it, and `Server=x` and `Server = x` are
# the same directive -- so all three are incidental. Nothing else is touched.
normalise_conf() {
  sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//' -e '/^$/d'
}

# =============================================================================
# FACT 1 -- Limine's config-path candidates
#
#   src/omarchy-deck-kernel.sh  LIMINE_CONFIG_CANDIDATES
#   test/lib/vm-assertions.sh   VM_ASSERT_LIMINE_CONFIG_CANDIDATES
#
# Both files' comments say the same thing: Omarchy's own limine-snapper.sh
# probes exactly these, so do the same. Upstream adding a sixth location
# breaks the product's probe and the assertion library's probe SEPARATELY.
#
# Asserted EQUAL, and ORDER-SENSITIVE. Order is not incidental here: it is
# probe order, so on a machine carrying two configs it decides which one the
# product edits and which one the VM assertions read. A reordering that made
# those two disagree would be invisible to every other check in the repo.
# =============================================================================

mapfile -t product_paths < <(extract_bash_array "$KERNEL" LIMINE_CONFIG_CANDIDATES)
mapfile -t test_paths < <(extract_bash_array "$ASSERTIONS" VM_ASSERT_LIMINE_CONFIG_CANDIDATES)

require_extract "Limine config candidates (product side)" \
  "${KERNEL}: readonly -a LIMINE_CONFIG_CANDIDATES=( ... )" 3 \
  "$(printf '%s\n' "${product_paths[@]:-}")"
require_extract "Limine config candidates (test side)" \
  "${ASSERTIONS}: readonly -a VM_ASSERT_LIMINE_CONFIG_CANDIDATES=( ... )" 3 \
  "$(printf '%s\n' "${test_paths[@]:-}")"
pass "both copies of the Limine config candidates extract, with ${#product_paths[@]} and ${#test_paths[@]} entries"

if [[ ${product_paths[*]} != "${test_paths[*]}" ]]; then
  fail "FACT 1 DIVERGED: Limine's config-path candidates" \
    "src/omarchy-deck-kernel.sh   LIMINE_CONFIG_CANDIDATES:
  ${product_paths[*]}
test/lib/vm-assertions.sh    VM_ASSERT_LIMINE_CONFIG_CANDIDATES:
  ${test_paths[*]}
These must be the same list in the same order -- it is probe order, and the
product and the VM assertions would otherwise read different files on a
machine that has more than one Limine config. Update BOTH."
fi
pass "fact 1: the two copies of Limine's config-path candidates are identical, in order"

# Not a failure, only a note: the count is a claim about upstream, not about
# the pair, and this suite's job is the pair. Both files' prose says "five".
[[ ${#product_paths[@]} -eq 5 ]] ||
  printf 'note - the candidate list is now %d long; both files say "five" in prose (src/omarchy-deck-kernel.sh, test/lib/vm-assertions.sh)\n' \
    "${#product_paths[@]}"

# --- 1b: the substrate's SINGLE location, against the product's five ---------
#
# ⚠️ A WEAKER ASSERTION ON PURPOSE -- subset, not equality.
#
# The substrate builder plants exactly one Limine config (/boot/limine.conf),
# where the product probes five candidates. That narrowing is deliberate
# (T9-coupling-inventory.md §4): the builder REPRODUCES one machine, it does
# not have to model every layout the product must survive. Forcing the two into
# equality would mean either making the builder plant five configs -- a shape
# no real machine has -- or cutting the product's probe down to one, which is
# the hardcoding PLAN.md §8.2 exists to forbid.
#
# The relationship that IS load-bearing is containment: the one config the
# substrate plants must be a path the product would find. If upstream drops
# that candidate and both copies of the list are updated in step, fact 1 above
# still passes -- and every VM suite then boots a guest whose config the
# product's probe walks straight past, failing with "no Limine config at any
# candidate location", which reads as a broken image rather than a stale list.
substrate_esp=$(sed -nE 's/^ESP_PATH="([^"]*)"$/\1/p' "$BUILDER")
require_extract "the substrate's ESP_PATH (test side)" \
  "${BUILDER}: ESP_PATH=\"...\" in the /etc/default/limine heredoc" 1 "$substrate_esp"
mapfile -t substrate_configs < <(
  grep -oE '/mnt/[A-Za-z0-9._/-]*limine\.conf' "$BUILDER" | sed 's|^/mnt||' | sort -u
)
require_extract "the substrate's Limine config path (test side)" \
  "${BUILDER}: the /mnt/.../limine.conf paths it writes and reads" 1 \
  "$(printf '%s\n' "${substrate_configs[@]:-}")"
[[ ${#substrate_configs[@]} -eq 1 ]] ||
  fail "EXTRACTION FAILED (ambiguous): the substrate's Limine config path" \
    "${BUILDER} now names ${#substrate_configs[@]} different config paths (${substrate_configs[*]}).
The containment check below has no single path to check. Decide which one is
the substrate's config and re-point this."
substrate_config=${substrate_configs[0]}
[[ $substrate_config == "${substrate_esp}"/* ]] ||
  fail "FACT 1 DIVERGED: the substrate's Limine config is not on its own ESP" \
    "test/images/vm-neptune-image.sh plants ${substrate_config}, but declares
ESP_PATH=\"${substrate_esp}\" in /etc/default/limine. The product resolves the
config as \${ESP_PATH}\${candidate}, so it cannot reach a config outside the ESP."
substrate_rel=${substrate_config#"$substrate_esp"}
found_candidate=0
for candidate in "${product_paths[@]}"; do
  [[ $candidate == "$substrate_rel" ]] && found_candidate=1
done
((found_candidate == 1)) ||
  fail "FACT 1 DIVERGED: the substrate plants a config the product would not find" \
    "test/images/vm-neptune-image.sh writes ${substrate_config}
  (ESP ${substrate_esp}, so ESP-relative: ${substrate_rel})
src/omarchy-deck-kernel.sh LIMINE_CONFIG_CANDIDATES:
  ${product_paths[*]}
This is a SUBSET check, not an equality check -- the substrate models one
machine and only has to plant a path the product probes. It does not."
pass "fact 1b: the substrate's single config (${substrate_rel} on ${substrate_esp}) is one of the product's ${#product_paths[@]} candidates"

# =============================================================================
# FACT 2 -- the Valve repo / mirror / SigLevel block
#
#   src/omarchy-deck-kernel.sh   VALVE_REPOS + VALVE_MIRROR + stage_repos()
#   test/images/vm-neptune-image.sh  a literal pacman.conf fragment
#
# The builder says the guest is given the repos "the same way
# omarchy-deck-kernel.sh's stage_repos adds them, so the guest starts from the
# state that script leaves behind". That is the whole justification for the VM
# suites' results transferring to the Deck, and it was prose only.
#
# Asserted EQUAL by RENDERING the product's own heredoc template once per
# entry in VALVE_REPOS and comparing the result to the builder's literal
# block. That is stronger than comparing field by field: it also catches a
# directive ADDED on one side (a Usage=, an extra SigLevel) which no
# field-by-field check would look for.
# =============================================================================

mapfile -t product_repos < <(extract_bash_array "$KERNEL" VALVE_REPOS)
require_extract "Valve repo list (product side)" \
  "${KERNEL}: readonly -a VALVE_REPOS=( ... )" 2 \
  "$(printf '%s\n' "${product_repos[@]:-}")"

product_mirror=$(sed -nE "s/^readonly VALVE_MIRROR='(.*)'\$/\1/p" "$KERNEL")
require_extract "Valve mirror URL (product side)" \
  "${KERNEL}: readonly VALVE_MIRROR='...'" 1 "$product_mirror"

stage_repos_body=$(sed -n '/^stage_repos()/,/^}/p' "$KERNEL")
require_extract "stage_repos() body (product side)" \
  "${KERNEL}: stage_repos() { ... }" 10 "$stage_repos_body"

# The heredoc stage_repos appends per repo, minus its two delimiter lines.
product_block_tmpl=$(sed -n '/<<EOF$/,/^EOF$/p' <<<"$stage_repos_body" | sed -e '1d' -e '$d')
require_extract "the pacman.conf fragment stage_repos writes (product side)" \
  "${KERNEL}: the <<EOF heredoc inside stage_repos()" 3 "$product_block_tmpl"
# shellcheck disable=SC2016 # matching the LITERAL ${repo}/${VALVE_MIRROR} in
# the product's heredoc; expanding them here would search for this shell's vars
for anchor in '[${repo}]' 'Server = ${VALVE_MIRROR}' 'SigLevel'; do
  grep -qF -- "$anchor" <<<"$product_block_tmpl" ||
    fail "EXTRACTION FAILED (wrong range): stage_repos()'s pacman.conf fragment" \
      "scraped a block from ${KERNEL} that has no '${anchor}' in it:
${product_block_tmpl}
The heredoc moved or changed shape. Re-point the extraction; do not delete it."
done
pass "the product's repo block template, repo list (${product_repos[*]}) and mirror all extract"

# The builder's literal copy. Exactly one such heredoc must exist, or the sed
# range below would silently splice two of them together.
appends=$(grep -c '^cat >>/mnt/etc/pacman.conf' "$BUILDER" || true)
[[ $appends -eq 1 ]] ||
  fail "EXTRACTION FAILED (ambiguous): the builder's pacman.conf append" \
    "found ${appends} 'cat >>/mnt/etc/pacman.conf' heredocs in ${BUILDER}, expected exactly 1.
With more than one, the extraction below splices them together and compares
nonsense; with none, it compares nothing at all."
substrate_block=$(sed -n "/^cat >>\/mnt\/etc\/pacman.conf <<'EOF'\$/,/^EOF\$/p" "$BUILDER" |
  sed -e '1d' -e '$d')
require_extract "the pacman.conf fragment the substrate plants (test side)" \
  "${BUILDER}: the cat >>/mnt/etc/pacman.conf heredoc" 3 "$substrate_block"
pass "the substrate's literal pacman.conf fragment extracts (${appends} heredoc, as expected)"

# 2a. The repo names and their order.
mapfile -t substrate_repos < <(sed -nE 's/^\[([a-z0-9][a-z0-9._-]*)\]$/\1/p' <<<"$substrate_block")
require_extract "repo section headers (test side)" \
  "${BUILDER}: the [<repo>] headers in that fragment" 2 \
  "$(printf '%s\n' "${substrate_repos[@]:-}")"
if [[ ${product_repos[*]} != "${substrate_repos[*]}" ]]; then
  fail "FACT 2 DIVERGED: the Valve repo list" \
    "src/omarchy-deck-kernel.sh       VALVE_REPOS:
  ${product_repos[*]}
test/images/vm-neptune-image.sh  [<repo>] sections it plants:
  ${substrate_repos[*]}
The substrate exists to start the guest from the state stage_repos leaves
behind. A repo in one list and not the other means the VM suites test a
pacman.conf no Deck has. Order is compared because pacman resolves
'pacman -S <name>' by repo order (see the stage_repos header comment)."
fi
pass "fact 2a: the substrate plants exactly the product's Valve repos, in order (${product_repos[*]})"

# 2b. The mirror URL.
mapfile -t substrate_servers < <(sed -nE 's/^Server[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' <<<"$substrate_block")
require_extract "Server= lines (test side)" \
  "${BUILDER}: the Server = lines in that fragment" 2 \
  "$(printf '%s\n' "${substrate_servers[@]:-}")"
for server in "${substrate_servers[@]}"; do
  [[ $server == "$product_mirror" ]] ||
    fail "FACT 2 DIVERGED: the Valve mirror URL" \
      "src/omarchy-deck-kernel.sh       VALVE_MIRROR:
  ${product_mirror}
test/images/vm-neptune-image.sh  Server =:
  ${server}
The substrate would pull the guest's Valve packages from a different mirror
than the product configures on the Deck."
done
pass "fact 2b: every Server= in the substrate is the product's VALVE_MIRROR"

# 2c. The whole fragment, rendered from the product's own template. Catches
# anything 2a/2b do not look for -- a changed SigLevel, an added directive.
rendered=""
for repo in "${product_repos[@]}"; do
  rendered+=$(sed -e "s|[$]{repo}|${repo}|g" -e "s|[$]{VALVE_MIRROR}|${product_mirror}|g" \
    <<<"$product_block_tmpl")
  rendered+=$'\n'
done
rendered_norm=$(normalise_conf <<<"$rendered")
substrate_norm=$(normalise_conf <<<"$substrate_block")
require_extract "the rendered product fragment" "the render of ${KERNEL}'s template" 3 "$rendered_norm"
require_extract "the normalised substrate fragment" "${BUILDER}" 3 "$substrate_norm"
if [[ $rendered_norm != "$substrate_norm" ]]; then
  fail "FACT 2 DIVERGED: the pacman.conf fragment itself" \
    "what src/omarchy-deck-kernel.sh's stage_repos would write:
${rendered_norm}
what test/images/vm-neptune-image.sh actually plants:
${substrate_norm}
(blank lines, indentation and spacing around '=' are normalised away before
comparing; anything shown above is a real difference in directives.)"
fi
pass "fact 2c: the substrate's fragment is exactly what stage_repos would write"

# --- 2f: the THIRD copy, on the target itself ---------------------------------
#
# 2026-09-17 Deck-verified: src/deck-session.sh's stage-valve-repos puts the
# SAME repos on the installed target (the kernel script's stage_repos never runs
# there -- no copy of that script is installed on the Deck). If these drift, the
# target's pacman.conf and the VM guests diverge: a package resolving from
# Valve's mirror in test resolves from Arch's on the Deck, which is exactly the
# gamescope swap that deleted Gaming Mode (Arch 3.16.28-1 over Valve 3.16.25-3).
# Asserted EQUAL to the product side above: same names in order, same mirror,
# same SigLevel. The deck-session copy renders its sections with printf rather
# than a heredoc, so the comparison is on the rendered directives, not the
# template text -- which is the same strength as 2c above.
SESSION_SH="$REPO_ROOT/src/deck-session.sh"
[[ -f $SESSION_SH ]] ||
  fail "EXTRACTION FAILED (missing): the session layer's Valve repo copy" \
    "expected ${SESSION_SH} to exist; it holds the target-side copy of the Valve repos"
mapfile -t session_repos < <(extract_bash_array "$SESSION_SH" VALVE_REPOS)
require_extract "Valve repo list (session side)" \
  "${SESSION_SH}: readonly -a VALVE_REPOS=( ... )" 2 \
  "$(printf '%s\n' "${session_repos[@]:-}")"
[[ ${product_repos[*]} == "${session_repos[*]}" ]] ||
  fail "FACT 2 DIVERGED (third copy): the session layer's Valve repos" \
    "src/omarchy-deck-kernel.sh  VALVE_REPOS: ${product_repos[*]}
src/deck-session.sh         VALVE_REPOS: ${session_repos[*]}
The target would carry a different repo set than the VM guests the suites test."
pass "fact 2f: deck-session.sh's VALVE_REPOS matches the kernel script's (${product_repos[*]})"
session_mirror=$(sed -nE "s/^readonly VALVE_MIRROR='(.*)'\$/\1/p" "$SESSION_SH")
require_extract "Valve mirror URL (session side)" \
  "${SESSION_SH}: readonly VALVE_MIRROR='...'" 1 "$session_mirror"
[[ $product_mirror == "$session_mirror" ]] ||
  fail "FACT 2 DIVERGED (third copy): the session layer's Valve mirror" \
    "src/omarchy-deck-kernel.sh  VALVE_MIRROR: ${product_mirror}
src/deck-session.sh         VALVE_MIRROR: ${session_mirror}"
pass "fact 2f: deck-session.sh's VALVE_MIRROR matches the kernel script's"
session_sig=$(grep -c 'SigLevel = Never' "$SESSION_SH" || true)
[[ $session_sig -ge 2 ]] ||
  fail "FACT 2 DIVERGED (third copy): the session layer's SigLevel" \
    "src/deck-session.sh names 'SigLevel = Never' ${session_sig} time(s); the repos are unsigned, and a session copy that drops it changes the trust shape."
pass "fact 2f: deck-session.sh's Valve sections carry SigLevel = Never"
# The repair must stay repo-qualified: a bare `pacman -S gamescope` in
# stage_valve_repos resolves by repo order to Arch's build -- reinstalling the
# very defect the repair exists to fix.
#
# The negative grep below passes vacuously on an empty scrape (a renamed
# function yields no body, and no body contains no bare name), so the
# extraction gets a positive control first: the body must exist, and must name
# the constant the repair installs through.
valve_repair_body=$(bash -c 'source "$1"; declare -f stage_valve_repos' _ "$SESSION_SH")
require_extract "the gamescope repair body (session side)" \
  "${SESSION_SH}: stage_valve_repos() { ... }" 5 "$valve_repair_body"
[[ $valve_repair_body == *GAMESCOPE_VALVE_SPEC* ]] ||
  fail "FACT 2 DIVERGED (third copy): the session layer's gamescope repair" \
    "stage_valve_repos no longer references GAMESCOPE_VALVE_SPEC -- the install it performs is not visibly the repo-qualified one."
# ...and the constant's VALUE must itself be repo-qualified (`repo/name`): a
# bare `gamescope` value would pass both checks above and still resolve by
# repo order to Arch's build.
gamescope_spec=$(sed -nE 's/^readonly GAMESCOPE_VALVE_SPEC=(.*)$/\1/p' "$SESSION_SH")
require_extract "the gamescope spec constant (session side)" \
  "${SESSION_SH}: readonly GAMESCOPE_VALVE_SPEC=..." 1 "$gamescope_spec"
[[ $gamescope_spec == */* ]] ||
  fail "FACT 2 DIVERGED (third copy): the session layer's gamescope repair" \
    "GAMESCOPE_VALVE_SPEC is '${gamescope_spec}', a bare name -- it must be repo/name or pacman resolves it by repo order to Arch's bare compositor."
! grep -qE 'pacman -S[^/]* gamescope' <<<"$valve_repair_body" ||
  fail "FACT 2 DIVERGED (third copy): the session layer's gamescope repair" \
    "stage_valve_repos installs a bare gamescope name, which resolves by repo order to Arch's bare compositor."
pass "fact 2f: stage_valve_repos installs only the repo-qualified gamescope build"

# --- 2d/2e: two further copies the inventory did not record -----------------
#
# The mirror's HOSTNAME is repeated in each kernel VM suite's reachability
# pre-check. If the product's mirror moves, those suites keep resolving a host
# nobody uses: an unreachable new mirror reads as "online", and a reachable old
# one as "offline", so the suite either runs a doomed test or skips a fine one.

mirror_host=${product_mirror#*://}
mirror_host=${mirror_host%%/*}
require_extract "the mirror hostname (product side)" \
  "${KERNEL}: the host part of VALVE_MIRROR" 1 "$mirror_host"
for suite in "${KERNEL_VM_SUITES[@]}"; do
  mapfile -t hosts < <(sed -nE 's/^.*getent hosts ([A-Za-z0-9._-]+).*$/\1/p' "$suite")
  require_extract "the network pre-check host in $(basename "$suite")" \
    "${suite}: getent hosts <host>" 1 "$(printf '%s\n' "${hosts[@]:-}")"
  for host in "${hosts[@]}"; do
    [[ $host == "$mirror_host" ]] ||
      fail "FACT 2 DIVERGED (third copy): the Valve mirror hostname" \
        "src/omarchy-deck-kernel.sh  VALVE_MIRROR host:  ${mirror_host}
${suite}
                            getent hosts:       ${host}
This suite's 'is the network up' gate probes a host the product does not use,
so it will report the wrong answer about the mirror the run actually needs."
  done
done
pass "fact 2d: all ${#KERNEL_VM_SUITES[@]} kernel VM suites pre-check the product's own mirror host (${mirror_host})"

# vm-kernel-stage-test.sh proves the product FAILS LOUDLY without the Valve
# repos by stripping them out of pacman.conf with an awk that names them
# literally. Add a third repo to VALVE_REPOS and the stripper leaves it behind:
# the "no repos" case then runs against a system that still has one, and passes
# for the wrong reason.
stripper=$(sed -n "/^awk '/,/pacman\.conf\.orig/p" "$STAGE_SUITE")
require_extract "the Valve-repo stripper (test side)" \
  "${STAGE_SUITE}: the awk that removes the repos from pacman.conf" 3 "$stripper"
grep -q 'skip' <<<"$stripper" ||
  fail "EXTRACTION FAILED (wrong range): the Valve-repo stripper" \
    "the block scraped from ${STAGE_SUITE} does not look like the stripper:
${stripper}"
# The stripper names the sections inside awk regexes, so its brackets are
# backslash-escaped. That escaping is incidental to WHICH repos it removes,
# which is the only thing compared here.
stripper_repos=${stripper//\\/}
for repo in "${product_repos[@]}"; do
  grep -qF -- "[${repo}]" <<<"$stripper_repos" ||
    fail "FACT 2 DIVERGED (third copy): the Valve repo names" \
      "src/omarchy-deck-kernel.sh  VALVE_REPOS: ${product_repos[*]}
${STAGE_SUITE}
                            its awk stripper does not name [${repo}]:
${stripper}
The stripper is what makes that suite's 'Valve repos absent' precondition case
mean anything. A repo it does not strip stays configured, and the case passes
while testing the opposite of what it claims."
done
# And nothing else: a section the product never adds but the suite strips means
# the suite is measuring a pacman.conf the product does not produce.
mapfile -t stripped_repos < <(grep -oE '\[[a-z0-9][a-z0-9._-]*\]' <<<"$stripper_repos" | tr -d '[]' | sort -u)
require_extract "the repos named by the stripper (test side)" \
  "${STAGE_SUITE}: the [<repo>] patterns inside its awk" 2 \
  "$(printf '%s\n' "${stripped_repos[@]:-}")"
# No pipe into the loop: `fail` inside a pipeline runs in a subshell, so its
# exit would be swallowed and the suite would carry on green -- the same
# green-for-the-wrong-reason shape this whole file is about.
mapfile -t extra_repos < <(
  comm -13 <(printf '%s\n' "${product_repos[@]}" | sort -u) <(printf '%s\n' "${stripped_repos[@]}")
)
((${#extra_repos[@]} == 0)) ||
  fail "FACT 2 DIVERGED (third copy): the stripper removes a repo the product never adds" \
    "${STAGE_SUITE} strips [${extra_repos[*]}], which is not in VALVE_REPOS (${product_repos[*]})"
pass "fact 2e: vm-kernel-stage-test.sh's awk strips exactly the product's Valve repos"

# =============================================================================
# FACT 3 -- retired: the firmware-collision regex pair is GONE
#
#   src/omarchy-deck-kernel.sh       colliding_arch_firmware() -- deleted
#   test/images/vm-neptune-image.sh  the inline swap -- must be deleted too
#
# linux-omarchy uses Arch's own linux-firmware, so there is no Valve firmware
# swap and nothing to collide with. Asserted ABSENT on both sides: a copy
# that survived on either side would claim a conflict resolution real Decks
# never hit (product side) or hand the VM suites a guest in a state the
# product would never produce (substrate side).
# =============================================================================

if grep -vE '^[[:space:]]*#' "$KERNEL" | grep -qE '^(colliding_arch_firmware\(\)|stage_firmware_swap\(\))'; then
  fail "FACT 3 DIVERGED (retirement): the firmware-collision probe survived" \
    "src/omarchy-deck-kernel.sh still defines a firmware-swap function, but stage_firmware_swap is retired -- linux-omarchy uses Arch's firmware, so there is nothing to collide with."
fi
pass "fact 3a: the product carries no firmware-collision probe"

if grep -vE '^[[:space:]]*#' "$BUILDER" | grep -qE 'colliding|linux-firmware-neptune|-Rdd'; then
  fail "FACT 3 DIVERGED (retirement): the substrate still performs a firmware swap" \
    "test/images/vm-neptune-image.sh still references a colliding/firmware-neptune/-Rdd swap. The guest must start from Arch firmware + linux-omarchy, the state the retired stage_firmware_swap leaves behind by never running."
fi
pass "fact 3b: the substrate performs no firmware swap"
# =============================================================================
# FACT 4 -- the Deck kernel package name
#
#   src/omarchy-deck-kernel.sh       KERNEL_PKG
#   test/images/vm-neptune-image.sh  KERNEL_PKG
#
# The substrate pre-installs a kernel; the product verifies one. If the two
# names drift, every VM suite tests the product's handling of a kernel that
# is not the one it ships -- and the failure surfaces as a missing UKI,
# which reads like a limine bug.
#
# Asserted EQUAL. A bare `./test/vm/...` run uses the substrate default,
# which is how the suites are always run by hand.
# =============================================================================

product_pkg=$(sed -nE 's/^readonly KERNEL_PKG="([^"]+)".*$/\1/p' "$KERNEL")
require_extract "the Deck kernel package (product side)" \
  "${KERNEL}: readonly KERNEL_PKG=\"<name>\"" 1 "$product_pkg"

substrate_pkg=$(sed -nE 's/^KERNEL_PKG=\$\{IMG_KERNEL_PKG:-([^}]+)\}.*$/\1/p' "$BUILDER")
require_extract "the Deck kernel package (test side)" \
  "${BUILDER}: KERNEL_PKG=\${IMG_KERNEL_PKG:-<name>}" 1 "$substrate_pkg"
[[ $product_pkg == "$substrate_pkg" ]] ||
  fail "FACT 4 DIVERGED: the Deck kernel package name" \
    "src/omarchy-deck-kernel.sh       KERNEL_PKG=${product_pkg}
test/images/vm-neptune-image.sh  KERNEL_PKG=${substrate_pkg}
The substrate would pre-install ${substrate_pkg} while the product verifies
${product_pkg}. Both names move together with the adopt decision."
pass "fact 4a: the substrate's kernel package matches the product's pin (${product_pkg})"

# 4b. No Neptune series DEFAULT or Neptune kernel CONSTRUCTOR may survive in
# code anywhere in the tree. Swept rather than listed so a reintroduced copy
# is caught the day it lands. Only two shapes count: `${...NEPTUNE_SERIES:-<digits>}`
# env defaults and `KERNEL_PKG="linux-neptune...` constructors -- prose
# mentions (retirement notes, assertion messages) are not code and do not
# match. This file itself is excluded: it must spell the patterns to sweep
# them.
mapfile -t series_code < <(
  grep -rEn --include='*.sh' 'NEPTUNE_SERIES:-|KERNEL_PKG="linux-neptune' \
    "$REPO_ROOT/src" "$REPO_ROOT/test" "$REPO_ROOT/tools" "$REPO_ROOT/iso" || true
)
mapfile -t series_code < <(
  printf '%s\n' "${series_code[@]:-}" | grep -v 'test-duplicated-upstream-facts.sh' || true
)
((${#series_code[@]} == 0)) ||
  fail "FACT 4 DIVERGED (retirement residue): Neptune defaults survive in code" \
    "these lines still default to a Neptune series or construct a Neptune package name:
  $(printf '%s\n' "${series_code[@]}" | sed "s|^${REPO_ROOT}/||")
Remove them or move the note into a comment."
pass "fact 4b: no Neptune series default or package constructor survives in code (src/test/tools/iso)"

printf 'all duplicated-upstream-fact tests passed\n'
