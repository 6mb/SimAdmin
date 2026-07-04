#!/usr/bin/env bash
set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:-3899/SimAdmin}"
TARGET_REPO="${TARGET_REPO:-${GITHUB_REPOSITORY:-6mb/SimAdmin}}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
BACKUP_PREFIX="${BACKUP_PREFIX:-backups}"
MIN_TREE_ENTRIES="${MIN_TREE_ENTRIES:-50}"
MIN_TAG_COUNT="${MIN_TAG_COUNT:-1}"
MIN_RELEASE_COUNT="${MIN_RELEASE_COUNT:-1}"
REQUIRED_PATHS="${REQUIRED_PATHS:-README.md backend frontend static}"

die() {
  echo "::error::$*"
  exit 1
}

notice() {
  echo "::notice::$*"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"
}

require_tool gh
require_tool git
require_tool jq
require_tool curl

if [ -z "${GH_TOKEN:-}" ]; then
  die "GH_TOKEN is required."
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

repo_json="$(gh api "repos/$SOURCE_REPO" 2>/dev/null)" || die "Upstream repo is not reachable: $SOURCE_REPO"
source_branch="$(jq -r '.default_branch // empty' <<<"$repo_json")"
[ -n "$source_branch" ] || die "Upstream default branch is empty."

branch_json="$(gh api "repos/$SOURCE_REPO/branches/$source_branch" 2>/dev/null)" || die "Upstream default branch is not reachable: $source_branch"
source_sha="$(jq -r '.commit.sha // empty' <<<"$branch_json")"
[ -n "$source_sha" ] || die "Upstream branch SHA is empty."

tree_json="$(gh api "repos/$SOURCE_REPO/git/trees/$source_sha?recursive=1" 2>/dev/null)" || die "Cannot inspect upstream tree."
tree_truncated="$(jq -r '.truncated // false' <<<"$tree_json")"
[ "$tree_truncated" != "true" ] || die "Upstream tree is truncated; refusing to mirror without a full health check."

tree_entries="$(jq '.tree | length' <<<"$tree_json")"
if [ "$tree_entries" -lt "$MIN_TREE_ENTRIES" ]; then
  die "Upstream tree is too small ($tree_entries entries, minimum $MIN_TREE_ENTRIES)."
fi

for required_path in $REQUIRED_PATHS; do
  if ! jq -e --arg path "$required_path" '.tree[] | select(.path == $path)' >/dev/null <<<"$tree_json"; then
    die "Upstream health check failed; missing required path: $required_path"
  fi
done

notice "Upstream is healthy: $SOURCE_REPO@$source_sha ($tree_entries tree entries)."

work_repo="$tmp_dir/repo"
git init "$work_repo" >/dev/null
cd "$work_repo"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git remote add upstream "https://github.com/$SOURCE_REPO.git"
git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/$TARGET_REPO.git"

git fetch --no-tags upstream "+refs/heads/$source_branch:refs/remotes/upstream/$source_branch"
fetched_sha="$(git rev-parse "refs/remotes/upstream/$source_branch")"
[ "$fetched_sha" = "$source_sha" ] || die "Fetched SHA does not match GitHub API SHA."

target_head_file="$tmp_dir/target-head.txt"
target_sha=""
if git ls-remote --exit-code --heads origin "$TARGET_BRANCH" > "$target_head_file" 2>/dev/null; then
  target_sha="$(awk '{print $1}' "$target_head_file" | head -n 1)"
fi

if [ "$target_sha" = "$source_sha" ]; then
  notice "$TARGET_REPO:$TARGET_BRANCH is already at upstream SHA $source_sha."
else
  if [ -n "$target_sha" ]; then
    git fetch --no-tags origin "+refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH"
    backup_ref="refs/heads/$BACKUP_PREFIX/$TARGET_BRANCH/$(date -u +%Y%m%d-%H%M%S)"
    notice "Saving current $TARGET_BRANCH ($target_sha) to $backup_ref before mirror push."
    git push origin "$target_sha:$backup_ref"
    git push origin "--force-with-lease=refs/heads/$TARGET_BRANCH:$target_sha" "$source_sha:refs/heads/$TARGET_BRANCH"
  else
    notice "Creating $TARGET_REPO:$TARGET_BRANCH from upstream SHA $source_sha."
    git push origin "$source_sha:refs/heads/$TARGET_BRANCH"
  fi
fi

source_tags="$tmp_dir/source-tags.tsv"
target_tags="$tmp_dir/target-tags.tsv"
source_tag_refs="$tmp_dir/source-tag-refs.txt"
target_tag_refs="$tmp_dir/target-tag-refs.txt"

git ls-remote --tags upstream | awk 'index($2, "^{}") == 0 {print $2 "\t" $1}' | sort > "$source_tags"
git ls-remote --tags origin | awk 'index($2, "^{}") == 0 {print $2 "\t" $1}' | sort > "$target_tags"
cut -f1 "$source_tags" > "$source_tag_refs"
cut -f1 "$target_tags" > "$target_tag_refs"

source_tag_count="$(wc -l < "$source_tags" | tr -d ' ')"
if [ "$source_tag_count" -lt "$MIN_TAG_COUNT" ]; then
  die "Upstream tag count is too small ($source_tag_count, minimum $MIN_TAG_COUNT)."
fi

while IFS=$'\t' read -r tag_ref tag_sha; do
  [ -n "$tag_ref" ] || continue
  current_sha="$(awk -F '\t' -v ref="$tag_ref" '$1 == ref {print $2}' "$target_tags" | head -n 1)"
  if [ "$current_sha" = "$tag_sha" ]; then
    continue
  fi

  notice "Mirroring tag $tag_ref."
  git fetch --no-tags upstream "+$tag_ref:$tag_ref"
  git push --force origin "$tag_ref:$tag_ref"
