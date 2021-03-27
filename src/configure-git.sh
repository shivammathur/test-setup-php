cd / || exit 1
git config --global user.email "you@example.com"
sudo git init
sudo git add -v -f /bin /lib /lib64 /sbin /usr /var
sudo find /etc -maxdepth 1 -mindepth 1 -type d -exec git add -v -f {} \;
sudo git commit -m "init"