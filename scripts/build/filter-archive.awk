# Only prune documentation in a keg or in Homebrew's shared prefix. Keep
# license/notice files, their symlink chains, and targets of retained aliases.
function documentation(path, p, n, i) {
  n=split(path, p, "/")
  if (p[1] == "share") i=2
  else if (p[1] == "Cellar" && n >= 5 && p[4] == "share") i=5
  else return 0
  return p[i] in documentation_dirs
}
function normalize(path, p, stack, n, i, count, result) {
  if (substr(path, 1, 1) == "/") {
    if (index(path, installed_prefix "/") != 1) return ""
    path=substr(path, length(installed_prefix)+2)
  }
  n=split(path, p, "/")
  for (i=1; i<=n; i++) {
    if (p[i] == "" || p[i] == ".") continue
    if (p[i] == "..") {
      if (!count) return ""
      count--
    } else stack[++count]=p[i]
  }
  for (i=1; i<=count; i++) result=result (i==1 ? "" : "/") stack[i]
  return result
}
function retain(path) {
  if ((path in members) && !(path in kept)) { kept[path]=1; changed=1 }
}
function resolve(path, p, n, i, j, current, parent, target, moved, iteration) {
  # Cyclic or external aliases are preserved as-is, never followed on disk.
  for (iteration=0; iteration<64; iteration++) {
    n=split(path, p, "/"); current=""; parent=""; moved=0
    for (i=1; i<=n; i++) {
      parent=current
      current=current (i==1 ? "" : "/") p[i]
      if (!(current in links)) continue
      retain(current)
      target=links[current]
      if (substr(target, 1, 1) != "/") target=parent "/" target
      # A root-level relative alias must not become an absolute path.
      if (parent == "" && substr(links[current], 1, 1) != "/") target=links[current]
      target=normalize(target)
      if (target == "") return ""
      for (j=i+1; j<=n; j++) target=target "/" p[j]
      path=target; moved=1; break
    }
    if (!moved) return path
  }
  return ""
}
BEGIN {
  count=split(directories, configured, " ")
  for (i=1; i<=count; i++) documentation_dirs[configured[i]]=1
}
FILENAME == ARGV[1] {
  members[$0]=1; ordered[++member_count]=$0
  if (!documentation($0) || tolower($0) ~ preserve_pattern) kept[$0]=1
  next
}
FILENAME == ARGV[2] {
  if (NF != 2 || !($1 in members) || $2 == "" || $2 ~ /[\r\n]/) exit 1
  links[$1]=$2
}
END {
  do {
    changed=0
    for (link in links) if (link in kept) {
      target=resolve(link)
      if (!documentation(target)) continue
      retain(target)
      # Retained aliases to a documentation directory must not become dangling.
      for (member in members) if (index(member, target "/") == 1) retain(member)
    }
  } while (changed)
  for (i=1; i<=member_count; i++) if (ordered[i] in kept) print ordered[i]
}
