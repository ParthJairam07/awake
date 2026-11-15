#!/bin/bash
# The temporary keychain the Release workflow signs from.
#
#   signing-keychain.sh create KEYCHAIN
#     Reads the Developer ID certificate from the environment:
#       APPLE_CERTIFICATE_P12       the .p12 export, base64 encoded
#       APPLE_CERTIFICATE_PASSWORD  the password of that export
#     Creates KEYCHAIN with a random password, imports the certificate so
#     that codesign may use its key without a prompt, puts KEYCHAIN first in
#     the user's keychain search list, and prints the SHA-1 hash of the
#     "Developer ID Application" identity in it as the only line on stdout.
#     Everything else goes to stderr. The certificate never touches a file
#     outside KEYCHAIN's folder, and that file is removed before returning.
#
#   signing-keychain.sh remove KEYCHAIN
#     Takes KEYCHAIN out of the search list and deletes it. Safe to run when
#     create failed half-way or never ran.
#
# The login keychain is never written to. Nothing here runs on a
# contributor's machine: build-app.sh only signs with an identity when it is
# given --sign-identity.
set -euo pipefail

SECURITY=/usr/bin/security
OPENSSL=/usr/bin/openssl
BASE64=/usr/bin/base64

usage() { echo "usage: $0 create|remove KEYCHAIN" >&2; }
[[ $# -eq 2 && -n "$2" ]] || { usage; exit 2; }
ACTION="$1"
KEYCHAIN="$2"

# The user's search list without KEYCHAIN, one path per line. `security
# list-keychains` prints each path in double quotes with leading spaces.
other_keychains() {
  "$SECURITY" list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' | grep -vxF "$KEYCHAIN" || true
}

# Sets the search list to $1 (may be empty) followed by the other keychains.
set_search_list() {
  local first="$1" line
  local list=()
  [[ -n "$first" ]] && list+=("$first")
  while IFS= read -r line; do
    [[ -n "$line" ]] && list+=("$line")
  done <<< "$(other_keychains)"
  # ${arr[@]+"${arr[@]}"}: an empty array expands to nothing under set -u
  # on the bash 3.2 that ships with macOS.
  "$SECURITY" list-keychains -d user -s ${list[@]+"${list[@]}"} >&2
}

case "$ACTION" in
  create)
    if [[ -z "${APPLE_CERTIFICATE_P12:-}" || -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]]; then
      echo "APPLE_CERTIFICATE_P12 and APPLE_CERTIFICATE_PASSWORD must both be set" >&2
      exit 1
    fi
    if [[ -e "$KEYCHAIN" ]]; then
      echo "$KEYCHAIN already exists; refusing to reuse it" >&2
      exit 1
    fi
    password="$("$OPENSSL" rand -hex 24)"
    certificate="$KEYCHAIN.p12"
    trap 'rm -f "$certificate"' EXIT
    ( umask 077; printf '%s' "$APPLE_CERTIFICATE_P12" | "$BASE64" --decode > "$certificate" )
    if [[ ! -s "$certificate" ]]; then
      echo "APPLE_CERTIFICATE_P12 did not decode to anything; it must be the base64 of the .p12 export" >&2
      exit 1
    fi
    "$SECURITY" create-keychain -p "$password" "$KEYCHAIN" >&2
    # No auto-lock while the job runs (the default locks after 5 minutes).
    "$SECURITY" set-keychain-settings "$KEYCHAIN" >&2
    "$SECURITY" unlock-keychain -p "$password" "$KEYCHAIN" >&2
    if ! "$SECURITY" import "$certificate" -f pkcs12 -P "$APPLE_CERTIFICATE_PASSWORD" -k "$KEYCHAIN" -T /usr/bin/codesign >&2; then
      echo "could not import the certificate: check APPLE_CERTIFICATE_PASSWORD and that the .p12 holds the certificate and its private key" >&2
      exit 1
    fi
    # Lets codesign use the key without the "allow access" dialog, which
    # nobody can click on a runner.
    "$SECURITY" set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$KEYCHAIN" >/dev/null
    set_search_list "$KEYCHAIN"
    identity="$("$SECURITY" find-identity -v -p codesigning "$KEYCHAIN" | awk '/"Developer ID Application: / { print $2; exit }')"
    if [[ ! "$identity" =~ ^[0-9A-F]{40}$ ]]; then
      echo "no valid \"Developer ID Application\" identity in the imported certificate. What it holds:" >&2
      "$SECURITY" find-identity -p codesigning "$KEYCHAIN" >&2 || true
      echo "Export the Developer ID Application certificate together with its private key (docs/releasing.md)." >&2
      exit 1
    fi
    echo "$identity"
    ;;
  remove)
    set_search_list ""
    if [[ -e "$KEYCHAIN" ]]; then
      "$SECURITY" delete-keychain "$KEYCHAIN" >&2
    fi
    rm -f "$KEYCHAIN.p12"
    ;;
  *) usage; exit 2 ;;
esac
