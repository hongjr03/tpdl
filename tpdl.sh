#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tpdl.sh <git-repository> [options]

Options:
  -r, --ref, --checkout <ref>    Git tag, branch, or commit to checkout.
  -n, --namespace <name>         Typst namespace to install into (default: local).
  -p, --package-path <dir>       Typst package data path (default: TYPST_PACKAGE_PATH or system data dir).
  -f, --force                    Replace an existing package version.
  -h, --help                     Print this help.

Installs to:
  {package-path}/{namespace}/{package.name}/{package.version}
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

repo=''
ref=''
namespace='local'
package_path="${TYPST_PACKAGE_PATH:-}"
force=0

while (($#)); do
  case "$1" in
    -r|--ref|--checkout)
      (($# >= 2)) || die "$1 requires a value"
      ref=$2
      shift 2
      ;;
    -n|--namespace)
      (($# >= 2)) || die "$1 requires a value"
      namespace=$2
      shift 2
      ;;
    -p|--package-path)
      (($# >= 2)) || die "$1 requires a value"
      package_path=$2
      shift 2
      ;;
    -f|--force)
      force=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$repo" ]] || die "only one repository can be provided"
      repo=$1
      shift
      ;;
  esac
done

[[ -n "$repo" ]] || {
  usage >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die "git was not found on PATH"

namespace=${namespace#@}
[[ "$namespace" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "namespace '$namespace' is not a valid Typst package identifier for this script"

resolve_package_path() {
  if [[ -n "$package_path" ]]; then
    printf '%s\n' "$package_path"
    return
  fi

  case "$(uname -s)" in
    Darwin)
      printf '%s\n' "$HOME/Library/Application Support/typst/packages"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      local data_dir="${APPDATA:-$HOME/AppData/Roaming}"
      printf '%s\n' "$data_dir/typst/packages"
      ;;
    *)
      local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"
      printf '%s\n' "$data_dir/typst/packages"
      ;;
  esac
}

manifest_field() {
  local manifest=$1
  local key=$2
  awk -v key="$key" '
    /^[[:space:]]*\[package\][[:space:]]*($|#)/ { in_package = 1; next }
    /^[[:space:]]*\[/ && in_package { exit }
    in_package {
      line = $0
      sub(/[[:space:]]+#.*/, "", line)
      pattern = "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*"
      if (line ~ pattern) {
        sub(pattern, "", line)
        sub(/[[:space:]]*$/, "", line)
        if (line ~ /^"/) {
          sub(/^"/, "", line)
          sub(/".*$/, "", line)
          print line
          exit
        }
        if (line ~ /^\047/) {
          sub(/^\047/, "", line)
          sub(/\047.*$/, "", line)
          print line
          exit
        }
      }
    }
  ' "$manifest"
}

manifest_excludes() {
  local manifest=$1
  awk '
    /^[[:space:]]*\[package\][[:space:]]*($|#)/ { in_package = 1; next }
    /^[[:space:]]*\[/ && in_package && !collecting { exit }
    in_package {
      line = $0
      if (!collecting && line ~ /^[[:space:]]*exclude[[:space:]]*=/) {
        collecting = 1
        sub(/^[^[]*\[/, "", line)
      }
      if (collecting) {
        done = line ~ /\]/
        sub(/\].*$/, "", line)
        while (match(line, /"([^"\\]|\\.)*"|'\''[^'\'']*'\''/)) {
          item = substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
          sub(/^["'\'']/, "", item)
          sub(/["'\'']$/, "", item)
          gsub(/\\"/, "\"", item)
          print item
        }
        if (done) {
          exit
        }
      }
    }
  ' "$manifest"
}

normalize_rel() {
  local value=$1
  value=${value//\\//}
  while [[ "$value" == ./* ]]; do
    value=${value#./}
  done
  value=${value%/}
  printf '%s\n' "$value"
}

should_exclude() {
  local rel
  rel=$(normalize_rel "$1")

  case "$rel" in
    .git|.git/*)
      return 0
      ;;
  esac

  local pattern
  for pattern in "${excludes[@]}"; do
    pattern=$(normalize_rel "$pattern")
    [[ -n "$pattern" ]] || continue
    if [[ "$rel" == "$pattern" || "$rel" == "$pattern"/* || "$rel" == $pattern ]]; then
      return 0
    fi
  done

  return 1
}

copy_package_files() {
  local source=$1
  local destination=$2

  mkdir -p "$destination"
  while IFS= read -r -d '' path; do
    local rel=${path#"$source"/}
    should_exclude "$rel" && continue

    local target="$destination/$rel"
    if [[ -d "$path" && ! -L "$path" ]]; then
      mkdir -p "$target"
    else
      mkdir -p "$(dirname "$target")"
      cp -pP "$path" "$target"
    fi
  done < <(find "$source" -mindepth 1 -print0)
}

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/tpdl.XXXXXX")
cleanup() {
  rm -rf "$temp_root"
}
trap cleanup EXIT

clone_dir="$temp_root/repo"
if [[ -z "$ref" ]]; then
  git clone --depth 1 -- "$repo" "$clone_dir"
else
  git clone -- "$repo" "$clone_dir"
  git -C "$clone_dir" checkout "$ref"
fi

manifest="$clone_dir/typst.toml"
[[ -f "$manifest" ]] || die "repository root does not contain typst.toml"

name=$(manifest_field "$manifest" name)
version=$(manifest_field "$manifest" version)
entrypoint=$(manifest_field "$manifest" entrypoint)

[[ -n "$name" ]] || die "typst.toml is missing package.name"
[[ -n "$version" ]] || die "typst.toml is missing package.version"
[[ -n "$entrypoint" ]] || die "typst.toml is missing package.entrypoint"
[[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "package.name '$name' is not a valid Typst package identifier for this script"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "package.version '$version' is not a valid Typst package version. Expected major.minor.patch"

excludes=()
while IFS= read -r item; do
  excludes+=("$item")
done < <(manifest_excludes "$manifest")

package_root=$(resolve_package_path)
base_dir="$package_root/$namespace/$name"
destination="$base_dir/$version"
spec="@$namespace/$name:$version"

if [[ -e "$destination" ]]; then
  if [[ "$force" -eq 0 ]]; then
    printf 'Already installed %s\n%s\n' "$spec" "$destination"
    exit 0
  fi
  rm -rf "$destination"
fi

mkdir -p "$base_dir"
temp_install="$base_dir/.tmp-$version-$RANDOM"
rm -rf "$temp_install"

copy_package_files "$clone_dir" "$temp_install"
if ! mv "$temp_install" "$destination"; then
  if [[ -e "$destination" && "$force" -eq 0 ]]; then
    rm -rf "$temp_install"
  else
    rm -rf "$temp_install"
    die "failed to move package into place"
  fi
fi

printf 'Installed %s\n%s\n' "$spec" "$destination"
