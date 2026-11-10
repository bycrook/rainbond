# 安全审计报告：隐蔽数据上报 / 遥测埋点 / 后门专项

- **审计对象**：`/home/project/rainbond`（Go 核心服务，含 1 个 JS 示例文件）
- **审计范围**：`api/`、`builder/`、`worker/`、`pkg/`、`grctl/`、`util/`、`event/`、`mq/`、`db/`、`config/`、`cmd/`（排除 `vendor/`、`third_party/`、`*_test.go`）
- **审计日期**：2026-11-06
- **审计重点**：隐性上报、条件触发上报、动态拼接地址上报、加密载荷上报、依赖包内隐藏上报、远端代码/配置拉取、敏感凭据外发

---

## 发现 1

【风险等级】**高**
【位置】`grctl/cmd/replace.go:330`（配合 `:295-340`）
【风险描述】`GenerateDomain` 以**明文 HTTP** 向公网域名 `http://domain.grapps.cn/domain/new` 发送表单数据：**集群网关 IP、集群 UUID、auth 认证密钥对**。这些是集群身份信息，可被中间人截获并用于仿冒/关联该集群。
【判定理由】硬编码公网域名 + `http.PostForm` 外发集群标识数据；非内网地址，无 TLS，无白名单校验。属于条件触发（`grctl replace ip --suffix true` 时才执行）的隐性上报路径。
【修复建议】改为 HTTPS 并校验证书；增加目标域名白名单；将 ip/uuid/auth 传输改为加密载荷；至少在执行前向操作者明示外发内容。

## 发现 2

【风险等级】**高**
【位置】`grctl/cmd/replace.go:216-218、246-262`（`SendtoConsole`）
【风险描述】从集群 Secret `rbd-api-client-cert` 读取 **rbd-api 客户端证书、私钥（client.key.pem）、CA 证书**，连同 api/websocket 地址、集群名、域名后缀，以 JSON POST 发往命令行 `-d` 指定的 console 域名（通常为公网控制台）。若 console 地址为 HTTP 或被 DNS 劫持，**集群级客户端私钥直接泄露**，攻击者可凭此私钥仿冒该集群调用 region API。
【判定理由】读取集群凭据 → 序列化 → 外发 HTTP POST，属于典型"读取敏感凭据后上传"通路；目标地址来自外部参数，无固定白名单。
【修复建议】私钥绝不应出集群边界；改为在 console 侧仅登记证书指纹、由 region 主动双向 mTLS 注册；强制目标地址 HTTPS + 域名白名单；外发前脱敏。

## 发现 3

【风险等级】**中**【疑似，需要人工复核】
【位置】`pkg/observability/sentry/sentry.go:225-231`、`config.go:23-45`；启用点：`cmd/api/main.go:40`、`cmd/worker/worker.go:47`、`cmd/builder/builder.go:45`、`cmd/mq/mq.go:38`、`cmd/init-probe/probe.go:37`
【风险描述】自研 Sentry 客户端，将所有组件的 **panic 详情、错误消息、完整堆栈、HTTP 请求路径** POST 到由 DSN 派生的外部 ingest 地址。堆栈和错误消息中可能包含内部 URL、SQL、业务数据。敏感字段有脱敏（token/password/secret/bearer 等），但脱敏不保证覆盖堆栈内嵌内容。
【判定理由】标准遥测上报通路：错误/堆栈 + tags（含请求路径）→ 异步 goroutine POST 外发。DSN 来自环境变量（`SENTRY_DSN` 等），`config.go:11-12` 注释称**官方发布镜像在构建期注入公网 DSN**——注释不可作为豁免依据。缓解因素：`RAINBOND_TELEMETRY_DISABLED=true` 可关闭；源码构建默认无 DSN 不上报。
【修复建议】需要人工复核：① 确认发布镜像注入的 DSN 实际指向及数据保留策略；② 默认改为 opt-in（未显式启用不上报）；③ 对堆栈做更严格的路径/内网 IP 脱敏；④ 在文档中明示该通路及关闭方式。

## 发现 4

【风险等级】**中**【疑似，需要人工复核】
【位置】`builder/exector/build_from_vm.go:341`；`builder/parser/vm_service.go:122、139`
【风险描述】构建 VM 镜像时向**用户完全可控的任意 URL**（`VMImageSource`/`sourceBody`）发起 GET/HEAD，且可能附带 `VMImageToken` 鉴权头。构成 SSRF 面：可被诱导向内网地址探测，或把平台持有的 token 发往攻击者服务器。
【判定理由】"从远端拉取内容 + 携带凭据 + URL 可控"三条特征齐备；属业务功能但缺少出站目标校验。
【修复建议】增加出站白名单/内网地址段黑名单（10/172.16-31/192.168/127/169.254 及集群 svc 域）；token 与下载 URL 分离；禁止重定向跟随到内网。

