#!/bin/bash
# GITEA_TOKEN은 나중에 관리자 페이지에서 발급받아 교체해야 합니다.
TOKEN="여기에_발급받은_토큰_입력"
URL="http://localhost:3000/api/v1"

# 1. 조직(clcoco) 생성
curl -X POST "$URL/orgs" \
     -H "Authorization: token $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"username": "clcoco"}'

# 2. 리포지토리(hello) 생성
curl -X POST "$URL/orgs/clcoco/repos" \
     -H "Authorization: token $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"name": "hello", "private": false}'
