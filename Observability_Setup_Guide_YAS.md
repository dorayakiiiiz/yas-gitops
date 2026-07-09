# Hướng dẫn triển khai hệ thống Giám sát Observability cho YAS trên Kubernetes

## 1. Mục tiêu của tài liệu

Tài liệu này hướng dẫn cách thiết lập một hệ thống Observability hoàn chỉnh cho dự án YAS trên Kubernetes, bao gồm:

- Thu thập chỉ số hệ thống và ứng dụng bằng Prometheus
- Trực quan hóa dữ liệu bằng Grafana
- Theo dõi lưu lượng mạng và service mesh bằng Istio và Kiali
- Giám sát quy trình triển khai GitOps bằng ArgoCD

Mục tiêu cuối cùng là cung cấp khả năng quan sát trạng thái hoạt động của toàn bộ hệ thống vi dịch vụ YAS một cách trực quan và nhanh chóng khi phát sinh sự cố.

---

## 2. Chuẩn bị trước khi triển khai

Trước khi bắt đầu, hãy chắc chắn rằng các điều kiện sau đã sẵn sàng:

- Cluster Kubernetes đã được tạo và có thể truy cập
- Công cụ kubectl đã được cài đặt và cấu hình đúng context
- Công cụ Helm đã được cài đặt
- Namespace dev đã tồn tại và sẽ dùng để chạy ứng dụng YAS
- Có quyền áp dụng các tài nguyên Kubernetes vào cluster

Nếu chưa có cluster, hãy đảm bảo cluster đang chạy trước khi tiếp tục.

---

## 3. Bước 1: Cài đặt và cấu hình Istio Service Mesh

### 3.1 Mục đích

Istio là lớp nền tảng Service Mesh giúp:

- Thu thập telemetry từ lưu lượng mạng giữa các service
- Tự động áp dụng bảo mật mTLS cho các kết nối nội bộ
- Hỗ trợ tracing và theo dõi request đi qua nhiều service
- Cung cấp một cách thống nhất để quan sát hành vi hệ thống

### 3.2 Các lệnh thực hiện

```bash
curl -L https://istio.io/downloadIstio | sh -
cd istio-*
export PATH=$PWD/bin:$PATH
istioctl install --set profile=demo -y
kubectl label namespace dev istio-injection=enabled --overwrite
```

### 3.3 Giải thích chi tiết từng lệnh

1. `curl -L https://istio.io/downloadIstio | sh -`
   - Tải script cài đặt Istio từ trang chủ chính thức.
   - `-L` nghĩa là nếu URL bị redirect thì vẫn tải đúng file.
   - `| sh -` nghĩa là thực thi script vừa tải xuống.

2. `cd istio-*`
   - Di chuyển vào thư mục cài đặt Istio vừa được giải nén.
   - `*` dùng để khớp với thư mục phiên bản Istio mới nhất.

3. `export PATH=$PWD/bin:$PATH`
   - Thêm thư mục chứa công cụ `istioctl` vào biến môi trường PATH.
   - Điều này cho phép thực thi `istioctl` từ bất kỳ vị trí nào trong terminal mà không cần chỉ định đường dẫn đầy đủ.

4. `istioctl install --set profile=demo -y`
   - Cài đặt Istio vào cluster bằng profile `demo`.
   - Profile `demo` phù hợp cho môi trường thử nghiệm và học tập vì nó bật đầy đủ các tính năng quan trọng của Istio.
   - `-y` nghĩa là tự động xác nhận và tiếp tục cài đặt mà không cần hỏi lại.

5. `kubectl label namespace dev istio-injection=enabled --overwrite`
   - Gắn nhãn cho namespace `dev` để kích hoạt cơ chế sidecar injection.
   - Khi một Pod mới được tạo trong namespace này, Istio sẽ tự động thêm sidecar `istio-proxy` vào Pod đó.

### 3.4 Kết quả mong đợi

Sau bước này, cluster sẽ có Istio hoạt động và các service trong namespace `dev` sẽ được triển khai với proxy Istio đi kèm.

---

## 4. Bước 2: Cấu hình bảo mật kết nối nội bộ bằng mTLS

### 4.1 Mục đích

mTLS (Mutual TLS) là cơ chế mã hóa hai chiều giữa các service. Mục đích là:

- Ngăn chặn việc giao tiếp nội bộ diễn ra dưới dạng plain text
- Tăng cường bảo mật cho dữ liệu truyền giữa các service
- Đảm bảo các kết nối trong hệ thống đều được xác thực và mã hóa

### 4.2 YAML áp dụng cấu hình

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: dev
spec:
  mtls:
    mode: STRICT
