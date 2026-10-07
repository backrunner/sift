"""Additional absolute-memory evidence required by the mapped NeuralNetwork profile."""

PROFILE_ID = "nn-fp32-mapped-w4-block16"


def identitylookup_failures(report: dict) -> list[str]:
    if report.get("profileID") != PROFILE_ID:
        return []
    evidence = report.get("identityLookupEvidence", {})
    failures = []
    checks = {
        "identityLookupArtifact": evidence.get("artifactSHA256") == report.get("artifactSHA256")
            and bool(report.get("artifactSHA256")),
        "identityLookupEnvironment": evidence.get("environment") == "identitylookup-extension"
            and evidence.get("productionEngine") is True,
        "identityLookupCompletion": evidence.get("completed") is True
            and evidence.get("failedQueries") == 0,
        "identityLookupRunCounts": evidence.get("coldRunCount", 0) >= 30
            and evidence.get("warmQueryCount", 0) >= 10_000,
        "identityLookupActualSMS": evidence.get("completedIncomingSMSQueries", 0) >= 1,
    }
    peak = evidence.get("absoluteProcessPeakBytes", 0)
    budget = evidence.get("observedProcessBudgetBytes", 0)
    checks["identityLookupAbsoluteMemory"] = 0 < peak <= 20 * 1024 * 1024
    checks["identityLookupHeadroom"] = budget - peak >= 4 * 1024 * 1024
    # Preserve the initial cache growth separately. Measure drift across the
    # fixed second half of the stress run, rather than calling initialization
    # allocation a persistent leak or hiding it in a baseline-subtracted peak.
    window = evidence.get("steadyStateWindow", {})
    first = window.get("firstPhysicalFootprintBytes", 0)
    maximum = window.get("maximumPhysicalFootprintBytes", 0)
    checks["identityLookupMemoryWindow"] = (
        window.get("startQuery") == 5000 and window.get("endQuery") == 10_000
        and window.get("sampleCount", 0) >= 51 and first > 0 and maximum >= first
    )
    checks["identityLookupMemoryDrift"] = (
        first > 0 and 0 <= maximum - first <= min(16 * 1024 * 1024, first * 0.10)
    )
    for name, passed in checks.items():
        if not passed:
            failures.append(name)
    return failures
