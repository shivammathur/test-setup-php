release_cds() {
  for asset in ./builds/*/*; do
    assets+=("$asset")
    cloudsmith push raw "$repo" "$asset" --republish --summary "$asset" --description "$asset" &
    to_wait+=("$!")
  done
}

release_create() {
  curl -o install.sh -sL https://dl.cloudsmith.io/public/"$repo"/raw/files/php-ubuntu.sh
  release_cds
  assets+=("./install.sh")
  gh release create "builds" "${assets[@]}" -n "builds $version" -t "builds"
}

release_upload() {
  gh release download -p "build.log" || true
  release_cds
  gh release upload "builds" "${assets[@]}" --clobber
}

log() {
  echo "$version" | sudo tee -a build.log
  gh release upload "builds" build.log --clobber
}

version=$(date '+%Y.%m.%d')
repo="$GITHUB_REPOSITORY"
assets=()
to_wait=()
cd "$GITHUB_WORKSPACE" || exit 1
if ! gh release view builds; then
  release_create
else
  release_upload
fi
wait "${to_wait[@]}"
log
