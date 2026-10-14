# CI/CD: GitHub → Azure DevOps → ACR → DigitalOcean Droplet

Hướng dẫn setup và vận hành pipeline cho repo `pipelines-dotnet-core`.

## 0. Trạng thái (2026-10-14)

| Hạng mục | Trạng thái | Bằng chứng |
|---|---|---|
| ACR `RafflesDemo` (`rafflesdemo.azurecr.io`, RG `ResourceGroup1`, `LegacyRegistryPermissions`) | ✅ Đã tạo (theo output `az acr show` của phiên trước) | Chưa verify lại từ máy local — CLI local không có quyền vào subscription `2dc612d2-…` |
| Service principal `sp-rafflesdemo-do-pull` (AcrPull) | ❌ Mới đề xuất, **chưa chạy** | — |
| Azure DevOps project, `ACRConnection`, `UbuntuSSHConnection`, Environments | ❌ Chưa tạo | — |
| Droplet | ❌ Chưa setup | — |
| Code trong repo (Dockerfile, `/health`, pipeline YAML, script Droplet) | ✅ Xong, đã test | Build image OK; 24/24 test deploy trên Docker Linux thật (dind) — dùng registry local thay ACR |
| Chạy pipeline trên Azure DevOps | ❌ Chưa chạy | Phải tạo service connection trước |

## 1. Kiến trúc

```mermaid
flowchart LR
  GH[GitHub<br/>develop / stage] -->|webhook| ADO[Azure Pipelines<br/>Microsoft-hosted ubuntu-latest]
  ADO -->|Docker@2 push<br/>ACRConnection| ACR[(rafflesdemo.azurecr.io<br/>pipelines-dotnet-core:BuildId)]
  ADO -->|SSH@0, 1 lệnh<br/>UbuntuSSHConnection| DO[DigitalOcean Droplet<br/>user deploy]
  DO -->|docker pull<br/>SP AcrPull| ACR
  DO --> C1[container dev<br/>127.0.0.1:8081]
  DO --> C2[container stage<br/>127.0.0.1:8082]
```

| Branch | Pipeline file | Environment (ADO) | Container trên Droplet | Approval |
|---|---|---|---|---|
| `develop` | `.azure-pipelines/azure-pipelines-dev.yml` | `pipelines-dotnet-core-dev` | `pipelines-dotnet-core-dev` :8081 | Không |
| `stage` | `.azure-pipelines/azure-pipelines-stage.yml` | `pipelines-dotnet-core-stage` | `pipelines-dotnet-core-stage` :8082 | Có |

PR vào `develop`/`stage` chỉ chạy CI (build/test/scan + build image, không push, không deploy).

**3 credential, 3 trách nhiệm riêng:**

| Credential | Ai dùng | Quyền |
|---|---|---|
| `ACRConnection` | Azure Pipelines | Push image vào ACR (AcrPush) |
| `UbuntuSSHConnection` (SSH key) | Azure Pipelines | Login Droplet bằng user `deploy` |
| `sp-rafflesdemo-do-pull` | Docker trên Droplet | Chỉ pull (AcrPull) |

## 2. Azure — Droplet pull identity (Cloud Shell)

Với `LegacyRegistryPermissions`, role đúng cho pull-only là **`AcrPull`** (chế độ ABAC mới dùng role "Container Registry Repository Reader" — không áp dụng ở đây). Không dùng admin account của ACR.

Quyền cần có của người chạy: tạo app registration trong tenant + **Owner / User Access Administrator / Role Based Access Control Administrator** trên ACR.

```bash
az account set --subscription 2dc612d2-782c-4b15-9376-0b816ced891f
ACR_ID=$(az acr show --name RafflesDemo --resource-group ResourceGroup1 --query id -o tsv)

# Kiểm tra lại chế độ quyền + admin user đang tắt
az acr show --name RafflesDemo --query "{roleMode:roleAssignmentMode, adminEnabled:adminUserEnabled, sku:sku.name}" -o table

# Tạo SP pull-only. Output chứa password -> chỉ hiển thị 1 lần, lưu vào password manager, không dán vào chat/repo.
az ad sp create-for-rbac \
  --name sp-rafflesdemo-do-pull \
  --role AcrPull \
  --scopes "$ACR_ID" \
  --years 1 \
  --query "{appId:appId, password:password}" -o json

# Verify role assignment (thay <appId>)
az role assignment list --assignee <appId> --scope "$ACR_ID" --query "[].roleDefinitionName" -o tsv   # -> AcrPull
```

Secret hết hạn sau 1 năm → đặt lịch rotate (`az ad sp credential reset --id <appId> --years 1`, rồi `docker login` lại trên Droplet).

## 3. Azure DevOps

### 3.1 Project + GitHub
1. Tạo project (vd. `Raffles-Demo`).
2. Cài **Azure Pipelines GitHub App** cho repo `pipelines-dotnet-core` (chỉ chọn repo này).

