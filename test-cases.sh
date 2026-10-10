# The profiles the allowlist must accept and refuse. Sourced by test-launcher.sh (vpn.sh's awk check) and by
# windows/check/export-cases.sh (the C# check), so both read one list. The caller defines allowed() and refused().
# shellcheck shell=sh disable=SC2034
base='client\ndev tun\nproto udp\nremote vpn.example.com 1194\n'
pre=  # bytes put before the profile
long=$(printf %0300d 0)  # longer than OpenVPN reads in one piece

allowed "plain client profile" ''
allowed "common directives" 'nobind\npersist-tun\nremote-cert-tls server\ncipher AES-256-GCM\nauth SHA512\nverb 3\nkeepalive 10 60\n'
allowed "inline blocks, whatever they contain" '<ca>\n-----BEGIN CERTIFICATE-----\nup down plugin\n-----END CERTIFICATE-----\n</ca>\n<tls-crypt>\nabc\n</tls-crypt>\n'
allowed "routes and DNS (never applied)" 'redirect-gateway def1\ndhcp-option DNS 1.1.1.1\nroute 10.0.0.0 255.0.0.0\n'
allowed "setenv forms OpenVPN Connect profiles use" 'setenv opt block-outside-dns\nsetenv CLIENT_CERT 0\n'
allowed "leading dashes and CRLF line endings" '--nobind\r\nverb 3\r\n'
allowed "connection block" '<connection>\nremote b.example.com 443 tcp\n</connection>\n'
allowed "proxy without a credentials file" 'http-proxy proxy.example.com 8080\nsocks-proxy 127.0.0.1 1080\n'
allowed "directives after an inline block" '<ca>\nabc\n</ca>\nnobind\nverb 3\n'
allowed "trailing comments" 'verb 3 # note\nremote b.example.com 443 ; backup\n'
allowed "quotes and backslashes inside a comment" '# don\047t "edit" this\\\nverb 3 # it\047s fine\n'
allowed "comment line starting with ;" '; just a note\n'
allowed "tabs between arguments" 'verb\t3\nkeepalive\t10\t60\n'
allowed "CRLF line endings around an inline block" '<ca>\r\nabc\r\n</ca>\r\nverb 3\r\n'
allowed "closing tag preceded by spaces" '<ca>\nabc\n  \t</ca>\nverb 3\n'
allowed "a 249-character line" "# $(printf %0247d 0)\n"
pre='\0357\0273\0277'; allowed "UTF-8 byte-order mark on the first line" ''; pre=

refused "up script" 'up /tmp/x.sh\n' "'up'"
refused "quoted directive name" '"down" /tmp/x.sh\n' "quotes or backslashes"
refused "dashed directive name" '--route-up /tmp/x.sh\n' "'route-up'"
refused "directive after an inline block" '<ca>\nabc\n</ca>\nplugin /tmp/x.so\n' "'plugin'"
refused "setenv opt smuggling a directive" 'setenv opt up /tmp/x.sh\n' "'up'"
refused "setenv of an arbitrary variable" 'setenv PATH /tmp\n' "'setenv PATH'"
refused "unknown inline block" '<up>\n/tmp/x.sh\n</up>\n' "'<up>'"
refused "log file" 'log /etc/x\n' "'log'"
refused "script-security" 'script-security 3\n' "'script-security'"
refused "management interface" 'management 127.0.0.1 7505\n' "'management'"
refused "device path" 'dev-node /dev/disk0\n' "'dev-node'"
refused "tap device" 'dev tap0\n' "'dev tap0'"
refused "proxy credentials file" 'http-proxy proxy.example.com 8080 /etc/passwd\n' "credentials file"
refused "username and password" 'auth-user-pass\n' "'auth-user-pass'"
refused "crypto engine" 'engine dynamic\n' "'engine'"
refused "unknown directive" 'frobnicate 1\n' "'frobnicate'"

# Where awk and OpenVPN read a profile differently, a directive can hide from the allowlist.
refused "closing tag with text glued on, then a forbidden directive" '<ca>\nabc\n</ca>x\nup /tmp/x.sh\n' "'up'"
refused "quote before a comment marker" 'verb "3 # note"\n' "quotes or backslashes"
refused "certificate block opened inside a connection block" '<connection>\n<ca>\n</connection>\nup /tmp/x.sh\n</ca>\n' "inside <connection>"
refused "unterminated inline block" '<ca>\nabc\nup /tmp/x.sh\n' "unterminated <ca> block"
refused "opening tag followed by more text" '<ca> extra\nup /tmp/x.sh\n</ca>\n' "'<ca>'"
refused "opening tag with leading dashes" '--<ca>\nup /tmp/x.sh\n</ca>\n' "'<ca>'"
refused "proxy credentials file in glued quotes" 'http-proxy proxy.example.com 8080 "auto""/etc/passwd"\n' "quotes or backslashes"
refused "proxy credentials file behind a vertical tab" 'http-proxy proxy.example.com 8080\v/etc/passwd\n' "control character"
refused "double quote" 'verb "3"\n' "quotes or backslashes"
refused "single quote" "verb '3'\n" "quotes or backslashes"
refused "backslash" 'verb 3 \\ x\n' "quotes or backslashes"
refused "carriage return inside a line" 'verb 3\rup /tmp/x.sh\n' "control character"
refused "NUL byte" '#\0 x\n' "control character"
refused "semicolon inside a word is not a comment" 'nobind;up /tmp/x.sh\n' "'nobind;up'"
refused "300-character line outside a block" "# $long\n" "longer than 249"
refused "300-character line inside a block" "<ca>\n$long\n</ca>\n" "longer than 249"
refused "control character inside a block" '<ca>\nab\vcd\n</ca>\n' "control character"
