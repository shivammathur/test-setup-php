release_cds() {
  for asset in ./builds/*/*; do
    assets+=("$asset")
    cloudsmith push raw "$repo" "$asset" --republish --summary "$asset" --description "$asset" &
    to_wait+=("$!")
  done
  cloudsmith push raw "$repo" ./src/php-ubuntu.sh --republish --summary php-ubuntu.sh --description php-ubuntu.sh
}

release_create() {
  release_cds
  assets+=("./src/install.sh")
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
cp ./src/install.sh ./src/php-ubuntu.sh
rm -rf ./builds/zstd*
if ! gh release view builds; then
  release_create
else
  release_upload
fi
wait "${to_wait[@]}"
log