### 3.2 `ACRConnection` (push)
Project settings → Service connections → New → **Docker Registry** → **Azure Container Registry**:
- Authentication type: **Workload Identity federation (automatic)** (không lưu secret)
- Subscription `2dc612d2-…`, registry `RafflesDemo`
- Service connection name: **`ACRConnection`**
- Bỏ chọn *Grant access permission to all pipelines* (cấp cho từng pipeline ở lần chạy đầu)

Nếu tài khoản ADO không đủ quyền tạo SP/role assignment: tạo SP push riêng (`az ad sp create-for-rbac --name sp-rafflesdemo-ado-push --role AcrPush --scopes "$ACR_ID"`) rồi dùng **Docker Registry → Others**: registry `https://rafflesdemo.azurecr.io`, Docker ID = appId, password = secret.

### 3.3 SSH key + `UbuntuSSHConnection`
Tạo key **riêng** cho Azure DevOps (không dùng key cá nhân):

```bash
ssh-keygen -t rsa -b 4096 -m PEM -f ~/.ssh/ado-droplet-deploy -C "ado-deploy" -N ""
```

(PEM/RSA để tương thích chắc chắn với task SSH; public key `~/.ssh/ado-droplet-deploy.pub` dùng ở bước 4.)

Service connections → New → **SSH**:
- Host name: IP Droplet · Port: 22 · Username: **`deploy`**
- Private key: nội dung `~/.ssh/ado-droplet-deploy`
- Name: **`UbuntuSSHConnection`**, không cấp cho all pipelines

### 3.4 Environments
Pipelines → Environments → New (Resource: **None**):
- `pipelines-dotnet-core-dev`
- `pipelines-dotnet-core-stage` → Approvals and checks → **Approvals** (người duyệt) + **Branch control** (`refs/heads/stage`)

### 3.5 Pipelines
New pipeline → GitHub → repo → **Existing Azure Pipelines YAML file**:
- branch `develop`, path `/.azure-pipelines/azure-pipelines-dev.yml` → rename `pipelines-dotnet-core-dev`
- branch `stage`, path `/.azure-pipelines/azure-pipelines-stage.yml` → rename `pipelines-dotnet-core-stage`

Lần chạy đầu sẽ hỏi **Permit** cho `ACRConnection`, `UbuntuSSHConnection` và Environment.

## 4. Droplet

1. Tạo Droplet Ubuntu 22.04/24.04 (≥ 1 GB RAM), login bằng SSH key của admin.
2. **DigitalOcean Cloud Firewall** (inbound):
   - 22/tcp: mở (Microsoft-hosted agent không có IP cố định — xem mục 8)
   - 80/443: chỉ khi đặt Nginx
   - **Không** mở 8081/8082 (container bind `127.0.0.1`; lưu ý Docker bypass `ufw` nếu đổi sang `0.0.0.0`)
3. Setup (root):

```bash
git clone https://github.com/QuangRubyAdamo/pipelines-dotnet-core.git && cd pipelines-dotnet-core && git checkout develop
sudo ./deploy/setup-droplet.sh "$(cat ado-droplet-deploy.pub)" dev stage
```

Script tạo user `deploy` (nhóm `docker`), cài Docker, cài `/opt/pipelines-dotnet-core/bin/deploy-container.sh`, tạo `/etc/pipelines-dotnet-core/{dev,stage}.conf` (port/bind) và `{dev,stage}.env` (biến môi trường/secret của app, quyền 640).

4. Login ACR bằng SP pull-only (không để password vào history):

```bash
sudo -iu deploy
read -rsp 'ACR pull password: ' P; echo
printf '%s' "$P" | docker login rafflesdemo.azurecr.io --username <appId> --password-stdin; unset P
chmod 600 ~/.docker/config.json
```

> `~/.docker/config.json` lưu credential dạng base64 (không mã hoá) — chỉ user `deploy` đọc được; quyền chỉ là pull.

5. Hardening SSH (làm tay, **sau khi** đã test login bằng key, giữ 1 session mở phòng khoá ngoài): trong `/etc/ssh/sshd_config.d/60-hardening.conf` đặt `PasswordAuthentication no`, `PermitRootLogin prohibit-password` (hoặc `no` nếu đã có admin user khác) → `sshd -t && systemctl reload ssh`. Cân nhắc `fail2ban`.

## 5. Chạy lần đầu & kiểm tra

```bash
git push -u origin develop stage   # trigger 2 pipeline
```

Kiểm tra:

```bash
# ACR có tag mới (Cloud Shell)
az acr repository show-tags --name RafflesDemo --repository pipelines-dotnet-core --orderby time_desc --top 5 -o table

# Trên Droplet
docker ps --filter name=pipelines-dotnet-core
curl -fsS http://127.0.0.1:8081/health && echo   # Healthy
docker logs --tail 50 pipelines-dotnet-core-dev
```

Log pipeline bước *Deploy* kết thúc bằng `Deployed rafflesdemo.azurecr.io/pipelines-dotnet-core:<BuildId> to dev`.

