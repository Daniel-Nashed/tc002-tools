#!/usr/bin/env bash
# Packages the root CA trust bundle curl needs for HTTPS (see
# runtime/on-demand-run.sh's CURL_CA_BUNDLE export) - and that OpenSSL's
# own CLI could use too, for a TLS-client role - as its OWN build step,
# independent of build_openssl.sh.
#
# This used to be a small side effect of build_openssl.sh's
# install_artifacts(): a plain "cp" of this container's own
# "ca-certificates" package (already installed for the container's own
# HTTPS needs - see build/docker/Dockerfile, build/setup_build_platform.sh)
# into OpenSSL's device/etc/ssl tree, on the reasoning that "anything
# needing a trust store here also needs OpenSSL, so tying the two together
# means nothing extra to remember to build." That stopped holding once
# OpenSSL (the CLI tool specifically - a genuinely optional, slow-to-
# compile component) became something an operator might reasonably decline
# to build at all: curl needs this bundle regardless, and producing it has
# ZERO dependency on actually cross-compiling OpenSSL - it is one "cp"
# from a package the container already has, nothing to configure/make/
# link. Splitting it out means declining the OpenSSL CLI does not silently
# break curl's HTTPS too - confirmed as a real, not hypothetical, failure
# mode: "mbedTLS: error reading CA cert file" on a real device where
# OpenSSL had not been (re)built after curl was.
#
# Uses this container's own OS trust store, not a bundle generated from
# Mozilla's own certdata.txt (which curl's upstream project separately
# publishes tooling for) - deliberately: the container's OS package may
# already carry roots an operator's own environment has injected (e.g. a
# corporate CA), and using it reflects whatever trust that build
# environment's owner actually configured, rather than a fixed generic
# list this project would otherwise have to regenerate and track itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Mirrors the real device path (/etc/ssl/certs/ca-certificates.crt),
# matching the device/ tree shape build_openssl.sh and build_nginx.sh
# already use - install/install_etc.sh's push_ca_bundle() pushes this
# straight to that path via push_etc_override().
DEVICE_DIR="${CA_BUNDLE_INSTALL_DIR}/etc/ssl/certs"

package_bundle()
{
  local system_ca_bundle="/etc/ssl/certs/ca-certificates.crt"

  test -f "$system_ca_bundle" \
    || die "${system_ca_bundle} not found in this container - is the ca-certificates package installed? (see build/docker/Dockerfile)"

  rm -rf "$CA_BUNDLE_INSTALL_DIR"
  mkdir -p "$DEVICE_DIR"
  cp "$system_ca_bundle" "${DEVICE_DIR}/ca-certificates.crt"

  log "packaged root CA bundle from ${system_ca_bundle} to ${DEVICE_DIR}/ca-certificates.crt"
}

write_manifest()
{
  local manifest="${CA_BUNDLE_INSTALL_DIR}/manifest-ca-bundle.json"
  local bundle="${DEVICE_DIR}/ca-certificates.crt"
  local built_at
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local commit
  commit="$(project_git_commit)"
  local sha256 cert_count
  sha256="$(sha256sum "$bundle" | cut -d' ' -f1)"
  cert_count="$(grep -c 'BEGIN CERTIFICATE' "$bundle")"

  {
    echo "{"
    echo "  \"built_at_utc\": \"${built_at}\","
    echo "  \"git_commit\": \"${commit}\","
    echo "  \"name\": \"ca-bundle\","
    echo "  \"source\": \"/etc/ssl/certs/ca-certificates.crt (container's ca-certificates package)\","
    echo "  \"device_path\": \"etc/ssl/certs/ca-certificates.crt\","
    echo "  \"certificate_count\": ${cert_count},"
    echo "  \"sha256\": \"${sha256}\""
    echo "}"
  } >"$manifest"

  log "wrote manifest: ${manifest}"
  dump_file "$manifest"
}

main()
{
  require_container
  require_cmd sha256sum

  header "ca-bundle: packaging root CA trust bundle"
  package_bundle
  write_manifest

  log_success "ca-bundle"
  log "ca-bundle build complete: ${CA_BUNDLE_INSTALL_DIR}"
}

main
