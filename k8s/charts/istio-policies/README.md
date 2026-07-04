# Hướng dẫn cấu hình Service Mesh với Istio cho hệ thống YAS Microservices

---

## Mục lục

1. [Giới thiệu](#1-giới-thiệu)
2. [Kiến trúc tổng quan](#2-kiến-trúc-tổng-quan)
3. [Cấu trúc thư mục và file cấu hình](#3-cấu-trúc-thư-mục-và-file-cấu-hình)
4. [Yêu cầu tiên quyết](#4-yêu-cầu-tiên-quyết)
5. [Triển khai từng bước](#5-triển-khai-từng-bước)
   - 5.1 [Cài đặt Istio lên Kubernetes](#51-cài-đặt-istio-lên-kubernetes)
   - 5.2 [Bật Istio Injection cho namespace](#52-bật-istio-injection-cho-namespace)
   - 5.3 [Cấu hình mTLS STRICT (Mã hoá đường truyền)](#53-cấu-hình-mtls-strict)
   - 5.4 [Cấu hình Authorization Policy (Chính sách kết nối)](#54-cấu-hình-authorization-policy)
   - 5.5 [Cấu hình Retry Policy (Tự động thử lại khi lỗi)](#55-cấu-hình-retry-policy)
   - 5.6 [Quan sát topology bằng Kiali](#56-quan-sát-topology-bằng-kiali)
6. [Kịch bản test và kết quả](#6-kịch-bản-test-và-kết-quả)
   - 6.1 [TEST 1 -- mTLS STRICT: Pod ngoài mesh bị chặn](#61-test-1----mtls-strict-pod-ngoài-mesh-bị-chặn)
   - 6.2 [TEST 2 -- Authorization Policy DENY: Service không có quyền bị 403](#62-test-2----authorization-policy-deny)
   - 6.3 [TEST 3 -- Authorization Policy ALLOW: Service có quyền được 200](#63-test-3----authorization-policy-allow)
   - 6.4 [TEST 4 -- Retry Policy: Envoy tự động retry khi gặp lỗi 503](#64-test-4----retry-policy)
7. [Chạy script test tự động](#7-chạy-script-test-tự-động)
8. [Bảng tổng hợp kết quả test](#8-bảng-tổng-hợp-kết-quả-test)
9. [Các lệnh kiểm tra nhanh](#9-các-lệnh-kiểm-tra-nhanh)
10. [Xử lý sự cố thường gặp](#10-xử-lý-sự-cố-thường-gặp)

---

## 1. Giới thiệu

Tài liệu này hướng dẫn triển khai **Service Mesh** bằng **Istio** trên Kubernetes cho hệ thống YAS (Yet Another Shop) gồm 14 microservices. Toàn bộ cấu hình được đóng gói dưới dạng Helm chart và triển khai tự động thông qua ArgoCD theo mô hình GitOps.

Service Mesh giải quyết 3 vấn đề chính trong kiến trúc microservices:

- **Mã hoá đường truyền (mTLS):** Mọi giao tiếp giữa các service đều được mã hoá TLS hai chiều. Ứng dụng không cần sửa code -- Envoy sidecar proxy xử lý hoàn toàn trong suốt.
- **Kiểm soát truy cập (Authorization Policy):** Chỉ những service được khai báo rõ ràng mới có quyền gọi sang service khác. Áp dụng mô hình Zero Trust: chặn tất cả mặc định, chỉ mở dần theo nhu cầu.
- **Xử lý lỗi tự động (Retry Policy):** Khi service trả về lỗi 5xx, Envoy sidecar của caller tự động gửi lại request mà ứng dụng không cần viết retry logic.

---

## 2. Kiến trúc tổng quan

```
                              EXTERNAL TRAFFIC
                                    |
                                    v
                        +-----------------------+
                        |   Nginx Ingress       |
                        |   Controller          |
                        +----------+------------+
                                   |
            +----------------------v--------------------------+
            |                 Namespace: dev                  |
            |                                                 |
            |  +---------------+         +---------------+    |
            |  | storefront-bff|  mTLS   |   product     |    |
            |  |   [Envoy]     |-------->|   [Envoy]     |    |
            |  +-------+-------+         +-------+-------+    |
            |          |                         |            |
            |          | mTLS                    | TCP        |
            |          v                         v            |
            |  +---------------+         +---------------+    |
            |  |   cart        |         | postgresql    |    |
            |  |   [Envoy]     |         | (không Envoy) |    |
            |  +---------------+         +---------------+    |
            |                                                 |
            |  + 10 services khác (order, customer,           |
            |    inventory, tax, media, search...)            |
            +-------------------------------------------------+
                         |
              +----------v-----------+
              |  Namespace:          |
              |  istio-system        |
              |                      |
              |  istiod              |  <-- Control Plane
              |  (Istio CA)          |      Cấp certificate
              |                      |      Phân phối config
              |  Kiali               |  <-- Dashboard topology
              |  Prometheus          |  <-- Thu thập metrics
              +----------------------+
```

**Giải thích các thành phần:**

| Thành phần | Vị trí | Chức năng |
|---|---|---|
| istiod | Namespace istio-system | Control plane: cấp certificate X.509 cho mỗi pod dựa trên ServiceAccount, phân phối cấu hình mTLS/AuthzPolicy/Retry xuống Envoy sidecar |
| Envoy sidecar | Mỗi pod trong namespace dev | Proxy chặn mọi traffic vào/ra pod. Thực hiện mã hoá TLS, kiểm tra quyền truy cập, retry lỗi -- tất cả trong suốt với ứng dụng |
| Kiali | Namespace istio-system | Dashboard hiển thị topology real-time, traffic flow, tỷ lệ lỗi, trạng thái mTLS giữa các service |
| Prometheus | Namespace istio-system | Thu thập metrics từ Envoy sidecar (request count, latency, error rate) để cung cấp dữ liệu cho Kiali |

**Nguyên lý hoạt động:**

Khi bật Istio injection cho namespace `dev`, mỗi pod được tự động thêm một container phụ gọi là Envoy sidecar. Mọi traffic vào và ra pod đều đi qua Envoy trước khi tới ứng dụng thật. Envoy chịu trách nhiệm mã hoá TLS, kiểm tra quyền truy cập, và thực hiện retry. Ứng dụng bên trong pod không cần sửa bất kỳ dòng code nào -- nó vẫn gọi HTTP bình thường, Envoy tự động nâng cấp thành mTLS.

---

## 3. Cấu trúc thư mục và file cấu hình

Toàn bộ cấu hình Istio được đóng gói trong Helm chart tại:

```
yas-gitops/k8s/charts/istio-policies/
|-- Chart.yaml                              # Khai báo metadata của Helm chart
|-- values.yaml                             # Tham số cấu hình (namespace, retry config)
|-- templates/
    |-- mtls.yaml                           # PeerAuthentication + DestinationRule
    |-- destination-rules-infra.yaml        # Tắt mTLS cho hạ tầng không có Envoy
    |-- authz.yaml                          # 16 AuthorizationPolicy (deny-all + per-service)
    |-- virtual-services.yaml               # Retry policy cho các backend services
```

Script test đặt tại:

```
yas-devops-1/k8s-infrastructure-scripts/
|-- test-service-mesh.ps1                   # Script tự động chạy 4 kịch bản test
```

**Giải thích từng file:**

| File | Loại resource Istio | Mục đích |
|---|---|---|
| mtls.yaml | PeerAuthentication, DestinationRule | Bật mTLS STRICT toàn namespace, bắt buộc mọi kết nối phải dùng certificate |
| destination-rules-infra.yaml | DestinationRule | Tắt mTLS khi gọi tới PostgreSQL, Redis, Kafka, Elasticsearch (không có Envoy) |
| authz.yaml | AuthorizationPolicy | Khai báo deny-all mặc định + 15 rule cho phép từng cặp service giao tiếp |
| virtual-services.yaml | VirtualService | Cấu hình retry 3 lần, timeout 5s/lần cho 10 backend services |

---

## 4. Yêu cầu tiên quyết

Trước khi triển khai Service Mesh, hệ thống cần có sẵn:

- Minikube v1.38 trở lên với Docker driver, cấp ít nhất 12GB RAM và 6 CPU
- Kubernetes v1.28 trở lên
- 14 microservices đã deploy trong namespace `dev` thông qua ArgoCD
- Hạ tầng dùng chung đã chạy: PostgreSQL (namespace postgres), Redis (namespace redis), Kafka (namespace kafka), Elasticsearch (namespace elasticsearch)

Kiểm tra nhanh:

```powershell
# Xác nhận Minikube đang chạy
minikube status

# Xác nhận kubectl kết nối đúng cluster
kubectl cluster-info

# Xác nhận namespace dev có pod đang chạy
kubectl get pods -n dev
```

---

## 5. Triển khai từng bước

### 5.1 Cài đặt Istio lên Kubernetes

**Bước 1:** Tải istioctl (công cụ dòng lệnh của Istio, chỉ cần làm một lần):

```powershell
Invoke-WebRequest `
  -Uri "https://github.com/istio/istio/releases/download/1.26.1/istioctl-1.26.1-win-amd64.zip" `
  -OutFile "istioctl.zip" -UseBasicParsing

Expand-Archive -Path "istioctl.zip" -DestinationPath "istioctl-bin" -Force
```

**Bước 2:** Kiểm tra cluster đủ điều kiện cài Istio:

```powershell
.\istioctl-bin\istioctl.exe x precheck
```

Kết quả mong đợi: tất cả các mục đều hiện `Install Pre-Check passed`.

**Bước 3:** Cài Istio với profile demo:

```powershell
.\istioctl-bin\istioctl.exe install --set profile=demo -y
```

Profile `demo` bao gồm đầy đủ: istiod (control plane) + ingress gateway + egress gateway. Đây là profile phù hợp cho môi trường học tập.

**Bước 4:** Cài Kiali (dashboard topology) và Prometheus (thu thập metrics):

```powershell
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/addons/prometheus.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/addons/kiali.yaml
```

**Bước 5:** Kiểm tra Istio đã cài thành công:

```powershell
kubectl get pods -n istio-system
```

Kết quả mong đợi (tất cả pod ở trạng thái Running):

```
NAME                                    READY   STATUS    RESTARTS   AGE
istiod-75cf956749-qkdjw                 1/1     Running   0          5m
istio-ingressgateway-cfb6f6999-gh8kl    1/1     Running   0          5m
istio-egressgateway-765d694f69-h5dzn    1/1     Running   0          5m
kiali-5c87c84765-4wrgg                  1/1     Running   0          3m
prometheus-5dcf95999d-x7zvg             2/2     Running   0          3m
```

---

### 5.2 Bật Istio Injection cho namespace

**Bước 1:** Gán label `istio-injection=enabled` cho namespace `dev`:

```powershell
kubectl label namespace dev istio-injection=enabled --overwrite
```

Lệnh này báo cho Istio: tự động inject Envoy sidecar vào mọi pod được tạo mới trong namespace `dev`.

**Bước 2:** Restart tất cả deployment để các pod hiện tại nhận Envoy sidecar:

```powershell
kubectl rollout restart deployment -n dev
```

**Bước 3:** Kiểm tra kết quả:

```powershell
kubectl get pods -n dev
```

Kết quả mong đợi: cột READY hiện `2/2` cho mỗi pod, nghĩa là 2 container đang chạy trong mỗi pod:
- Container thứ nhất: Ứng dụng thật (product, cart, tax...)
- Container thứ hai: Envoy sidecar do Istio tự động inject

```
NAME                              READY   STATUS    RESTARTS   AGE
product-78fcdd858f-mttpn          2/2     Running   0          5m
cart-76d54578cd-84d4x             2/2     Running   0          5m
storefront-bff-64f49dffdd-ddscj   2/2     Running   0          5m
tax-6f78bd6c78-vbtmx              2/2     Running   0          5m
```

Nếu pod nào hiện `1/2`, Envoy chưa được inject. Restart lại deployment đó:

```powershell
kubectl rollout restart deployment/<ten-service> -n dev
```

---

### 5.3 Cấu hình mTLS STRICT

#### Mục đích

mTLS (mutual TLS) đảm bảo mọi giao tiếp giữa các service trong namespace `dev` đều được:
- **Mã hoá:** Traffic không thể bị nghe lén trên đường mạng
- **Xác thực hai chiều:** Cả hai phía (caller và receiver) đều phải xuất trình certificate hợp lệ do Istio CA cấp
- **Chặn kết nối không hợp lệ:** Pod không có Envoy sidecar (không có certificate) bị từ chối ngay lập tức

#### File cấu hình: `templates/mtls.yaml`

File này chứa 2 object Kubernetes:

**Object 1 -- PeerAuthentication (phía nhận traffic):**

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-mtls
spec:
  mtls:
    mode: STRICT
```

Giải thích:
- Áp dụng cho toàn bộ namespace `dev` (không có `selector` nên là mặc định cho cả namespace)
- `mode: STRICT` bắt buộc mọi kết nối vào pod phải dùng TLS với certificate hợp lệ
- Nếu kết nối bằng HTTP thường (không có certificate) thì bị từ chối ngay lập tức tại tầng transport (Connection reset by peer)

**Object 2 -- DestinationRule (phía gửi traffic):**

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: default-mtls-outbound
spec:
  host: "*.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

Giải thích:
- Wildcard `*.svc.cluster.local` áp dụng cho tất cả service trong cluster
- `mode: ISTIO_MUTUAL` bắt buộc Envoy sidecar của caller phải:
  1. Mã hoá packet thành TLS
  2. Gắn certificate SPIFFE vào request, ví dụ: `cluster.local/ns/dev/sa/storefront-bff`
- Ứng dụng vẫn gọi `http://product/...` bình thường, Envoy tự động nâng cấp thành mTLS

#### Luồng mTLS giữa storefront-bff và product

```
[storefront-bff App]
      | Gọi http://product/... (HTTP thường)
      v
[Envoy của storefront-bff]
      | DestinationRule: mode ISTIO_MUTUAL
      | --> Mã hoá TLS
      | --> Gắn certificate: "cluster.local/ns/dev/sa/storefront-bff"
      |
      | ====== TLS Encrypted ==============================
      v
[Envoy của product]
      | PeerAuthentication: mode STRICT
      | --> Giải mã TLS
      | --> Kiểm tra certificate có do Istio CA cấp? --> Hợp lệ
      v
[product App]  <-- Nhận request HTTP bình thường, không biết gì về mTLS
```

#### Ngoại lệ cho hạ tầng không có Envoy

**File:** `templates/destination-rules-infra.yaml`

PostgreSQL, Redis, Kafka, Elasticsearch chạy ở các namespace riêng và không có Envoy sidecar. Nếu không có ngoại lệ, các service trong mesh sẽ không kết nối được tới chúng vì Envoy sẽ cố gửi TLS nhưng phía nhận không hiểu.

```yaml
# Tắt mTLS khi gọi tới PostgreSQL
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: disable-mtls-postgres
spec:
  host: "*.postgres.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: DISABLE
---
# Tắt mTLS khi gọi tới Redis
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: disable-mtls-redis
spec:
  host: "*.redis.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: DISABLE
---
# Tắt mTLS khi gọi tới Kafka
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: disable-mtls-kafka
spec:
  host: "*.kafka.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: DISABLE
---
# Tắt mTLS khi gọi tới Elasticsearch
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: disable-mtls-elasticsearch
spec:
  host: "*.elasticsearch.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: DISABLE
```

Mỗi DestinationRule với `mode: DISABLE` cho phép Envoy gửi traffic thường (không mã hoá) khi gọi tới các dịch vụ hạ tầng này.

---

### 5.4 Cấu hình Authorization Policy

#### Mục đích

Authorization Policy kiểm soát **service nào được phép gọi service nào** trong mesh. Cơ chế này hoạt động sau khi mTLS đã xác thực xong: Envoy đọc identity từ certificate của caller và kiểm tra có nằm trong danh sách cho phép không.

Identity của mỗi service có dạng SPIFFE: `cluster.local/ns/<namespace>/sa/<service-account>`

#### File cấu hình: `templates/authz.yaml`

File này chứa 16 AuthorizationPolicy, bao gồm 1 policy deny-all mặc định và 15 policy cho phép từng service cụ thể.

**Phần 1 -- Default Deny (Chặn tất cả mặc định):**

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: dev
spec: {}
```

Giải thích: `spec: {}` nghĩa là không có bất kỳ rule nào cho phép. Trong Istio, khi namespace có ít nhất một AuthorizationPolicy mà request không khớp rule nào thì bị từ chối (HTTP 403). Đây là nguyên tắc Zero Trust: chặn tất cả trước, chỉ mở dần theo nhu cầu.

**Phần 2 -- Cho phép truy cập vào các Frontend và BFF (public):**

Các service đóng vai trò cổng vào hệ thống (nhận traffic từ Ingress Controller hoặc trình duyệt) cần được mở cho tất cả:

```yaml
# Cho phép mọi traffic vào storefront-bff (nhận traffic từ Nginx Ingress)
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-to-storefront-bff
  namespace: dev
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: storefront-bff
  action: ALLOW
  rules:
    - {}    # Cho phép tất cả nguồn
```

Tương tự cho: storefront-ui, backoffice-ui, backoffice-bff, swagger-ui, sampledata.

**Phần 3 -- Cho phép BFF gọi tới Backend Services (có giới hạn):**

Các backend service (product, cart, order, customer, inventory, tax, media, search) chỉ cho phép một số service cụ thể gọi vào, dựa trên danh sách `principals`:

```yaml
# Chỉ cho phép storefront-bff, backoffice-bff, sampledata gọi tới product
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-to-product
  namespace: dev
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: product
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/dev/sa/storefront-bff"
              - "cluster.local/ns/dev/sa/backoffice-bff"
              - "cluster.local/ns/dev/sa/sampledata"
```

Giải thích từng trường:
- `selector.matchLabels`: Xác định policy này áp dụng cho pod nào (pod có label `app.kubernetes.io/name: product`)
- `action: ALLOW`: Cho phép kết nối
- `principals`: Danh sách identity (lấy từ certificate mTLS) của các service được phép gọi vào. Format: `cluster.local/ns/<namespace>/sa/<service-account>`

Nếu `tax` (không có trong danh sách principals) cố gọi `product`, Envoy của product sẽ trả về `HTTP 403 Forbidden` ngay tại tầng mạng mà không chuyển request vào ứng dụng.

**Phần 4 -- Cho phép tất cả gọi tới Keycloak:**

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-all-to-keycloak
  namespace: dev
spec:
  selector:
    matchLabels:
      app: keycloak
  action: ALLOW
  rules:
    - {}    # Tất cả service đều cần xác thực JWT qua Keycloak
```

#### Bảng tổng hợp 16 chính sách

| STT | Tên chính sách | Service được bảo vệ | Service được phép gọi vào |
|---|---|---|---|
| 1 | deny-all | Toàn bộ namespace dev | Không ai (mặc định chặn) |
| 2 | allow-to-storefront-ui | storefront-ui | Tất cả |
| 3 | allow-to-storefront-bff | storefront-bff | Tất cả |
| 4 | allow-to-backoffice-ui | backoffice-ui | Tất cả |
| 5 | allow-to-backoffice-bff | backoffice-bff | Tất cả |
| 6 | allow-to-swagger-ui | swagger-ui | Tất cả |
| 7 | allow-to-sampledata | sampledata | Tất cả |
| 8 | allow-to-product | product | storefront-bff, backoffice-bff, sampledata |
| 9 | allow-to-cart | cart | storefront-bff, backoffice-bff, sampledata |
| 10 | allow-to-order | order | storefront-bff, backoffice-bff, sampledata |
| 11 | allow-to-customer | customer | storefront-bff, backoffice-bff, sampledata |
| 12 | allow-to-inventory | inventory | storefront-bff, backoffice-bff, sampledata |
| 13 | allow-to-tax | tax | storefront-bff, backoffice-bff, sampledata |
| 14 | allow-to-media | media | storefront-bff, backoffice-bff, sampledata |
| 15 | allow-to-search | search | storefront-bff, backoffice-bff, sampledata |
| 16 | allow-all-to-keycloak | keycloak | Tất cả |

---

### 5.5 Cấu hình Retry Policy

#### Mục đích

Khi một service tạm thời bị lỗi (trả về HTTP 5xx), Envoy sidecar của caller tự động gửi lại request mà ứng dụng không cần biết. Điều này giúp hệ thống chịu lỗi tốt hơn trước các sự cố tạm thời như service đang khởi động lại, quá tải nhất thời, hoặc mạng chập chờn.

#### File cấu hình: `templates/virtual-services.yaml`

File này sử dụng Helm template để sinh VirtualService cho nhiều service cùng lúc:

```yaml
{{- range .Values.retryServices }}
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: {{ . }}-retry
  namespace: {{ $.Values.namespace }}
spec:
  hosts:
    - {{ . }}
  http:
    - retries:
        attempts: {{ $.Values.retryPolicy.attempts }}
        perTryTimeout: {{ $.Values.retryPolicy.perTryTimeout }}
        retryOn: {{ $.Values.retryPolicy.retryOn }}
      timeout: {{ $.Values.retryPolicy.timeout }}
      route:
        - destination:
            host: {{ . }}
            port:
              number: 80
{{- end }}
```

#### Giá trị cấu hình trong `values.yaml`

```yaml
namespace: dev

retryPolicy:
  enabled: true
  attempts: 3
  perTryTimeout: 5s
  timeout: 20s
  retryOn: "5xx,gateway-error,connect-failure,retriable-4xx"

retryServices:
  - product
  - cart
  - order
  - customer
  - inventory
  - tax
  - media
  - search
  - promotion
  - sampledata
```

#### Giải thích từng tham số

| Tham số | Giá trị | Ý nghĩa |
|---|---|---|
| attempts | 3 | Tổng cộng 3 lần thử. Lần đầu là request bình thường, 2 lần sau là retry |
| perTryTimeout | 5s | Mỗi lần thử chờ tối đa 5 giây. Quá 5 giây không có response thì tính là thất bại và chuyển sang lần thử tiếp theo |
| timeout | 20s | Tổng thời gian tối đa cho cả request lẫn retry. Quá 20 giây thì dừng lại hoàn toàn |
| retryOn | 5xx,gateway-error,connect-failure,retriable-4xx | Điều kiện kích hoạt retry: lỗi server 5xx, lỗi gateway (502/503/504), mất kết nối, và một số lỗi 4xx có thể retry (ví dụ 409 Conflict) |

Cấu hình này được áp dụng cho 10 backend services. Khi Helm render template, nó sẽ sinh ra 10 VirtualService riêng biệt (product-retry, cart-retry, order-retry...).

---

### 5.6 Quan sát topology bằng Kiali

#### Mở Kiali Dashboard

```powershell
kubectl port-forward svc/kiali 20001:20001 -n istio-system
```

Truy cập: http://localhost:20001

Giữ terminal này luôn chạy. Kiali sẽ không hoạt động nếu đóng terminal.

#### Cấu hình hiển thị trên Kiali

Trên giao diện Kiali:

1. Chọn **Graph** ở menu bên trái
2. Namespace: chọn **dev**
3. Graph type: **Versioned app graph**
4. Time range: **Last 5m** (góc trên bên phải)
5. Nhấn nút **Display** --> bật **Security** để hiện biểu tượng mTLS trên các đường kết nối

#### Sinh traffic để Kiali có dữ liệu hiển thị

Kiali chỉ hiển thị traffic đã xảy ra trong khoảng thời gian được chọn. Cần sinh traffic trước khi xem graph:

```powershell
for ($i = 1; $i -le 20; $i++) {
    kubectl exec -n dev deployment/storefront-bff -- `
        wget -q -O /dev/null `
        "http://product.dev.svc.cluster.local/product/storefront/products/featured" 2>$null
    Start-Sleep -Milliseconds 500
}
```

#### Đọc hiểu topology graph

Trên Kiali Graph sẽ hiển thị:

- **Các node (hình tròn/vuông):** Mỗi node là một workload (product, cart, storefront-bff...)
- **Các mũi tên:** Hướng traffic đang chảy giữa các service
- **Ô vuông nhỏ màu xanh lá trên mũi tên:** Biểu tượng mTLS, xác nhận kết nối đang được mã hoá
- **Màu sắc mũi tên:** Xanh lá = thành công (2xx), Đỏ = có lỗi (4xx/5xx)
- **Panel bên phải:** HTTP success rate, error rate, throughput (requests per second)

---

## 6. Kịch bản test và kết quả

### 6.1 TEST 1 -- mTLS STRICT: Pod ngoài mesh bị chặn

**Mục đích:** Chứng minh PeerAuthentication mode STRICT hoạt động đúng -- pod không có Envoy sidecar không thể gọi vào service trong mesh.

**Lệnh:**

```powershell
kubectl run mtls-test --image=curlimages/curl --namespace=default `
  --rm -it --restart=Never -- `
  curl -v --max-time 5 http://product.dev.svc.cluster.local/product/storefront/products/featured
```

**Kết quả mong đợi:**

```
* Host product.dev.svc.cluster.local:80 was resolved.
* IPv6: (none)
* IPv4: 10.98.61.147
*   Trying 10.98.61.147:80...
* Established connection to product.dev.svc.cluster.local port 80
* using HTTP/1.x
> GET /product/storefront/products/featured HTTP/1.1
> Host: product.dev.svc.cluster.local
> User-Agent: curl/8.21.0
> Accept: */*
>
* Request completely sent off
* Recv failure: Connection reset by peer
* closing connection #0
curl: (56) Recv failure: Connection reset by peer
```

**Giải thích:**
- Pod `mtls-test` được tạo trong namespace `default` -- namespace này không có Istio injection, nên pod không có Envoy sidecar và không có certificate
- Pod gửi HTTP thường tới `product.dev.svc.cluster.local`
- Envoy sidecar của `product` nhận được packet nhưng đang chờ TLS handshake
- Không nhận được TLS handshake --> Envoy reset kết nối ngay lập tức
- `Connection reset by peer` là bằng chứng trực tiếp rằng mTLS STRICT đang hoạt động

**File cấu hình liên quan:** `mtls.yaml` dòng 1-7 (PeerAuthentication mode: STRICT)

---

### 6.2 TEST 2 -- Authorization Policy DENY

**Mục đích:** Chứng minh AuthorizationPolicy chặn đúng service không có quyền. Service `tax` không nằm trong danh sách principals của `allow-to-customer`, nên phải bị từ chối.

**Lệnh:**

```powershell
kubectl exec -n dev deployment/tax -- `
  wget -S -q -O /dev/null --timeout=5 `
  "http://customer.dev.svc.cluster.local/customer/storefront/customers/profile"
```

**Kết quả mong đợi:**

```
  HTTP/1.1 403 Forbidden
wget: server returned error: HTTP/1.1 403 Forbidden
```

**Giải thích:**
- Pod `tax` nằm trong mesh, có Envoy sidecar và certificate hợp lệ (mTLS pass)
- Envoy của `customer` nhận request, đọc identity từ certificate: `cluster.local/ns/dev/sa/tax`
- Kiểm tra danh sách principals của `allow-to-customer`: chỉ có storefront-bff, backoffice-bff, sampledata
- `tax` không khớp bất kỳ rule nào --> `deny-all` áp dụng --> trả về HTTP 403
- Lưu ý: 403 xảy ra tại tầng Envoy, request không bao giờ tới ứng dụng `customer`

**File cấu hình liên quan:** `authz.yaml` dòng 1-7 (deny-all) và dòng 150-167 (allow-to-customer)

---

### 6.3 TEST 3 -- Authorization Policy ALLOW

**Mục đích:** Chứng minh AuthorizationPolicy cho phép đúng service có quyền. Service `storefront-bff` nằm trong danh sách principals của `allow-to-product`, nên phải được chấp nhận.

**Lệnh:**

```powershell
kubectl exec -n dev deployment/storefront-bff -- `
  wget -S -q -O /dev/null --timeout=10 `
  "http://product.dev.svc.cluster.local/product/storefront/products/featured"
```

**Kết quả mong đợi:**

```
  HTTP/1.1 200 OK
  vary: Origin,Access-Control-Request-Method,Access-Control-Request-Headers
  x-content-type-options: nosniff
  x-xss-protection: 0
  cache-control: no-cache, no-store, max-age=0, must-revalidate
  content-type: application/json
  x-envoy-upstream-service-time: 16
  server: envoy
```

**Giải thích:**
- `storefront-bff` nằm trong mesh, có certificate: `cluster.local/ns/dev/sa/storefront-bff`
- Envoy của `product` đọc identity, kiểm tra principals của `allow-to-product` --> khớp --> cho phép
- Header `server: envoy` xác nhận traffic đã đi qua Envoy proxy (không phải kết nối trực tiếp)
- Header `x-envoy-upstream-service-time: 16` cho biết thời gian Envoy chờ response từ ứng dụng product là 16ms

**File cấu hình liên quan:** `authz.yaml` dòng 93-110 (allow-to-product)

---

### 6.4 TEST 4 -- Retry Policy

**Mục đích:** Chứng minh VirtualService retry policy hoạt động. Dùng kỹ thuật Fault Injection của Istio để inject lỗi 503 nhân tạo vào product, rồi quan sát Envoy có tự động retry không.

**Bước 1 -- Inject lỗi 503 nhân tạo (30% request bị trả 503):**

```powershell
@"
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: product-fault-injection
  namespace: dev
spec:
  hosts:
    - product
  http:
    - fault:
        abort:
          percentage:
            value: 30
          httpStatus: 503
      retries:
        attempts: 3
        perTryTimeout: 5s
        retryOn: 5xx,gateway-error,connect-failure
      timeout: 20s
      route:
        - destination:
            host: product
            port:
              number: 80
"@ | kubectl apply -f -

# Chờ 10 giây để Istio phân phối cấu hình xuống Envoy
Start-Sleep -Seconds 10
```

Lệnh này tạo một VirtualService khiến 30% request đến `product` bị trả về 503 ngay tại tầng Envoy. Ứng dụng product hoàn toàn bình thường, chỉ có Envoy inject lỗi.

**Bước 2 -- Gửi 10 request và quan sát:**

```powershell
for ($i = 1; $i -le 10; $i++) {
    $r = kubectl exec -n dev deployment/storefront-bff -- `
        wget -S -q -O /dev/null --timeout=20 `
        "http://product.dev.svc.cluster.local/product/storefront/products/featured" 2>&1
    if ($r -match "200") {
        Write-Host "Request $i -> 200 OK (Retry hấp thụ lỗi)" -ForegroundColor Green
    } else {
        Write-Host "Request $i -> FAIL" -ForegroundColor Red
    }
    Start-Sleep -Seconds 1
}
```

**Kết quả mong đợi:**

```
Request 1  -> 200 OK (Retry hấp thụ lỗi)
Request 2  -> 200 OK (Retry hấp thụ lỗi)
Request 3  -> 200 OK (Retry hấp thụ lỗi)
Request 4  -> 200 OK (Retry hấp thụ lỗi)
Request 5  -> 200 OK (Retry hấp thụ lỗi)
Request 6  -> 200 OK (Retry hấp thụ lỗi)
Request 7  -> 200 OK (Retry hấp thụ lỗi)
Request 8  -> 200 OK (Retry hấp thụ lỗi)
Request 9  -> 200 OK (Retry hấp thụ lỗi)
Request 10 -> 200 OK (Retry hấp thụ lỗi)
```

Ít nhất 8/10 request phải thành công (200 OK), mặc dù 30% bị inject lỗi 503.

**Giải thích xác suất:** Xác suất thất bại hoàn toàn (cả 3 lần retry đều trúng 503) = 0.3 x 0.3 x 0.3 = 2.7%. Nên gần như chắc chắn ít nhất 1 trong 3 lần sẽ thành công.

**Bước 3 -- Dọn dẹp fault injection:**

```powershell
kubectl delete virtualservice product-fault-injection -n dev
```

**File cấu hình liên quan:** `virtual-services.yaml` (retry config), `values.yaml` dòng 10-15 (retry parameters)

---

## 7. Chạy script test tự động

Script test tự động đã được chuẩn bị sẵn tại `yas-devops-1/k8s-infrastructure-scripts/test-service-mesh.ps1`. Script này chạy tuần tự cả 4 kịch bản test và in kết quả PASS/FAIL cho từng kịch bản.

**Cách chạy:**

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
cd "D:\LAP TRINH WEB\Project02\yas-devops-1\k8s-infrastructure-scripts"
.\test-service-mesh.ps1
```

**Kết quả mong đợi:**

```
TEST 1: mTLS          -> PASS (Connection reset by peer)
TEST 2: AuthzPolicy   -> PASS (HTTP 403 Forbidden)
TEST 3: AuthzPolicy   -> PASS (HTTP 200 OK)
TEST 4: Retry Policy  -> PASS (10/10 thành công)
```

---

## 8. Bảng tổng hợp kết quả test

| STT | Kịch bản | Caller | Target | Kết quả | Lý do |
|---|---|---|---|---|---|
| 1 | mTLS STRICT | Pod ngoài mesh (namespace default, không có Envoy) | product | Connection reset by peer | Không có certificate --> Envoy từ chối TLS handshake |
| 2 | AuthzPolicy DENY | tax (trong mesh, có Envoy) | customer | HTTP 403 Forbidden | tax không nằm trong principals của allow-to-customer |
| 3 | AuthzPolicy ALLOW | storefront-bff (trong mesh, có quyền) | product | HTTP 200 OK, server: envoy | storefront-bff nằm trong principals của allow-to-product |
| 4 | Retry Policy | storefront-bff | product (30% lỗi 503 injected) | 10/10 thành công | Envoy retry tối đa 3 lần, xác suất thất bại hoàn toàn chỉ 2.7% |

**So sánh 3 tầng bảo vệ:**

| Tầng | Cơ chế | Vị trí xử lý | Kết quả khi vi phạm |
|---|---|---|---|
| Transport | mTLS STRICT (PeerAuthentication) | Envoy receiver từ chối TLS handshake | Connection reset by peer |
| Network | Authorization Policy (deny-all + ALLOW rules) | Envoy receiver kiểm tra principals từ certificate | HTTP 403 Forbidden |
| Application | Authorization Policy ALLOW (principals khớp) | Envoy cho phép, chuyển request vào ứng dụng | HTTP 200 OK |

---

## 9. Các lệnh kiểm tra nhanh

```powershell
# Xem trạng thái tất cả pod (cần 2/2 Running)
kubectl get pods -n dev

# Xem tất cả PeerAuthentication (mTLS)
kubectl get peerauthentication -n dev

# Xem tất cả DestinationRule (mTLS outbound + infra exceptions)
kubectl get destinationrule -n dev

# Xem tất cả AuthorizationPolicy (16 chính sách)
kubectl get authorizationpolicy -n dev

# Xem tất cả VirtualService (retry + fault injection nếu có)
kubectl get virtualservice -n dev

# Mở Kiali Dashboard (giữ terminal này mở)
kubectl port-forward svc/kiali 20001:20001 -n istio-system
# Truy cập: http://localhost:20001

# Mở ArgoCD Dashboard
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Truy cập: https://localhost:8080
```

---

## 10. Xử lý sự cố thường gặp

### Pod hiện 1/2 thay vì 2/2

Nguyên nhân: Envoy sidecar chưa được inject hoặc ứng dụng chưa qua readiness probe.

Cách xử lý:
```powershell
# Kiểm tra namespace có label istio-injection không
kubectl get namespace dev --show-labels

# Nếu thiếu, thêm label
kubectl label namespace dev istio-injection=enabled --overwrite

# Restart deployment cụ thể
kubectl rollout restart deployment/<ten-service> -n dev
```

### Service gọi nhau bị 403 sau khi apply AuthorizationPolicy

Nguyên nhân: Service chưa được thêm vào danh sách `principals` của target service.

Cách xử lý: Mở file `authz.yaml`, tìm chính sách của target service và thêm identity của caller vào `principals`:

```yaml
principals:
  - "cluster.local/ns/dev/sa/<ten-service-caller>"
```

### Kết nối tới PostgreSQL/Redis bị lỗi sau khi bật mTLS

Nguyên nhân: Thiếu DestinationRule với `mode: DISABLE` cho các hạ tầng không có Envoy.

Cách xử lý: Kiểm tra file `destination-rules-infra.yaml` đã có entry cho namespace tương ứng chưa. Nếu thiếu, thêm DestinationRule mới với `mode: DISABLE` cho host tương ứng.

### Kiali graph trống, không hiển thị gì

Nguyên nhân: Chưa có traffic trong khoảng thời gian đang xem.

Cách xử lý: Sinh traffic bằng lệnh wget/curl từ pod trong mesh, sau đó nhấn nút refresh trên Kiali và chọn time range phù hợp (Last 1m hoặc Last 5m).

### AuthorizationPolicy không có hiệu lực sau khi apply

Nguyên nhân: Istio cần thời gian để phân phối cấu hình mới xuống Envoy sidecar.

Cách xử lý: Chờ 10-15 giây sau khi apply rồi mới test. Kiểm tra policy đã được apply đúng:

```powershell
kubectl get authorizationpolicy -n dev
kubectl describe authorizationpolicy <ten-policy> -n dev
```

---

## Lưu ý quan trọng

- **Toàn bộ cấu hình Service Mesh được quản lý bằng GitOps:** Helm chart trong repo `yas-gitops` được ArgoCD tự động sync vào cluster. Mọi thay đổi chỉ cần push lên Git, ArgoCD sẽ tự động đồng bộ.
- **ServiceAccount phải đặt tên giống tên service:** AuthorizationPolicy dựa vào ServiceAccount để nhận diện identity. Nếu tên không khớp, policy sẽ không hoạt động.
- **Không cần sửa code ứng dụng:** mTLS, Authorization Policy, và Retry Policy đều hoạt động ở tầng Envoy sidecar. Ứng dụng vẫn gọi HTTP bình thường.
- **Kiali cần traffic để hiển thị:** Graph trống nghĩa là chưa có request nào trong khoảng thời gian đang xem. Dùng vòng lặp wget để sinh traffic trước khi chụp screenshot.