Xem app từ máy cá nhân (không mở port): `ssh -L 8081:127.0.0.1:8081 <admin>@<droplet-ip>` → http://localhost:8081.

## 6. Cách deploy hoạt động & rollback

`deploy-container.sh <dev|stage> <image>` trên Droplet:
1. Chỉ nhận image thuộc `rafflesdemo.azurecr.io/pipelines-dotnet-core` với tag hợp lệ.
2. `docker pull` đúng tag của run.
3. Chạy bản mới thành container **candidate** trên port localhost ngẫu nhiên → check `/health`. Fail → xoá candidate, **container đang chạy không bị đụng tới**, pipeline fail.
4. Thay container chính (downtime vài giây) → check `/health`. Fail → chạy lại image trước đó.
5. Khoá theo instance — 2 deploy cùng lúc chạy tuần tự.
6. Container: non-root (uid 10001), read-only rootfs, `--cap-drop ALL`, `no-new-privileges`, 512 MB, `--restart unless-stopped`.

**Rollback:** mở run thành công trước đó trong Azure DevOps → *Rerun* stage Deploy → deploy lại đúng tag cũ (vẫn còn trong ACR).

## 7. Troubleshooting

| Triệu chứng | Nguyên nhân thường gặp | Xử lý |
|---|---|---|
| `NETSDK1045` / SDK không hỗ trợ target | Sai `dotnetVersion` | `templates/variables.yml` khớp `<TargetFramework>` (hiện `6.0.x`) |
| Gitleaks fail | Secret trong code/history | Xoá secret, **rotate** secret đó (history vẫn còn) |
| Dependency scan fail | Package có CVE High/Critical | Nâng version package |
| Docker@2: `unauthorized` / `denied` khi push | `ACRConnection` thiếu AcrPush / chưa Permit | Kiểm tra role của SP của connection trên ACR; Permit trong run |
| Pipeline báo *resource not authorized* | Chưa cấp quyền service connection/Environment | Mở run → **Permit** |
| SSH: `All configured authentication methods failed` | Sai username/key, key không phải PEM, chưa có trong `authorized_keys` | `ssh -i ~/.ssh/ado-droplet-deploy deploy@<ip>` từ máy local; `ssh-keygen -p -m PEM -f <key>` |
| SSH timeout | Cloud Firewall/ufw chặn 22 | Kiểm tra firewall rule |
| `permission denied ... docker.sock` | User `deploy` chưa vào nhóm docker / chưa login lại | `id deploy`; chạy lại `setup-droplet.sh` |
| `docker pull failed` | Chưa `docker login` bằng user `deploy`, SP hết hạn, chưa có AcrPull | `sudo -iu deploy docker pull rafflesdemo.azurecr.io/pipelines-dotnet-core:<tag>`; kiểm tra role assignment |
| `new image failed its health check` | App crash khi start, thiếu biến môi trường | Log candidate được in trong log pipeline; thêm biến vào `/etc/pipelines-dotnet-core/<env>.env` |
| `another deploy ... still running` | Deploy trước chưa xong (>10 phút) | Kiểm tra container/`docker ps`; chạy lại |

## 8. Bảo mật — lưu ý & giới hạn

- **Port 22 mở ra internet**: hệ quả của việc dùng Microsoft-hosted agent + SSH (IP agent thay đổi). Giảm rủi ro: chỉ key, tắt password, fail2ban, key ADO dùng riêng. Phương án không cần mở port: self-hosted agent/Environment VM agent trên Droplet (pull model) — đã bị loại theo yêu cầu "không self-hosted".
- **User `deploy` thuộc nhóm `docker` ≈ root** trên Droplet. Pipeline chỉ gửi 1 lệnh cố định nên có thể siết thêm bằng *forced command* trong `authorized_keys` (`command="…",no-pty,no-port-forwarding`) — **chưa test với task SSH@0**, cần thử trước khi áp dụng.
- SSH service connection không có trường pin host key; muốn kiểm tra host key dùng `InstallSSHKey@0` (`knownHostsEntry`) + script `ssh` thay cho `SSH@0`.
- Không có secret trong repo/image; secret app nằm ở `/etc/pipelines-dotnet-core/<env>.env` (640 root:deploy).
- Public HTTPS: đặt Nginx/Caddy trên Droplet proxy tới `127.0.0.1:8081/8082` (chưa làm).
- ACR tích tụ tag theo BuildId; Basic SKU không có retention policy → dọn định kỳ bằng `az acr run --cmd "acr purge --filter 'pipelines-dotnet-core:.*' --ago 30d --keep 10" /dev/null`.
- **.NET 6 đã EOL (11/2024)**: image base không còn được vá. Nâng lên .NET 8 = đổi `TargetFramework`, `dotnetVersion`, 2 tag trong `Dockerfile`.
- Repo chưa có unit test → bước test chỉ cảnh báo; thêm project `*Tests.csproj` là tự chạy.
