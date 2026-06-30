#!/usr/bin/env bash
set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:-3899/SimAdmin}"
TARGET_REPO="${TARGET_REPO:-${GITHUB_REPOSITORY:-6mb/SimAdmin}}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

release_rows="$tmp_dir/releases.b64"
latest_tag=""

if latest_json="$(gh release view --repo "$SOURCE_REPO" --json tagName 2>/dev/null)"; then
  latest_tag="$(jq -r '.tagName // ""' <<<"$latest_json")"
fi

echo "Syncing releases from $SOURCE_REPO to $TARGET_REPO"
echo "Source latest release: ${latest_tag:-unknown}"

gh api --paginate "repos/$SOURCE_REPO/releases?per_page=100" --jq '.[] | @base64' > "$release_rows"

if [ ! -s "$release_rows" ]; then
  echo "No source releases found."
  exit 0
fi

decode_release() {
  printf '%s' "$1" | base64 -d
}

release_exists() {
  local tag="$1"
  gh release view "$tag" --repo "$TARGET_REPO" >/dev/null 2>&1
}

json_bool_flag() {
  local value="$1"
  if [ "$value" = "true" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

retry() {
  local max_attempts="$1"
  shift
  local attempt=1

  until "$@"; do
    if [ "$attempt" -ge "$max_attempts" ]; then
      return 1
    fi

    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

# GitHub returns releases newest-first; create oldest-first so the final Latest
# marker naturally matches the upstream repository.
tac "$release_rows" | while IFS= read -r row; do
  release_json="$(decode_release "$row")"
  tag="$(jq -r '.tag_name' <<<"$release_json")"
  name="$(jq -r '.name // .tag_name' <<<"$release_json")"
  draft="$(jq -r '.draft' <<<"$release_json")"
  prerelease="$(jq -r '.prerelease' <<<"$release_json")"
  body_file="$tmp_dir/release-body-${tag//[^A-Za-z0-9._-]/_}.md"

  jq -r '.body // ""' <<<"$release_json" > "$body_file"

  echo "::group::Release $tag"

  if release_exists "$tag"; then
    echo "Updating release metadata for $tag"
    gh release edit "$tag" \
      --repo "$TARGET_REPO" \
      --title "$name" \
      --notes-file "$body_file" \
      "--draft=$(json_bool_flag "$draft")" \
      "--prerelease=$(json_bool_flag "$prerelease")"

    if [ -n "$latest_tag" ] && [ "$tag" = "$latest_tag" ] && [ "$draft" != "true" ] && [ "$prerelease" != "true" ]; then
      gh release edit "$tag" --repo "$TARGET_REPO" --latest
    fi
  else
    echo "Creating release $tag"
    create_args=(
      release create "$tag"
      --repo "$TARGET_REPO"
      --title "$name"
      --notes-file "$body_file"
      --verify-tag
    )

    if [ "$draft" = "true" ]; then
      create_args+=(--draft)
    fi

    if [ "$prerelease" = "true" ]; then
      create_args+=(--prerelease)
    fi

    if [ -n "$latest_tag" ] && [ "$tag" = "$latest_tag" ] && [ "$draft" != "true" ] && [ "$prerelease" != "true" ]; then
      create_args+=(--latest)
    else
      create_args+=(--latest=false)
    fi

    gh "${create_args[@]}"
  fi

  target_release_json="$(gh api "repos/$TARGET_REPO/releases/tags/$tag")"
  assets_dir="$tmp_dir/assets/${tag//[^A-Za-z0-9._-]/_}"
  mkdir -p "$assets_dir"

  jq -c '.assets[]?' <<<"$release_json" | while IFS= read -r asset_json; do
    asset_id="$(jq -r '.id' <<<"$asset_json")"
    asset_name="$(jq -r '.name' <<<"$asset_json")"
    asset_size="$(jq -r '.size' <<<"$asset_json")"
    asset_url="$(jq -r '.browser_download_url' <<<"$asset_json")"
    target_size="$(jq -r --arg name "$asset_name" '.assets[]? | select(.name == $name) | .size' <<<"$target_release_json" | head -n 1)"

    if [ -n "$target_size" ] && [ "$target_size" = "$asset_size" ]; then
      echo "Asset already current: $asset_name"
      continue
    fi

    asset_path="$assets_dir/$asset_name"
    echo "Downloading asset: $asset_name"
    rm -f "$asset_path"
    retry 5 curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o "$asset_path" "$asset_url"

    echo "Uploading asset: $asset_name"
    retry 5 gh release upload "$tag" "$asset_path" --repo "$TARGET_REPO" --clobber
  done

  echo "::endgroup::"
done

echo "Release sync complete."