done < "$source_tags"

while IFS= read -r tag_ref; do
  [ -n "$tag_ref" ] || continue
  if grep -Fxq "$tag_ref" "$source_tag_refs"; then
    continue
  fi

  notice "Deleting target-only tag $tag_ref."
  git push origin ":$tag_ref"
done < "$target_tag_refs"

source_release_rows="$tmp_dir/source-releases.b64"
target_release_rows="$tmp_dir/target-releases.b64"
source_release_tags="$tmp_dir/source-release-tags.txt"
target_release_tags="$tmp_dir/target-release-tags.txt"

gh api --paginate "repos/$SOURCE_REPO/releases?per_page=100" --jq '.[] | @base64' > "$source_release_rows"
gh api --paginate "repos/$TARGET_REPO/releases?per_page=100" --jq '.[] | @base64' > "$target_release_rows"

source_release_count="$(wc -l < "$source_release_rows" | tr -d ' ')"
if [ "$source_release_count" -lt "$MIN_RELEASE_COUNT" ]; then
  die "Upstream release count is too small ($source_release_count, minimum $MIN_RELEASE_COUNT)."
fi

latest_tag=""
if latest_json="$(gh release view --repo "$SOURCE_REPO" --json tagName 2>/dev/null)"; then
  latest_tag="$(jq -r '.tagName // empty' <<<"$latest_json")"
fi

> "$source_release_tags"
while IFS= read -r row; do
  [ -n "$row" ] || continue
  printf '%s' "$row" | base64 -d | jq -r '.tag_name' >> "$source_release_tags"
done < "$source_release_rows"

> "$target_release_tags"
while IFS= read -r row; do
  [ -n "$row" ] || continue
  printf '%s' "$row" | base64 -d | jq -r '.tag_name' >> "$target_release_tags"
done < "$target_release_rows"

while IFS= read -r row; do
  [ -n "$row" ] || continue
  target_release_json="$(printf '%s' "$row" | base64 -d)"
  target_release_id="$(jq -r '.id' <<<"$target_release_json")"
  target_release_tag="$(jq -r '.tag_name' <<<"$target_release_json")"

  if grep -Fxq "$target_release_tag" "$source_release_tags"; then
    continue
  fi

  notice "Deleting target-only release $target_release_tag."
  gh api -X DELETE "repos/$TARGET_REPO/releases/$target_release_id"
done < "$target_release_rows"

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

json_bool_flag() {
  if [ "$1" = "true" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

tac "$source_release_rows" | while IFS= read -r row; do
  [ -n "$row" ] || continue
  release_json="$(printf '%s' "$row" | base64 -d)"
  tag="$(jq -r '.tag_name' <<<"$release_json")"
  name="$(jq -r '.name // .tag_name' <<<"$release_json")"
  draft="$(jq -r '.draft' <<<"$release_json")"
  prerelease="$(jq -r '.prerelease' <<<"$release_json")"
  body_file="$tmp_dir/release-body-${tag//[^A-Za-z0-9._-]/_}.md"
  assets_dir="$tmp_dir/assets/${tag//[^A-Za-z0-9._-]/_}"
  mkdir -p "$assets_dir"

  jq -r '.body // ""' <<<"$release_json" > "$body_file"

  if gh release view "$tag" --repo "$TARGET_REPO" >/dev/null 2>&1; then
    notice "Updating release $tag."
    gh release edit "$tag" \
      --repo "$TARGET_REPO" \
      --title "$name" \
      --notes-file "$body_file" \
      "--draft=$(json_bool_flag "$draft")" \
      "--prerelease=$(json_bool_flag "$prerelease")"
  else
    notice "Creating release $tag."
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

    gh "${create_args[@]}"
  fi

  if [ -n "$latest_tag" ] && [ "$tag" = "$latest_tag" ] && [ "$draft" != "true" ] && [ "$prerelease" != "true" ]; then
    gh release edit "$tag" --repo "$TARGET_REPO" --latest
  fi

  target_release_json="$(gh api "repos/$TARGET_REPO/releases/tags/$tag")"
  source_asset_names="$tmp_dir/source-assets-${tag//[^A-Za-z0-9._-]/_}.txt"
  jq -r '.assets[]?.name' <<<"$release_json" | sort > "$source_asset_names"

  jq -c '.assets[]?' <<<"$target_release_json" | while IFS= read -r target_asset_json; do
    target_asset_id="$(jq -r '.id' <<<"$target_asset_json")"
    target_asset_name="$(jq -r '.name' <<<"$target_asset_json")"

    if grep -Fxq "$target_asset_name" "$source_asset_names"; then
      continue
    fi

    notice "Deleting target-only asset $target_asset_name from $tag."
    gh api -X DELETE "repos/$TARGET_REPO/releases/assets/$target_asset_id"
  done

  jq -c '.assets[]?' <<<"$release_json" | while IFS= read -r asset_json; do
    asset_name="$(jq -r '.name' <<<"$asset_json")"
    asset_size="$(jq -r '.size' <<<"$asset_json")"
    asset_url="$(jq -r '.browser_download_url' <<<"$asset_json")"
    target_size="$(jq -r --arg name "$asset_name" '.assets[]? | select(.name == $name) | .size' <<<"$target_release_json" | head -n 1)"

    if [ -n "$target_size" ] && [ "$target_size" = "$asset_size" ]; then
      continue
    fi

    asset_path="$assets_dir/$asset_name"
    notice "Mirroring asset $asset_name for $tag."
    rm -f "$asset_path"
    retry 5 curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o "$asset_path" "$asset_url"
    retry 5 gh release upload "$tag" "$asset_path" --repo "$TARGET_REPO" --clobber
  done
done

notice "Protected upstream mirror complete."
