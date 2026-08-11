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
#   3. The firmware-collision regex pair
#        src/omarchy-deck-kernel.sh  <->  test/images/vm-neptune-image.sh
#   4. The pinned Neptune series
#        src/omarchy-deck-kernel.sh  <->  test/images/vm-neptune-image.sh
#
# Each one is a place where the TEST can stay green after the PRODUCT has been
# fixed, or the product can be fixed while the test still asserts the old
# world. Nothing else in this repo compares them -- the substrate builder even
# says "same firmware swap omarchy-deck-kernel.sh's stage_firmware_swap
# performs" and "added the same way stage_repos adds them" in prose, which is
# a claim no code checks.
#
# Three of the four turned out to have MORE than two copies. Those extra copies
# are asserted here too, and flagged in the report, because a pair that is
# really a quintet is worse than the inventory recorded:
#
#   - the Neptune series default is repeated in three test/vm suites as well
#   - the Valve mirror's HOSTNAME is repeated in those same three suites'
#     network pre-check
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
# FACT 3 -- the firmware-collision regex pair
#
#   src/omarchy-deck-kernel.sh       colliding_arch_firmware()
#   test/images/vm-neptune-image.sh  the same two greps, inline
#
# One upstream fact: Valve's linux-firmware-neptune declares conflicts against
# `linux-firmware` and `linux-firmware-whence` only, not against Arch's ten
# split subpackages. Both copies encode it as an include regex and an exclude
# regex. Asserted EQUAL: the substrate is supposed to leave the guest in the
# state stage_firmware_swap leaves a Deck, and a narrower regex on the
# substrate side would leave collisions the product would have cleared -- so
# the VM run would exercise a conflict resolution real Decks never hit.
# =============================================================================

fw_fn=$(sed -n '/^colliding_arch_firmware()/,/^}/p' "$KERNEL")
require_extract "colliding_arch_firmware() (product side)" \
  "${KERNEL}: colliding_arch_firmware() { ... }" 3 "$fw_fn"

# grep_pattern <flags> <text> -- the single-quoted PATTERN of the first
# `grep <flags> '...'` in the text.
grep_pattern() {
  local flags=$1
  sed -nE "s/^.*grep ${flags} '([^']*)'.*\$/\1/p" | head -n 1
}

product_fw_include=$(grep_pattern -E <<<"$fw_fn")
product_fw_exclude=$(grep_pattern -vE <<<"$fw_fn")
require_extract "the firmware include regex (product side)" \
  "${KERNEL}: colliding_arch_firmware()'s \`grep -E\`" 1 "$product_fw_include"
require_extract "the firmware exclude regex (product side)" \
  "${KERNEL}: colliding_arch_firmware()'s \`grep -vE\`" 1 "$product_fw_exclude"

fw_lines=$(grep -c 'mapfile -t colliding' "$BUILDER" || true)
[[ $fw_lines -eq 1 ]] ||
  fail "EXTRACTION FAILED (ambiguous): the substrate's firmware swap" \
    "found ${fw_lines} 'mapfile -t colliding' lines in ${BUILDER}, expected exactly 1"
fw_line=$(grep 'mapfile -t colliding' "$BUILDER")
substrate_fw_include=$(grep_pattern -E <<<"$fw_line")
substrate_fw_exclude=$(grep_pattern -vE <<<"$fw_line")
require_extract "the firmware include regex (test side)" \
  "${BUILDER}: the \`grep -E\` on the mapfile line" 1 "$substrate_fw_include"
require_extract "the firmware exclude regex (test side)" \
  "${BUILDER}: the \`grep -vE\` on the mapfile line" 1 "$substrate_fw_exclude"
pass "all four halves of the firmware-collision regex pair extract"

[[ $product_fw_include == "$substrate_fw_include" ]] ||
  fail "FACT 3 DIVERGED: the firmware-collision INCLUDE regex" \
    "src/omarchy-deck-kernel.sh       colliding_arch_firmware() grep -E:
  ${product_fw_include}
test/images/vm-neptune-image.sh  its inline grep -E:
  ${substrate_fw_include}
These select which installed linux-firmware* packages collide with Valve's.
Different regexes mean the substrate hands the VM suites a guest in a state
stage_firmware_swap would never produce."
pass "fact 3a: both copies use the same include regex (${product_fw_include})"

[[ $product_fw_exclude == "$substrate_fw_exclude" ]] ||
  fail "FACT 3 DIVERGED: the firmware-collision EXCLUDE regex" \
    "src/omarchy-deck-kernel.sh       colliding_arch_firmware() grep -vE:
  ${product_fw_exclude}
test/images/vm-neptune-image.sh  its inline grep -vE:
  ${substrate_fw_exclude}
This is the half that spares Valve's own package and linux-firmware-whence.
A copy that spares less would have the substrate remove what the product
keeps (or the reverse), silently."
pass "fact 3b: both copies use the same exclude regex (${product_fw_exclude})"

