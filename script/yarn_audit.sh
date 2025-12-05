#!/bin/bash
# Script yarn_audit.sh
# Runs a yarn audit, but ignores accepted yarn warnings, and pretty-prints errors in JSON

# YARN_IGNROE is a list of accepted yarn warnings, space separated:
# Path traversal in webpack-dev-middleware
YARN_IGNORE="GHSA-wr3j-pwj9-hqq6"
# Uncontrolled resource consumption in braces
YARN_IGNORE="$YARN_IGNORE GHSA-grv7-fg5c-xmjg"
# Denial of service in http-proxy-middleware
YARN_IGNORE="$YARN_IGNORE GHSA-c7qv-q95q-8v27"
# Improper Verification of Cryptographic Signature in node-forge
YARN_IGNORE="$YARN_IGNORE GHSA-x4jg-mjrx-434g GHSA-cfm4-qjh2-4765"
# node-forge has ASN.1 Unbounded Recursion
YARN_IGNORE="$YARN_IGNORE GHSA-554w-wpv2-vw27"
# node-forge has an Interpretation Conflict vulnerability via its ASN.1 Validator Desynchronization
YARN_IGNORE="$YARN_IGNORE GHSA-5gfm-wpxj-wjgq"
# Inefficient Regular Expression Complexity in nth-check"
YARN_IGNORE="$YARN_IGNORE GHSA-rp65-9cf3-cjxr"
# ip SSRF improper categorization in isPublic
YARN_IGNORE="$YARN_IGNORE GHSA-2p57-rm9w-gvfp"

YARN_IGNORE_JSON="`echo $YARN_IGNORE | sed -e 's/^/"/' -e 's/$/"/' -e 's/ /", "/g'`"
echo "yarn audit --no-progress --level high --json"
yarn audit --no-progress --level high --json > yarn_audit.json || true
echo
echo "Summary counts of vulnerabilities found, before filtering accepted warnings:"
cat yarn_audit.json | jq -c 'select ( .type == "auditSummary" )' | jq -M

echo
echo "Filtering for new high or critical severity warnings:"
for IGNORE in $YARN_IGNORE; do
    cat yarn_audit.json | \
        jq -cMe 'select ( .type == "auditAdvisory" and (.data.advisory.github_advisory_id == "'"$IGNORE"'") )' > /dev/null || \
        echo "Warning: yarn audit no longer flags github_advisory_id $IGNORE"
done

if cat yarn_audit.json | jq -c 'select ( .type == "auditAdvisory" and (.data.advisory.github_advisory_id | IN ('"$YARN_IGNORE_JSON"') | not) )' | jq -Me; then
   echo
   echo Warning: New yarn audit vulnerabilities found in yarn.lock, listed above.
   echo Run yarn upgrade, or update YARN_IGNORE in script/yarn_audit.sh
   echo with accepted github_advisory_id values.
   exit 1
else
   rm -f yarn_audit.json
   echo No new yarn audit vulnerabilities found
fi