## 发现 5

【风险等级】**中**【疑似，需要人工复核】
【位置】`api/handler/helm.go:68-74`
【风险描述】向用户填写的 Chart 仓库 `RepoURL`（可为任意公网地址）发起请求，并以 **BasicAuth 明文携带 chart 仓库用户名/密码**。若 RepoURL 可被低权限用户篡改，凭据即外带。
【判定理由】凭据 + 用户可控外发目标；业务功能，但缺输入归属校验。
【修复建议】校验操作者对 RepoURL 的配置权限；凭据加密存储、按需注入；记录仓库地址变更审计日志。

## 发现 6

【风险等级】**低**
【位置】`builder/build/cnb/dependency_mirror.go:11、31-42`
【风险描述】构建依赖镜像默认指向公网 `https://buildpack.rainbond.com/cnb`，地址优先级为 环境变量 > 标记文件 > 默认公网 URL，写入 build pod annotation。属**下载**而非上报，但意味着默认配置下构建环境会外联公网（气隙环境信息泄露面：DNS/HTTP 请求本身暴露集群存在）。
【判定理由】动态配置 URL + 默认公网目标。
【修复建议】气隙部署文档强制要求配置 `BP_DEPENDENCY_MIRROR`；支持集群内镜像仓代理。

## 附带安全备注（非上报类）

【风险等级】**低**
【位置】`pkg/component/es/esComponent.go:43,106`；`worker/master/controller/thirdcomponent/prober/runtime_probe.go:34`
【风险描述】出站 TLS 统一 `InsecureSkipVerify:true`，证书校验被绕过，存在中间人截获 ES 凭据/探测数据的风险。
【修复建议】改为可配置的 CA 校验，仅在内网自签场景显式豁免。

---

## 【无风险】排除项说明

核查了：语法层误报（`api/handler/covert_resource.go` 实为 `ConvertResource` 拼写，纯 K8s 资源转换，无网络行为）；`event/manager.go` 日志 Send 为集群内 gRPC 日志流；`pkg/component/storage/*` 上传绑定均为本地/内网存储标识；`api/controller/chunk_upload_example.js` 为相对路径 `/package_build` 的内网分片上传示例；`grctl/cluster/vergion.go` 为 CRD 模板无网络行为；`api/util/license/rsa_license.go` base64 仅本地验签无回调。

全库未发现：`eval`/`new Function`/远端脚本下载执行、ngrok/frp 类内网穿透、base64 混淆载荷外发、websocket 主动外连、pushgateway 外发；etcd/K8s/Prometheus/console 回调均为内网业务请求（放行标记）。`go.mod` 中 OpenTelemetry 相关依赖均为 indirect（来自 client-go），源码中无 OTLP 导出器调用。

## 确认为内网/集群内业务请求（放行标记）

| 位置 | 目标 | 说明 |
|---|---|---|
| `worker/master/volumes/provider/rainbondsslc.go:171` | `http://<ip>:6100/v2/localvolumes/create` | rbd-node 存储接口，集群内节点 IP |
| `api/controller/kubeblocks.go:19,161,181` | `http://kb-adapter-rbdplugin.rbd-plugins.svc:8080` | 集群内 svc 转发 |
| `pkg/component/es/esComponent.go:106` | 集群内 ES | BasicAuth 出站（见附带备注） |
| `mq/client/client.go:88`、`worker/client/client.go:65`、`util/criutil/criutil.go:38` | rbd-mq / worker / CRI | 集群内组件互联 |
| `builder/sources/trust.go:56-71` | 用户/默认镜像 registry | 构建时校验，业务需要 |
| `worker/master/controller/thirdcomponent/prober/runtime_probe.go:59-74` | 用户配置的探活地址 | 业务探测（见附带备注） |

误报排除：`config/configs/` 中的 `goodrain.com`（证书路径）、`api/controller/apigateway/api_gateway_route.go:763` 与 `worker/appm/conversion/gateway.go:278,293` 的 `rainbond.com/...` 均为 k8s annotation key / 默认值，非网络外发。

---

## 修复状态（2026-11-09）

### 已完成的代码修复