# =============================================================================
# FACT 4 -- the pinned Neptune series
#
#   src/omarchy-deck-kernel.sh       NEPTUNE_SERIES_DEFAULT
#   test/images/vm-neptune-image.sh  IMG_NEPTUNE_SERIES default
#   + three test/vm suites, which the inventory did not record
#
# 611 is the one series validated on the operator's OLED Deck. The substrate
# pre-installs a kernel; the product installs one. If the two numbers drift,
# every VM suite tests the product's handling of a kernel that is not the one
# it ships -- and the failure surfaces as a missing UKI, which reads like a
# limine bug.
#
# Asserted EQUAL across every default in the repo. The VM suites' defaults are
# in scope because they are the values a bare `./test/vm/...` run uses, which
# is how they are always run by hand.
# =============================================================================

product_series=$(sed -nE 's/^readonly NEPTUNE_SERIES_DEFAULT=([0-9]+).*$/\1/p' "$KERNEL")
require_extract "the pinned Neptune series (product side)" \
  "${KERNEL}: readonly NEPTUNE_SERIES_DEFAULT=<digits>" 1 "$product_series"

substrate_series=$(sed -nE 's/^SERIES=\$\{IMG_NEPTUNE_SERIES:-([0-9]+)\}.*$/\1/p' "$BUILDER")
require_extract "the pinned Neptune series (test side)" \
  "${BUILDER}: SERIES=\${IMG_NEPTUNE_SERIES:-<digits>}" 1 "$substrate_series"
pass "both copies of the Neptune series pin extract (product ${product_series}, substrate ${substrate_series})"

[[ $product_series == "$substrate_series" ]] ||
  fail "FACT 4 DIVERGED: the pinned Neptune series" \
    "src/omarchy-deck-kernel.sh       NEPTUNE_SERIES_DEFAULT=${product_series}
test/images/vm-neptune-image.sh  IMG_NEPTUNE_SERIES default=${substrate_series}
The substrate would pre-install linux-neptune-${substrate_series} while the
product installs linux-neptune-${product_series}. Both numbers move together,
after validating on hardware (see the NEPTUNE_SERIES_DEFAULT header comment)."
pass "fact 4a: the substrate's series default matches the product's pin (${product_series})"

# 4b. Every other `*NEPTUNE_SERIES:-<digits>}` default in the tree. Swept
# rather than listed so a NEW copy is caught the day it is added.
mapfile -t series_defaults < <(
  grep -rEn --include='*.sh' '\$\{[A-Z_]*NEPTUNE_SERIES:-[0-9]+\}' \
    "$REPO_ROOT/src" "$REPO_ROOT/test" "$REPO_ROOT/tools" || true
)
require_extract "the repo-wide sweep for hard-coded series defaults" \
  "grep over src/ test/ tools/ for \${*NEPTUNE_SERIES:-<digits>}" 2 \
  "$(printf '%s\n' "${series_defaults[@]:-}")"
for hit in "${series_defaults[@]}"; do
  hit_series=$(sed -nE 's/^.*NEPTUNE_SERIES:-([0-9]+)\}.*$/\1/p' <<<"$hit")
  [[ -n $hit_series ]] ||
    fail "EXTRACTION FAILED: could not read the series out of a swept line" "$hit"
  [[ $hit_series == "$product_series" ]] ||
    fail "FACT 4 DIVERGED (further copy): a hard-coded Neptune series" \
      "src/omarchy-deck-kernel.sh pins ${product_series}; this line defaults to ${hit_series}:
  ${hit#"$REPO_ROOT"/}
Copies of this number: ${#series_defaults[@]} across the tree (grep for
'NEPTUNE_SERIES:-'). All of them move together with the pin."
done
pass "fact 4b: all ${#series_defaults[@]} hard-coded series defaults in the tree agree with the pin (${product_series})"

# 4c. The package-name shape either side builds around that number. The series
# is only half the fact; `linux-neptune-` is the other half, and a rename on
# one side would leave the numbers agreeing about nothing.
product_pkg=$(sed -nE 's/^readonly KERNEL_PKG="([^"$]*)\$\{NEPTUNE_SERIES\}".*$/\1/p' "$KERNEL")
substrate_pkg=$(sed -nE 's/^KERNEL_PKG="([^"$]*)\$\{SERIES\}".*$/\1/p' "$BUILDER")
require_extract "the kernel package prefix (product side)" \
  "${KERNEL}: readonly KERNEL_PKG=\"...\${NEPTUNE_SERIES}\"" 1 "$product_pkg"
require_extract "the kernel package prefix (test side)" \
  "${BUILDER}: KERNEL_PKG=\"...\${SERIES}\"" 1 "$substrate_pkg"
[[ $product_pkg == "$substrate_pkg" ]] ||
  fail "FACT 4 DIVERGED: the Neptune package-name prefix" \
    "src/omarchy-deck-kernel.sh       KERNEL_PKG prefix: ${product_pkg}
test/images/vm-neptune-image.sh  KERNEL_PKG prefix: ${substrate_pkg}
Both sides pin the same series number but build a different package name from
it, so the substrate installs one kernel and the product looks for another."
pass "fact 4c: both sides build the package name as '${product_pkg}<series>'"

printf 'all duplicated-upstream-fact tests passed\n'
