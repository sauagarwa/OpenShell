#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Sandbox security enforcement test.
# Run from inside a sandbox that has the restrictive policy loaded.
#
# Usage:
#   openshell sandbox connect <name>
#   # then paste or run this script inside the sandbox

set -euo pipefail

PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2"
    shift 2
    local output rc=0
    output=$("$@" 2>&1) || rc=$?

    if [ "$expected" = "pass" ] && [ "$rc" -eq 0 ]; then
        echo "  ✅ PASS: $desc"
        ((PASS++))
    elif [ "$expected" = "fail" ] && [ "$rc" -ne 0 ]; then
        echo "  ✅ PASS: $desc (correctly denied)"
        ((PASS++))
    else
        echo "  ❌ FAIL: $desc (expected=$expected, rc=$rc)"
        echo "         output: ${output:0:120}"
        ((FAIL++))
    fi
}

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║       OpenShell Sandbox Security Test                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Network policy tests ──────────────────────────────────
echo "── Network Policy (supervisor proxy + OPA) ──"

echo ""
echo "  [Allowed endpoint: api.github.com GET]"
check "GET api.github.com/zen" pass \
    curl -sS --max-time 10 https://api.github.com/zen

echo ""
echo "  [Blocked: POST to allowed endpoint (L7 read-only)]"
check "POST api.github.com (L7 block)" fail \
    curl -sS --max-time 10 -X POST \
    https://api.github.com/repos/octocat/hello-world/issues \
    -H "Content-Type: application/json" -d '{"title":"test"}'

echo ""
echo "  [Blocked: endpoint not in policy]"
check "GET google.com (not in policy)" fail \
    curl -sS --max-time 10 https://www.google.com

echo ""
echo "  [Blocked: different endpoint not in policy]"
check "GET pypi.org (not in policy)" fail \
    curl -sS --max-time 10 https://pypi.org/simple/

# ── Filesystem policy tests (Landlock) ────────────────────
echo ""
echo "── Filesystem Policy (Landlock LSM) ──"

echo ""
echo "  [Allowed: write to /tmp]"
check "Write to /tmp/test-file" pass \
    bash -c 'echo "test" > /tmp/sandbox-security-test && cat /tmp/sandbox-security-test && rm /tmp/sandbox-security-test'

echo ""
echo "  [Allowed: write to /sandbox]"
check "Write to /sandbox/test-file" pass \
    bash -c 'echo "test" > /sandbox/sandbox-security-test && cat /sandbox/sandbox-security-test && rm /sandbox/sandbox-security-test'

echo ""
echo "  [Allowed: read from /etc]"
check "Read /etc/hostname" pass \
    cat /etc/hostname

echo ""
echo "  [Allowed: read from /usr]"
check "Read /usr/bin/curl (exists)" pass \
    test -f /usr/bin/curl

echo ""
echo "  [Blocked: write to /etc]"
check "Write to /etc (read-only)" fail \
    bash -c 'echo "hack" > /etc/sandbox-test 2>&1'

echo ""
echo "  [Blocked: write to /usr]"
check "Write to /usr (read-only)" fail \
    bash -c 'echo "hack" > /usr/sandbox-test 2>&1'

echo ""
echo "  [Blocked: write to /var/log]"
check "Write to /var/log (read-only)" fail \
    bash -c 'echo "hack" > /var/log/sandbox-test 2>&1'

# ── Summary ───────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
    echo "  ✅ All tests passed — sandbox enforcement verified"
else
    echo "  ⚠️  Some tests failed — review output above"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
