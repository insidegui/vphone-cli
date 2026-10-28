#!/usr/local/libexec/vphone-ssh/sh
# Run through a real SSH session: vphone-cli vm ssh <name> < UnixToolsSmoke.sh
set -eu
directory=$(mktemp -d /private/var/tmp/vphone-tools.XXXXXX)
trap 'rm -rf "$directory"' EXIT HUP INT TERM
cd "$directory"

# Check installed names, rather than invoking applets only via the multiplexer.
for applet in $(toybox); do
    [ -x "/usr/local/libexec/vphone-ssh/bin/$applet" ]
done
[ "$(command -v ps)" = /bin/ps ]
[ "$(command -v df)" = /bin/df ]

mkdir sub
printf 'beta 2\nalpha 1\nbeta 2\n' > input
cp input sub/copied
mv sub/copied sub/moved
cmp input sub/moved
ls -la . > listing
grep -q input listing
[ "$(cat input | grep alpha | sed 's/alpha/ok/')" = 'ok 1' ]
[ "$(sort input | uniq | head -n 1)" = 'alpha 1' ]
[ "$(tail -n 1 input)" = 'beta 2' ]
[ "$(wc -l < input | tr -d ' ')" = 3 ]
[ "$(cut -d ' ' -f 2 input | tr -d '\n')" = 212 ]
[ "$(find sub -type f)" = sub/moved ]
[ "$(printf 'one\0two\0' | xargs -0 -n 1 printf '[%s]')" = '[one][two]' ]
[ "$(awk '{sum += $2} END {print sum}' input)" = 5 ]
[ "$(awk 'BEGIN {print system("exit 7")}')" = 7 ]
[ "$(awk 'BEGIN {cmd="printf pipe-ok"; cmd | getline v; close(cmd); print v}')" = pipe-ok ]
awk 'BEGIN {print "write-pipe-ok" | "cat > output"; close("cat > output")}'
[ "$(cat output)" = write-pipe-ok ]
timeout 5 awk 'BEGIN {a="cat > first"; b="cat > second"; print "first" | a; print "second" | b; close(a); close(b)}'
[ "$(cat first)" = first ]
[ "$(cat second)" = second ]

gzip -c input > compressed.gz
gunzip -c compressed.gz > inflated
cmp input inflated
tar -czf archive.tar.gz input sub
mkdir extracted
tar -xzf archive.tar.gz -C extracted
cmp input extracted/input
cmp sub/moved extracted/sub/moved
ln -s input link
[ "$(readlink link)" = input ]
[ "$(stat -c %s input)" = 22 ]
chmod 600 input
[ "$(stat -c %a input)" = 600 ]
[ "$(sha256sum input | cut -d ' ' -f 1)" = "$(sha256sum inflated | cut -d ' ' -f 1)" ]
[ "$(id -u)" = 0 ]
date -u +%Y-%m-%d
sleep 0.1
ps -p $$
printf 'Unix tools smoke test passed\n'