```

### 4.3 Giải thích cấu hình

- `kind: PeerAuthentication` cho biết đây là tài nguyên Istio dùng để điều chỉnh chính sách xác thực TLS.
- `namespace: dev` nghĩa là chính sách này chỉ áp dụng cho namespace `dev`.
- `mode: STRICT` quy định rằng mọi kết nối nội bộ giữa các service trong namespace này phải dùng mTLS.

### 4.4 Cách áp dụng

```bash
cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: dev
spec:
  mtls:
    mode: STRICT
EOF
```

### 4.5 Ý nghĩa thực tế

Nếu một service cố tình giao tiếp bằng cách không dùng TLS, Istio sẽ chặn kết nối đó. Điều này giúp hệ thống luôn ở trong trạng thái bảo mật cao.

---

## 5. Bước 3: Khởi tạo hạ tầng giám sát Prometheus và Grafana

### 5.1 Mục đích

Prometheus dùng để thu thập metric, còn Grafana dùng để hiển thị dữ liệu dưới dạng dashboard. Đây là bộ phận trung tâm của hệ thống Observability.

### 5.2 Các lệnh thực hiện

```bash
kubectl create namespace monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set grafana.enabled=true \
  --set grafana.service.type=NodePort \
  --set grafana.adminPassword=admin
```

### 5.3 Giải thích từng bước

1. `kubectl create namespace monitoring`
   - Tạo namespace riêng để chứa các thành phần giám sát.

2. `helm repo add prometheus-community ...`
   - Thêm Helm repository chứa chart `kube-prometheus-stack`.

3. `helm repo update`
   - Cập nhật danh sách chart mới nhất từ repository.

4. `helm install prometheus ...`
   - Cài đặt stack giám sát Prometheus + Grafana vào namespace `monitoring`.

### 5.4 Ý nghĩa của các tùy chọn Helm

- `serviceMonitorSelectorNilUsesHelmValues=false`
  - Cho phép Prometheus tự phát hiện và thu thập các ServiceMonitor do người dùng tự định nghĩa, thay vì chỉ giới hạn ở những tài nguyên được Helm quản lý.

- `podMonitorSelectorNilUsesHelmValues=false`
  - Tương tự, cho phép Prometheus nhận diện PodMonitor.

- `grafana.service.type=NodePort`
  - Mở Grafana ra bên ngoài cluster để truy cập bằng Node IP và cổng được mở.

- `grafana.adminPassword=admin`
  - Đặt mật khẩu mặc định cho tài khoản admin của Grafana.

### 5.5 Kiểm tra tiến trình cài đặt

```bash
kubectl get pods -n monitoring -w
```

Lệnh này cho phép theo dõi trạng thái của các pod trong namespace `monitoring` cho đến khi chúng chuyển sang trạng thái `Running`.

---

## 6. Bước 4: Cài đặt Kiali Dashboard

### 6.1 Mục đích

Kiali là giao diện web cho Istio, hỗ trợ quan sát:

- Topology của mạng service
- Tỷ lệ request giữa các service
- Sức khỏe và trạng thái của các kết nối
- Dữ liệu telemetry từ Istio

### 6.2 Lệnh thực hiện

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/addons/kiali.yaml
```

### 6.3 Giải thích

Lệnh trên sẽ áp dụng các manifest chuẩn của Istio để triển khai Kiali vào cluster. Kiali sẽ tự kết nối với Prometheus để vẽ biểu đồ về lưu lượng mạng trong hệ thống.

---

## 7. Bước 5: Tạo Service để thu thập metric từ Istio proxy

### 7.1 Mục đích

Mỗi sidecar Istio (container `istio-proxy`) sẽ expose metric tại cổng `15090`. Để Prometheus có thể scrape được dữ liệu này, cần tạo một Kubernetes Service trỏ đến cổng đó.

### 7.2 YAML triển khai

```yaml
apiVersion: v1
kind: Service
metadata:
  name: istio-proxy-metrics
  namespace: dev
  labels:
    app: istio-proxy
spec:
  selector:
    app.kubernetes.io/name: product
  ports:
    - name: http-envoy-prom
      port: 15090
      targetPort: 15090
```

### 7.3 Giải thích

- Service này tạo một endpoint nội bộ để Prometheus truy cập vào metric của sidecar Envoy.
- `targetPort: 15090` tương ứng với cổng mà Istio proxy đang expose metric.

### 7.4 Cách áp dụng

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: istio-proxy-metrics
  namespace: dev
  labels:
    app: istio-proxy
spec:
  selector:
    app.kubernetes.io/name: product
  ports:
    - name: http-envoy-prom
      port: 15090
      targetPort: 15090