| 编号 | 问题 | 修复位置 | 修复方式 |
|---|---|---|---|
| 发现1 | 明文 HTTP 向公网 `domain.grapps.cn` 发送集群 IP + auth | `grctl/cmd/replace.go` | 泛域名后缀服务改为 opt-in（`RBD_DOMAIN_SUFFIX_API`），未配置则不发起请求；接口强制 HTTPS，接入白名单校验 |
| 发现2 | `SendtoConsole` 明文传输客户端私钥 | `grctl/cmd/replace.go` | 目标地址强制 HTTPS（`RBD_EGRESS_ALLOW_INSECURE` 可显式放开）、支持 `RBD_EGRESS_HOST_ALLOWLIST` 白名单 |
| 发现3 | Sentry 遥测默认开启 | `pkg/observability/sentry/config.go` | 改为显式 opt-in，仅配置 DSN 不再上报，必须 `RAINBOND_ERROR_REPORTING_ENABLED=true` |
| 发现4 | VM 镜像源可指向任意地址（SSRF） | `builder/exector/build_from_vm.go`、`builder/parser/vm_service.go` | 请求前统一走 `pkg/security/egress` 校验 |
| 发现5 | Helm 仓库凭据可外发 | `api/handler/helm.go` | 拉取 `index.yaml` 前校验目标地址 |
| 发现6 | 构建依赖默认连公网 | 未改代码 | 通过 `BP_DEPENDENCY_MIRROR` 配置内网镜像 |

新增公共组件：`pkg/security/egress`（默认拒绝明文 HTTP、始终拦截 169.254.169.254 等链路本地/元数据地址，支持主机白名单与私网阻断开关）。

### 本地真实链路验证（k3s + MariaDB + rbd-api）

| 验证项 | 结果 |
|---|---|
| 服务启动并监听 37070 / 37071 | 通过，`/healthz` 200 |
| 创建团队 / 应用 / 组件（带 service_id） | 通过 |
| 空 `service_id` 创建组件 | 400 拒绝，数据库不再产生孤儿记录（修复：`api/controller/resources.go`） |
| `GET /appstatuses?app_ids=...` | 不再 400 EOF（修复：`api/controller/application.go`） |
| `/logs/request.log` | 目录自动创建并写入（修复：`api/server/api.go`） |
| `KUBECONFIG` 回退 | 集群外可启动（修复：`util/k8s/k8s.go`） |

### 遗留事项

1. `rbd-worker` 在无 apisix / kruise / gateway-api 等第三方 CRD 的环境下会阻塞在 controller-runtime 缓存同步，且 `worker/appm/store/store.go:372` 使用 `for !a.Ready() {}` 无超时忙等，缺少可观测的失败提示。
2. 默认 `--storage-type s3` 指向 `minio-service:9000`，本地无对象存储时出现持续告警；本地调试建议 `--storage-type local`。
3. `rbd-hub` 未部署时 hub 客户端每 10 秒重试，日志噪声较大。
4. 清理了修复前测试产生的 `service_id` 为空的脏数据（`tenant_services`、`tenant_services_label`、`tenant_services_event`）。

---

## 控制台（rainbond-console）遥测审计（2026-11-09）

### 风险等级：高

【位置】
- `rainbond-console/console/services/telemetry.py`
- `rainbond-console/console/services/telemetry_switch.py`
- `rainbond-console/goodrain_web/sentry_config.py`
- `rainbond-console/console/views/posthog_proxy.py`、`console/views/sentry_proxy.py`

【风险描述】控制台内置 PostHog 遥测，**默认开启**，向硬编码公网地址 `https://posthog.goodrain.com` 上报实例信息：

| 项 | 内容 |
|---|---|
| 上报地址 | `https://posthog.goodrain.com/batch/`（硬编码默认值，可被 `RAINBOND_POSTHOG_SERVER_HOST` 等覆盖） |
| 内置凭证 | 硬编码项目 token `phc_oCoPw...`（源码可见） |
| 上报字段 | `instance_id`（随机 UUID，持久化于 `console_sys_config`）、`console_version`、`rainbond_version`、`edition`、`install_time`、`days_since_install` |
| 事件 | `rainbond_instance_registered`、`rainbond_instance_heartbeat`（每日一次）、`rainbond_app_created`（含 region_name / app_type / is_first_app）、`rainbond_component_created` |
| 默认状态 | 数据库无开关记录时 `enabled = True`（`telemetry_switch.py:62`），即 **opt-out 默认上报** |
| 脱敏 | 有：token/password/email/url/domain/app_name 等键被过滤，但实例 ID 与版本信息原样上报 |

【判定理由】"读取实例信息 + 硬编码公网地址 + 默认开启 + 后台异步发送" 四条特征齐备，属典型默认遥测，且用户首次注册即触发。

【实际证据】本地部署后数据库出现：

```
RBD_TELEMETRY_INSTANCE_ID = 77dc37f1...
RBD_TELEMETRY_REGISTERED  = true
RBD_TEL_HB_20261109       = true      # 当日心跳已记录
```

目标域名实测可直连（`302`，0.31s），说明请求已实际发出。

