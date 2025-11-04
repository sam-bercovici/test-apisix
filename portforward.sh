#!/usr/bin/env bash
set -euo pipefail

kubectl -n apisix port-forward svc/apisix-gateway 8080:80
