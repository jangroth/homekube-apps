#!/usr/bin/env bash

set -ux

curl -s -o /dev/null -w "%{http_code}\n" --max-time 2 192.168.86.220:30745
curl -s -o /dev/null -w "%{http_code}\n" --max-time 2 192.168.86.221:30745
curl -s -o /dev/null -w "%{http_code}\n" --max-time 2 192.168.86.222:30745