【修复建议与已执行处置】
1. 数据库开关 `EXTERNAL_TELEMETRY_ENABLED.enable = false`
2. 启动注入 `RAINBOND_TELEMETRY_DISABLED=true`、`POSTHOG_DISABLED=true`
3. 清理已写入的 `RBD_TEL*` 标记
4. 修复上游缺陷：`track_instance_registered` / `track_instance_heartbeat` / `track_app_created` 在遥测关闭时仍会写入 marker，已在函数入口增加 `is_enabled()` 判断
5. 验证：抓包 35 秒 0 数据包，三个上报函数均返回 `False`，数据库无遥测记录

【遗留】
- 前端仍保留 `/console/posthog`、`/console/sentry` 代理路由，建议在网关层封禁
- 控制台侧 Sentry 源码构建默认关闭（需 DSN），但发布镜像可能注入

### 版本核对结论

- 上游 `goodrain/rainbond` main 与本地 fork 同一提交 `bbb1e5bdd`（`v6.10.3-release`），Go 后端无需升级
- "有新版本"提示由控制台版本检查产生，该版本新增的即为上述遥测能力

---

## 控制台外联通路复核与封禁（2026-11-10）

在遥测开关关闭之后，对控制台做了一次完整的外联复核，确认仍存在两类**非遥测**的厂商外联，并全部封禁。

### 复核方法

| 手段 | 说明 |
|---|---|
| 源码检索 | 在 `rainbond-console` 全仓检索 `grapps.cn` / `goodrain.com` / `rainbond.com` / `posthog` / `sentry` |
| 接口实测 | 携带有效 JWT 调用 `/console/update/versions`，观察是否返回远端真实数据 |
| DNS 验证 | `getent hosts` 确认域名可解析（说明只是"不发"，不是"解析不了"） |
| 连通性验证 | `curl` 直连厂商域名，确认网络层可达 |

### 发现一：版本检查外联 `get.rainbond.com`

```
console/views/upgrade.py:48
JSON_URL = os.getenv("VERSION_INFO_URL", "https://get.rainbond.com/upgrade-versions.json")
response = requests.get(JSON_URL, timeout=VERSION_INFO_TIMEOUT)   # 无缓存，每次实时拉取
```

实测 `/console/update/versions` 返回真实版本列表（`v6.10.3-release` 等），证明外联成功。外发内容为普通 GET（出口 IP、时间、默认 UA），无实例 ID、无版本号、无集群信息 → **风险等级：低**，但属不必要的外部依赖。

### 发现二：云市场外联 `hub.grapps.cn`

```
app_market 表：('RainbondMarket', 'https://hub.grapps.cn', 'rainstore', 'rainbond')   # 默认启用
console/views/app_server_proxy.py:14   target_base_url = 'https://hub.grapps.cn'
console/views/center_pool/apps.py:186  market_domain = "https://hub.grapps.cn"
```

打开「应用市场 / 云端组件库」时控制台代理拉取模板元数据（MySQL 版本列表等）。外发内容本身不敏感，但**返回的模板内容（镜像地址、启动参数、Chart）不可控** → **风险等级：中**。

### 处置（已执行）

| 层 | 动作 | 结果 |
|---|---|---|
| 环境变量 | 控制台启动注入 `DISABLE_CLOUD_MARKET=true`（写入 `scripts/local-stack.sh`） | `is_cloud_market_disabled()` 短路版本检查与市场拉取 |
| 主机解析 | `/etc/hosts` 将 5 个厂商域名指向 `127.0.0.1` | 主机进程快速失败 |
| 网络层 | `iptables` 自定义链 `RBD_VENDOR_BLOCK`，按公网 DNS 解析结果 REJECT | 覆盖自定义解析器等绕过 hosts 的场景 |
| 脚本化 | 新增 `scripts/block-vendor-egress.sh {enable|disable|status}` | 可重复执行、幂等 |

封禁域名清单：

```
get.rainbond.com      版本检查
hub.grapps.cn         云端组件库 / 应用市场
posthog.goodrain.com  PostHog 遥测
sentry.goodrain.com   Sentry 错误上报
domain.grapps.cn      grctl 域名后缀服务
```

### 验证结果

```
/console/update/versions        → []            （原为完整版本列表）
curl get.rainbond.com           → BLOCKED
curl hub.grapps.cn              → BLOCKED
curl posthog.goodrain.com       → BLOCKED
curl sentry.goodrain.com        → BLOCKED
控制台应用列表 / 组件操作        → 200           （功能未受影响）
```

### 遗留

1. `/etc/hosts` 只对主机进程生效，**容器内进程仍需网络层规则**：脚本的 `--with-forward` 可把同一链挂到 FORWARD，或在集群出口网关统一封禁
2. 云市场关闭后，控制台「应用市场」页面为空属预期；组件来源改为**镜像直连创建**或**本地组件库**
