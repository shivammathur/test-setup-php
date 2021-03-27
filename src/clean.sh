sudo apt-get purge php-* -y
to_wait=()
sudo find /usr/bin -maxdepth 1 -name "llvm*" -type d | xargs sudo rm -rf & to_wait+=($!)
sudo find /usr/include -maxdepth 1 -name "llvm*" -type d | xargs sudo rm -rf & to_wait+=($!)
sudo find /usr/lib -maxdepth 1 -name "llvm*" -type d | xargs sudo rm -rf & to_wait+=($!)
sudo find /usr/lib -maxdepth 1 -name "python*" -type d | xargs sudo rm -rf & to_wait+=($!)
sudo find /usr/local -maxdepth 1 -name "julia*" -type d | xargs sudo rm -rf & to_wait+=($!)
for dir in /lib/modules /usr/lib/google-cloud-sdk /usr/lib/erlang /usr/lib/heroku /usr/lib/jvm /usr/lib/modules /usr/lib/mono /usr/lib/R /usr/lib/ruby /usr/share/dotnet /usr/local/aws /usr/local/aws-cli /usr/local/doc /usr/local/graalvm /usr/local/include/node /usr/local/lib/android /usr/local/lib/node_modules /usr/local/n /usr/share/icons /usr/share/swift /usr/share/miniconda /usr/src/linux-azure-headers /var/lib/docker /var/lib/gems; do
  sudo mkdir -p /tmp/empty
  sudo rsync -a --delete /tmp/empty/ "$dir"/ & to_wait+=($!)
done
wait "${to_wait[@]}"
