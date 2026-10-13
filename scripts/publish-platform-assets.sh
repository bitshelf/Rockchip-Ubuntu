#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

provider="${ASSET_PROVIDER:-}"
repository="${ASSET_REPOSITORY:-}"
tag="${ASSET_TAG:-}"
token="${ASSET_TOKEN:-}"
bundle="${PLATFORM_ASSET_BUNDLE:-}"
server="${ASSET_SERVER_URL:-}"
api="${ASSET_API_URL:-}"
target="${ASSET_TARGET_COMMIT:-}"

[[ "$provider" == github || "$provider" == forgejo ]] ||
    die "ASSET_PROVIDER must be github or forgejo"
[[ "$repository" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "invalid ASSET_REPOSITORY"
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid ASSET_TAG"
[[ -n "$token" || -n "${ASSET_AUTH_HEADER:-}" ]] || die "ASSET_TOKEN or ASSET_AUTH_HEADER is required"
[[ "$bundle" == /* && -s "$bundle" && -s "${bundle}.sha256" ]] ||
    die "PLATFORM_ASSET_BUNDLE and its checksum are required"
for tool in curl jq sha256sum; do
    command -v "$tool" >/dev/null || die "missing asset publish dependency: $tool"
done

(
    cd "$(dirname "$bundle")"
    sha256sum --quiet -c "$(basename "${bundle}.sha256")"
) || die "platform asset bundle checksum mismatch"

response="$(mktemp)"
payload="$(mktemp)"
trap 'rm -f -- "$response" "$payload"' EXIT
if [[ "$provider" == github ]]; then
    api="${api:-https://api.github.com}"
    auth=(--header "Authorization: Bearer ${token}" --header 'Accept: application/vnd.github+json')
else
    [[ "$server" == http://* || "$server" == https://* ]] ||
        die "ASSET_SERVER_URL is required for Forgejo"
    api="${api:-${server%/}/api/v1}"
    auth=(--header "Authorization: token ${token}" --header 'Accept: application/json')
fi
if [[ -n "${ASSET_AUTH_HEADER:-}" ]]; then
    auth=(--header "$ASSET_AUTH_HEADER" --header 'Accept: application/json')
fi

kind="${ASSET_UPLOAD_KIND:-release}"
[[ "$kind" == release || "$kind" == generic ]] || die "invalid ASSET_UPLOAD_KIND"
if [[ "$kind" == generic ]]; then
    [[ "$provider" == forgejo ]] || die "generic package upload requires Forgejo"
    package="${ASSET_PACKAGE_NAME:-ubuntu-platform-assets}"
    [[ "$package" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid ASSET_PACKAGE_NAME"
    base="${server%/}/api/packages/${repository%%/*}/generic/$package/$tag"
    for file in "$bundle" "${bundle}.sha256"; do
        name="$(basename "$file")"
        url="$base/$(jq -rn --arg value "$name" '$value|@uri')"
        status="$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "${auth[@]}" "$url")"
        if [[ "$status" == 404 ]]; then
            curl --fail --silent --show-error "${auth[@]}" --request PUT \
                --header 'Content-Type: application/octet-stream' --data-binary "@$file" "$url" >/dev/null
            curl --fail --silent --show-error "${auth[@]}" --output "$response" "$url"
        elif [[ "$status" != 200 ]]; then
            die "cannot query package asset (HTTP $status)"
        fi
        [[ "$(sha256sum "$response" | cut -d' ' -f1)" == "$(sha256sum "$file" | cut -d' ' -f1)" ]] ||
            die "remote package asset differs; refusing overwrite: $name"
        echo "Verified package asset: $url"
    done
    exit 0
fi

status="$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
    "${auth[@]}" "$api/repos/$repository/releases/tags/$tag")"
if [[ "$status" == 404 ]]; then
    jq -nc --arg tag "$tag" --arg target "$target" \
        '{tag_name:$tag,name:$tag,draft:false,prerelease:false}
         + (if $target == "" then {} else {target_commitish:$target} end)' >"$payload"
    curl --fail --silent --show-error --output "$response" \
        "${auth[@]}" --header 'Content-Type: application/json' \
        --data-binary "@$payload" "$api/repos/$repository/releases"
elif [[ "$status" != 200 ]]; then
    die "cannot query release $tag (HTTP $status)"
fi

release_id="$(jq -er '.id' "$response")"
for file in "$bundle" "${bundle}.sha256"; do
    name="$(basename "$file")"
    jq -e --arg name "$name" '.assets[]? | select(.name == $name)' "$response" >/dev/null &&
        die "release asset already exists and will not be overwritten: $name"
    if [[ "$provider" == github ]]; then
        upload_url="$(jq -er '.upload_url | sub("\\{.*$"; "")' "$response")"
    else
        upload_url="$api/repos/$repository/releases/$release_id/assets"
    fi
    upload_args=(--header 'Content-Type: application/octet-stream' --data-binary "@$file")
    if [[ "$provider" == forgejo ]]; then
        # Forgejo's release attachment API accepts the attachment form field.
        upload_args=(--form "attachment=@$file")
    fi
    curl --fail --silent --show-error "${auth[@]}" "${upload_args[@]}" \
        "${upload_url}?name=$(jq -rn --arg value "$name" '$value|@uri')" >/dev/null
    echo "Uploaded release asset: $name"
done
