#!/usr/bin/env bash

set -ux

PORT=30002

curl -s -o /dev/null -w "%{http_code}\n" --max-time 2 192.168.86.220:$PORT
curl -s -o /dev/null -w "%{http_code}\n" --max-time 2 192.168.86.221:$PORT
curl -s -o /dev/null -w "%{http_code}\n" --max-time 2 192.168.86.222:$PORT
