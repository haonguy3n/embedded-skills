#!/usr/bin/env bash
# shellcheck disable=SC2329  # the step_* functions are called by name ("step_$s")
# The static-analysis gate: every step must report nothing; the script names the steps that did not and exits 1.
#
#   tools/check.sh                 every step
#   tools/check.sh tidy rules      only these: format tidy cppcheck rules python shell
#
# Needs clang-format and clang-tidy (with run-clang-tidy) from the system, and:  pip install cppcheck ruff shellcheck-py
# tidy and cppcheck read the compile database of a debug build: cmake --preset host-debug (CMAKE_EXPORT_COMPILE_COMMANDS).
# Adjust the variables below to the project. Self-checks (*/test/) are exempt from tidy's 30-line rule.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD:-$ROOT/build/host-debug}"        # where compile_commands.json is
read -ra SRC_DIRS <<< "${SRC_DIRS:-Libs Apps}"  # C++ source roots, relative to ROOT (space-separated)
THREAD_LIB="${THREAD_LIB:-Libs/Base}"           # the one place allowed to create threads
cd "$ROOT" || exit 1

failed=()
cpp_files() { git ls-files -- "${SRC_DIRS[@]}" | grep -E '\.(cpp|h)$'; }

step_format() {
    local bad
    bad=$(cpp_files | xargs -r clang-format --dry-run --Werror 2>&1 | grep -c 'error:' || true)
    [ "$bad" = 0 ]
}

step_tidy() {
    [ -f "$BUILD/compile_commands.json" ] || { echo "no $BUILD/compile_commands.json: configure a debug build"; return 1; }
    run-clang-tidy -quiet -p "$BUILD" "$(cpp_files | grep -v '/test/' | grep '\.cpp$' | paste -sd'|')" 2>/dev/null \
        | grep -E 'warning:|error:' && return 1 || return 0
}

step_cppcheck() {
    cppcheck --project="$BUILD/compile_commands.json" --enable=warning,performance,portability --inline-suppr \
        --error-exitcode=1 --quiet -i"$BUILD"
}

step_rules() {
    local ok=0
    # nothing throws (errors are std::expected)
    if git grep -nE '\bthrow\b' -- "${SRC_DIRS[@]}" ':!*/test/*' | grep -v NOLINT; then echo "rules: throw"; ok=1; fi
    # threads only from the threading library
    if git grep -nE 'std::(j)?thread\b|g_thread_new|pthread_create' -- "${SRC_DIRS[@]}" ":!$THREAD_LIB/*" ':!*/test/*'; then
        echo "rules: a thread outside $THREAD_LIB"; ok=1
    fi
    return "$ok"
}

step_python() { git ls-files '*.py' | xargs -r ruff check --quiet; }
step_shell() { git ls-files '*.sh' | xargs -r shellcheck; }

steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=(format tidy cppcheck rules python shell)
for s in "${steps[@]}"; do
    echo "== $s"
    "step_$s" || failed+=("$s")
done
if [ ${#failed[@]} -eq 0 ]; then echo "check: clean"; exit 0; fi
echo "check: findings in ${failed[*]}"
exit 1