EOF
```

---

## 8. Bước 6: Tạo ServiceMonitor để Prometheus scrape dữ liệu Istio và ArgoCD

### 8.1 Mục đích

Prometheus không tự động biết đâu là target cần scrape. Vì vậy phải định nghĩa ServiceMonitor để nó biết:

- Cần scrape metric từ Istio proxy ở cổng `15090`
- Cần scrape metric từ ArgoCD ở namespace `argocd`

### 8.2 ServiceMonitor cho Istio Envoy

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: istio-envoy
  namespace: monitoring
  labels:
    release: prometheus
spec:
  endpoints:
    - interval: 15s
      path: /stats/prometheus
      port: http-envoy-prom
  namespaceSelector:
    matchNames:
      - dev
  selector:
    matchLabels:
      app: istio-proxy
```

### 8.3 ServiceMonitor cho ArgoCD

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-monitor
  namespace: monitoring
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-metrics
  endpoints:
    - port: metrics
      interval: 15s
  namespaceSelector:
    matchNames:
      - argocd
```

### 8.4 Giải thích

- `release: prometheus` là nhãn giúp Prometheus Operator nhận diện và quản lý monitor này.
- `interval: 15s` nghĩa Prometheus sẽ scrape mỗi 15 giây.
- `path: /stats/prometheus` là đường dẫn metric của Envoy proxy.
- `port: http-envoy-prom` là cổng service được định nghĩa ở bước trước.

### 8.5 Cách áp dụng

```bash
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: istio-envoy
  namespace: monitoring
  labels:
    release: prometheus
spec:
  endpoints:
    - interval: 15s
      path: /stats/prometheus
      port: http-envoy-prom
  namespaceSelector:
    matchNames:
      - dev
  selector:
    matchLabels:
      app: istio-proxy
EOF

cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-monitor
  namespace: monitoring
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-metrics
  endpoints:
    - port: metrics
      interval: 15s
  namespaceSelector:
    matchNames:
      - argocd
EOF
```

---

## 9. Bước 7: Mở cổng truy cập cho các giao diện giám sát

### 9.1 Mục đích

Các service giám sát thường nằm trong mạng nội bộ của cluster, nên cần dùng port-forward để mở các cổng ra máy local hoặc gateway bên ngoài.

### 9.2 Các lệnh port-forward

```bash
nohup kubectl port-forward --address 0.0.0.0 svc/prometheus-operator-grafana -n monitoring 3000:80 > /dev/null 2>&1 &
nohup kubectl port-forward --address 0.0.0.0 svc/prometheus-operator-kube-p-prometheus -n monitoring 9090:9090 > /dev/null 2>&1 &
nohup kubectl port-forward --address 0.0.0.0 svc/kiali -n istio-system 20001:20001 > /dev/null 2>&1 &
nohup kubectl port-forward --address 0.0.0.0 svc/argocd-server -n argocd 8080:443 > /dev/null 2>&1 &
```

### 9.3 Giải thích

- `nohup ... &` giúp lệnh chạy ngầm và không bị ngắt khi terminal đóng.
- `--address 0.0.0.0` cho phép nghe từ mọi địa chỉ mạng nội bộ.
- Các cổng mở ra gồm:
  - `3000` → Grafana
  - `9090` → Prometheus
  - `20001` → Kiali
  - `8080` → ArgoCD

---

## 10. Bước 8: Lấy mật khẩu admin của ArgoCD

### 10.1 Mục đích

ArgoCD tạo một secret chứa mật khẩu ban đầu của tài khoản admin. Mật khẩu này cần được truy xuất để đăng nhập vào giao diện web.

### 10.2 Lệnh thực hiện

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### 10.3 Giải thích

- Secret được lưu trong namespace `argocd`.
- `jsonpath` dùng để lấy giá trị trường `password`.
- `base64 -d` dùng để giải mã chuỗi đã được mã hóa trước đó.

Sau khi thực hiện lệnh này, mật khẩu gốc để đăng nhập vào ArgoCD sẽ được truy xuất.

---

## 11. Bước 9: Tạo lưu lượng giả lập để kiểm thử hệ thống

### 11.1 Mục đích

Sau khi cài đặt xong, cần tạo traffic thật để các dashboard và biểu đồ có dữ liệu hiển thị. Nếu không có traffic, Grafana và Kiali có thể trông như chưa hoạt động.

### 11.2 Lệnh thực hiện

```bash
nohup bash -c 'while true; do curl -s http://192.168.49.2:31568/product/storefront/products/featured > /dev/null; sleep 1; done' > /dev/null 2>&1 &
```

### 11.3 Giải thích

- Vòng lặp `while true` sẽ liên tục gửi request đến endpoint sản phẩm nổi bật của hệ thống YAS.
- `sleep 1` tạo khoảng cách 1 giây giữa các request.
- Điều này giúp Prometheus có dữ liệu để scrape và Grafana/Kiali có thể vẽ biểu đồ chính xác.

---
