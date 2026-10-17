# 최초 준비와 등록

현재는 운영 공개키 파일이 아직 게시되지 않은 준비 단계입니다. 실제 Portal 접속 파일의 서명 검증·등록 개통은 운영 공개키 게시와 Portal 연결 검증 뒤 안내합니다.

## 신뢰 자료 준비

이 저장소의 정확한 HTTPS 주소 `https://github.com/seungyeobchoi/portal-kubectl-access`를 먼저 확인합니다. 사용자별 접속 ZIP과 별개로 OS에 맞는 등록기·공개키·검증 도구를 준비합니다.

| Windows 디렉터리 | Ubuntu 디렉터리 |
|---|---|
| `Register-PortalKubeconfig.ps1` | `register_portal_kubeconfig.py` |
| `portal-kubeconfig.pub` — 운영 키 준비 뒤 게시 | 같은 운영 공개키 파일 — 준비 뒤 게시 |
| `minisign.exe` — 공식0.12 archive의 x86_64 실행 파일 | `minisign` — 공식0.12 archive의 x86_64 실행 파일 |
| `minisign.sha256` | `minisign.sha256` |

공식 도구: [minisign0.12 release](https://github.com/jedisct1/minisign/releases/tag/0.12). 고정 archive URL·관측 SHA256은 [toolchain.json](../toolchain.json)에 있습니다. Windows archive에는 여러 CPU용 파일이 있으므로 x86_64를 사용합니다. 등록기는 실행 파일의 hash를 같은 디렉터리의 pin과 비교하며 자동 업데이트하거나 HTTP ZIP의 도구/키로 바꾸지 않습니다. pin은 공식 HTTPS에서 획득한 파일의 관측값이며 upstream release API가 제공한 digest로 표시하지 않습니다.

운영 `portal-kubeconfig.pub`가 없으면 등록기는 실패합니다. 임의 키나 다른 프로젝트의 키를 넣지 않습니다. 등록기·공개키·pin을 HTTP에서 모두 다시 받는 방식으로 신뢰 기준을 바꾸지 않습니다.

## 접속 ZIP 등록

운영 준비가 완료된 뒤 Portal에서 자기 클러스터의 ZIP을 받습니다. ZIP에는 `cluster.yaml`과 `cluster.yaml.minisig` 두 파일만 있어야 합니다. 직접 압축을 풀 필요 없이 등록기에 ZIP 경로를 전달합니다. 아래 명령은 운영 공개키/도구가 준비됐을 때의 사용 형태입니다.

Windows에서 신뢰한 등록기 디렉터리를 열고 실행합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-PortalKubeconfig.ps1 -BundlePath "$env:USERPROFILE\Downloads\portal-kubeconfig.zip"
```

이 호출의 실행 정책은 새 PowerShell 프로세스에만 적용합니다. PC 전체 실행 정책이나 조직의 Group Policy를 변경하지 않습니다. 조직 정책으로 실행이 금지된 환경에서는 그 정책을 우회하지 않고 관리자에게 승인된 실행 방법을 확인합니다. 실행 대상은 위의 독립 HTTPS 경로에서 준비한 등록기입니다.

Ubuntu 또는 WSL Ubuntu에서는 다음 형태를 사용합니다.

```bash
python3 ./register_portal_kubeconfig.py --bundle "$HOME/Downloads/portal-kubeconfig.zip"
```

Ubuntu에서는 시스템 Python3와 실행 가능한 공식 `minisign`이 필요합니다. 등록기는 별도 Python package를 설치하지 않습니다. WSL에서는 Linux 홈의 경로와 Linux 실행 파일을 기준으로 사용합니다. WSL에서 Windows binary를 호출하는 조합은 별도 검증 전입니다.

등록 성공 시 JSON의 `path`에 출력된 정확한 파일을 kubectl에 전달합니다.

```text
kubectl --kubeconfig "<등록 결과의 path>" get pods
```

기본 위치는 해당 OS 사용자 홈의 `.kube/portal/portal-<내용 SHA256>.yaml`입니다. 같은 파일을 다시 등록하면 같은 경로를 사용하고 다른 내용은 새 파일로 등록합니다. 기존 설정을 자동 삭제하거나 기본 kubeconfig에 합치지 않습니다. Ubuntu 대상 디렉터리는 사용자 소유0700이며 파일은0600이어야 합니다. Windows는 사용자 소유와 변경 권한·reparse point를 확인합니다.

## 실패와 보호 범위

서명/키/도구가 맞지 않거나 파일이 변조됐거나 등록 경로가 안전하지 않으면 등록을 중단합니다. 기존 정상 파일은 보존하고 무서명 대체 파일을 제공하지 않습니다. 파일을 편집한 뒤 기존 서명으로 등록할 수는 없습니다.

파일 등록은 token 발급/refresh·keyring 초기화·서버 계정 변경을 실행하지 않습니다. 인증은 기존 kubectl OIDC 도우미의 브라우저 로그인 흐름을 따릅니다. 서명은 현재 사용자 권한·클러스터 최신 상태·회수나 HTTP Portal 화면/세션의 기밀성을 보증하지 않습니다. 권한은 서버가 계속 검사합니다.

최초 GitHub/공식 도구 획득이 막히면 최초 준비를 완료할 수 없습니다. 이미 등록한 파일의 일반 kubectl 명령은 GitHub 조회를 요구하지 않습니다. 새 공개키를 HTTP 화면에서 봤다는 이유만으로 자동 신뢰하지 않습니다.

## HTTPS 전환 후

Portal HTTPS의 신뢰 체인·자동 갱신·로그인/쿠키·다운로드 경로 검증을 마치면 최초 준비 자료도 Portal에서 직접 제공합니다. 전환 전후 파일·키 버전과 사용자 안내를 대조하고 기존 GitHub 설치 사용자에게 새 경로를 안내합니다. 등록기와 기존 정상 파일을 즉시 강제 삭제하는 방식으로 전환하지 않습니다.
