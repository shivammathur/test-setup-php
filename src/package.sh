cd / || exit 1
git add /bin /lib /lib64 /sbin /usr /var
find /etc -maxdepth 1 -mindepth 1 -type d -exec git add {} \;
git commit -m "installed php"
mkdir -p /tmp/php
for file in $(git log -p -n 1 --name-only | sed 's/^.*\(\s\).*$/\1/' | xargs -L1 echo); do
  sudo cp -r -p --parents "$file" /tmp/php || true
done

. /etc/lsb-release
SEMVER="$(php -v | head -n 1 | cut -f 2 -d ' ' | cut -f 1 -d '-')"
(
  cd /tmp/php || exit 1
  sudo tar cf - ./* | zstd -22 -T0 --ultra > ../php_"$PHP_VERSION"+ubuntu"$DISTRIB_RELEASE".tar.zst
  cp ../php_"$PHP_VERSION"+ubuntu"$DISTRIB_RELEASE".tar.zst ../php_"$SEMVER"+ubuntu"$DISTRIB_RELEASE".tar.zst
)
cd "$GITHUB_WORKSPACE" || exit 1
mkdir builds
sudo mv /tmp/*.zst ./builds