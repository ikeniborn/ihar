"""Live proof that a pinned vendor honours a hook decision (LLD 6.6)."""

LIVE_CASES = frozenset({
    "deny-blocks-the-tool",
    "rewrite-reaches-the-tool",
    "session-start-context",
    "mcp-matcher-fires",
    "timeout-behaviour",
})

ENVIRONMENT_REASONS = frozenset({
    "vendor-api-error",
    "vendor-quota-exhausted",
    "vendor-unauthenticated",
    "vendor-unreachable",
})

REQUIRED_CASES = {
    "claude": LIVE_CASES | {
        "sandbox-direct-write",
        "sandbox-child-write",
        "sandbox-workspace-write",
    },
    "codex": LIVE_CASES | {
        "hook-is-loaded",
        "trust-is-recordable",
        "tampering-is-detected",
    },
}
