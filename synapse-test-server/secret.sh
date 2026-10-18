#!/usr/bin/bash

set -e
secret=GlfrFoZvTxgKMZc9bEoQYC1XnLpmW9eVNk4moPrIKQZlleDKgAb6fbrAiWfIgENW

u=$((`date +%s` + 3600)):test
p=$(echo -n $u | openssl dgst -hmac $secret -sha1 -binary | base64)
echo -e "username: $u\npassword: $p"
