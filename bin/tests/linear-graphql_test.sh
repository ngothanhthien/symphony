#!/usr/bin/env bash
#
# Shell-level regression test for `linear-graphql`.
#
# Verifies the read-only guard:
#   * plain query passes the guard and reaches the network call
#   * mutation and subscription are blocked (exit 6)
#   * leading comment / leading fragment before a write is also blocked
#
# We do not need a real Linear API — the guard runs before the curl
# call, so we can assert on the exit code and stderr text alone.
#
# Usage: bash bin/tests/linear-graphql_test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="${SCRIPT_DIR}/symphony-claude-tools/linear-graphql"

if [[ ! -x "$TOOL" ]]; then
  echo "FAIL: $TOOL is not executable" >&2
  exit 1
fi

failures=0

assert_exit() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL [$label]: expected exit $expected, got $actual" >&2
    failures=$((failures + 1))
  else
    echo "PASS [$label]"
  fi
}

assert_stderr_contains() {
  local label="$1" needle="$2" haystack="$3"
  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL [$label]: stderr did not contain $needle" >&2
    echo "----- stderr -----" >&2
    echo "$haystack" >&2
    echo "------------------" >&2
    failures=$((failures + 1))
  else
    echo "PASS [$label]"
  fi
}

export LINEAR_API_KEY="test-token-shouldnt-reach-curl"

run_tool() {
  local query="$1"
  set +e
  out=$("$TOOL" --query "$query" 2>&1)
  rc=$?
  set -e
  echo "$out"
  return $rc
}

# 1) Plain query — guard should NOT block. We expect a network failure
#    (exit 4) because the fake token cannot reach a real Linear API;
#    what we are really testing is that the guard did not exit 6.
set +e
plain_query_out=$("$TOOL" --query "query Viewer { viewer { id } }" 2>&1)
plain_query_rc=$?
set -e
assert_exit "plain query not blocked by guard" "4" "$plain_query_rc"

# 2) Mutation — should be blocked.
set +e
mutation_out=$("$TOOL" --query "mutation M { issueUpdate(id: \"x\", input: {}) { success } }" 2>&1)
mutation_rc=$?
set -e
assert_exit "mutation blocked" "6" "$mutation_rc"
assert_stderr_contains "mutation stderr" "Linear write operations are blocked" "$mutation_out"

# 3) Subscription — should be blocked.
set +e
sub_out=$("$TOOL" --query "subscription S { issueUpdates { id } }" 2>&1)
sub_rc=$?
set -e
assert_exit "subscription blocked" "6" "$sub_rc"
assert_stderr_contains "subscription stderr" "Linear write operations are blocked" "$sub_out"

# 4) Mutation preceded by a # comment — should still be blocked.
set +e
comment_out=$("$TOOL" --query $'# explanatory comment\nmutation M { commentCreate(input: {}) { success } }' 2>&1)
comment_rc=$?
set -e
assert_exit "mutation after leading comment blocked" "6" "$comment_rc"

# 5) Fragment before mutation — should still be blocked.
set +e
frag_out=$("$TOOL" --query $'fragment F on Issue { id }\nmutation M { issueUpdate(id: \"x\", input: {}) { success } }' 2>&1)
frag_rc=$?
set -e
assert_exit "fragment-then-mutation blocked" "6" "$frag_rc"

# 6) Query with a leading comment that is a real query — should pass
#    the guard (and fail with network error code 4 as before).
set +e
qcomment_out=$("$TOOL" --query $'# read-only comment\nquery Viewer { viewer { id } }' 2>&1)
qcomment_rc=$?
set -e
assert_exit "query after leading comment not blocked" "4" "$qcomment_rc"

# 7) Compact form `mutation{...}` with no whitespace before the brace —
#    the operation keyword is a whole word but the next non-comment
#    character is `{`, not whitespace. The guard must still match.
set +e
compact_mutation_out=$("$TOOL" --query 'mutation{ issueUpdate(id: "x", input: {}) { success } }' 2>&1)
compact_mutation_rc=$?
set -e
assert_exit "compact mutation blocked" "6" "$compact_mutation_rc"
assert_stderr_contains "compact mutation stderr" "Linear write operations are blocked" "$compact_mutation_out"

# 8) Compact form `subscription{...}` — same boundary, different keyword.
set +e
compact_sub_out=$("$TOOL" --query 'subscription{ issueUpdates { id } }' 2>&1)
compact_sub_rc=$?
set -e
assert_exit "compact subscription blocked" "6" "$compact_sub_rc"

# 9) Identifiers like `mutationLog` must NOT trip the guard. The left
#    boundary is a non-word character only, so a keyword embedded in a
#    longer identifier does not match.
set +e
identifier_out=$("$TOOL" --query 'query Q { viewer { id } mutationLog }' 2>&1)
identifier_rc=$?
set -e
assert_exit "mutationLog identifier not blocked" "4" "$identifier_rc"

if [[ "$failures" -gt 0 ]]; then
  echo "FAIL: $failures assertion(s) failed" >&2
  exit 1
fi

echo "OK: all linear-graphql guard assertions passed"
