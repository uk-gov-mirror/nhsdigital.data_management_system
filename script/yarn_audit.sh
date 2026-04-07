#!/bin/bash
# Script yarn_audit.sh
# Runs a yarn audit, but ignores accepted yarn warnings, and pretty-prints errors in JSON
case "$1" in
    upgrade)
        echo Updating yarn packages
        rm -rf vendor/npm-packages-offline-cache
        yarn cache clean
        yarn upgrade
        echo Any yarn file changes will be in: vendor/npm-packages-offline-cache/ yarn.lock
        exit
        ;;
    audit | "")
        # Default behaviour: fall through
        SHOW_USAGE=0
        ;;
    *)
        SHOW_USAGE=1
        ;;
esac

if [ "$SHOW_USAGE" = "1" ]; then
    echo "Usage: `basename "$0"` [audit]  # runs yarn audit, ignoring accepted warnings"
    echo "       `basename "$0"` upgrade  # runs yarn upgrade and updates vendor/npm-packages-offline-cache/"
    echo "       `basename "$0"` help     # displays this message"
    if [ "$1" = "help" ] || [ "$1" = "-help" ] || [ "$1" = "--help" ]; then
        exit 0
    else
        echo "Error: Unknown arguments" >&2
        exit 1
    fi
fi

# YARN_IGNORE is a list of accepted yarn warnings:
YARN_IGNORE=()
# Path traversal in webpack-dev-middleware
YARN_IGNORE+=(GHSA-wr3j-pwj9-hqq6)
# Uncontrolled resource consumption in braces
YARN_IGNORE+=(GHSA-grv7-fg5c-xmjg)
# Denial of service in http-proxy-middleware
YARN_IGNORE+=(GHSA-c7qv-q95q-8v27)
# Improper Verification of Cryptographic Signature in node-forge
YARN_IGNORE+=(GHSA-x4jg-mjrx-434g GHSA-cfm4-qjh2-4765)
# node-forge has ASN.1 Unbounded Recursion
YARN_IGNORE+=(GHSA-554w-wpv2-vw27)
# node-forge has an Interpretation Conflict vulnerability via its ASN.1 Validator Desynchronization
YARN_IGNORE+=(GHSA-5gfm-wpxj-wjgq)
# Inefficient Regular Expression Complexity in nth-check
YARN_IGNORE+=(GHSA-rp65-9cf3-cjxr)
# ip SSRF improper categorization in isPublic
YARN_IGNORE+=(GHSA-2p57-rm9w-gvfp)
# node-tar is Vulnerable to Arbitrary File Overwrite and Symlink Poisoning via Insufficient Path Sanitization
YARN_IGNORE+=(GHSA-8qq5-rm4j-mr97)
# Race Condition in node-tar Path Reservations via Unicode Ligature Collisions on macOS APFS
YARN_IGNORE+=(GHSA-r6q2-hw4h-h46w)
# node-tar Vulnerable to Arbitrary File Creation/Overwrite via Hardlink Path Traversal
YARN_IGNORE+=(GHSA-34x7-hfp2-rc4v)
# Arbitrary File Read/Write via Hardlink Target Escape Through Symlink Chain in node-tar Extraction
YARN_IGNORE+=(GHSA-83g3-92jg-28cx)
# tar has Hardlink Path Traversal via Drive-Relative Linkpath
YARN_IGNORE+=(GHSA-qffp-2rhf-9h96)
# node-tar Symlink Path Traversal via Drive-Relative Linkpath
YARN_IGNORE+=(GHSA-9ppj-qmqm-q256)
# Serialize JavaScript is Vulnerable to RCE via RegExp.flags and Date.prototype.toISOString()
YARN_IGNORE+=(GHSA-5c6j-r48x-rmvq)
# Forge has a basicConstraints bypass in its certificate chain verification (RFC 5280 violation)
YARN_IGNORE+=(GHSA-2328-f5f3-gj25)
# Forge has signature forgery in Ed25519 due to missing S > L check
YARN_IGNORE+=(GHSA-q67f-28xg-22rw)
# Forge has Denial of Service via Infinite Loop in BigInteger.modInverse() with Zero Input
YARN_IGNORE+=(GHSA-5m6q-g25r-mvwx)
# Forge has signature forgery in RSA-PKCS due to ASN.1 extra field
YARN_IGNORE+=(GHSA-ppp5-5v6c-4jwp)

YARN_IGNORE_JSON="`echo ${YARN_IGNORE[@]} | sed -e 's/^/"/' -e 's/$/"/' -e 's/ /", "/g'`"
echo "yarn audit --no-progress --level high --json"
yarn audit --no-progress --level high --json > yarn_audit.json || true
echo
echo "Summary counts of vulnerabilities found, before filtering accepted warnings:"
cat yarn_audit.json | jq -c 'select ( .type == "auditSummary" )' | jq -M

echo
echo "Filtering for new high or critical severity warnings:"
for IGNORE in ${YARN_IGNORE[@]}; do
    cat yarn_audit.json | \
        jq -cMe 'select ( .type == "auditAdvisory" and (.data.advisory.github_advisory_id == "'"$IGNORE"'") )' > /dev/null || \
        echo "Warning: yarn audit no longer flags github_advisory_id $IGNORE"
done

if cat yarn_audit.json | jq -c 'select ( .type == "auditAdvisory" and (.data.advisory.github_advisory_id | IN ('"$YARN_IGNORE_JSON"') | not) )' | jq -Me; then
   echo
   echo Warning: New yarn audit vulnerabilities found in yarn.lock, listed above.
   echo Run script/yarn_audit.sh upgrade, or update YARN_IGNORE in
   echo script/yarn_audit.sh with accepted github_advisory_id values.
   echo e.g. by running:
   echo "$0 | grep -e title -e github_advisory_id | sed -E -e 's/^ *\"title\": \"(.*)\",\$/# \\1/' -e 's/^ *\"github_advisory_id\": \"(.*)\",/YARN_IGNORE+=(\\1)/'"
   exit 1
else
   rm -f yarn_audit.json
   echo No new yarn audit vulnerabilities found
fi
