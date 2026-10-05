# DevOps Portfolio - Master Deployment Guide & Secrets Cheat Sheet
> Toàn bộ hướng dẫn triển khai, thông tin đăng nhập, API keys, URLs và quy trình vận hành từ **Project 01 đến Project 04**.

---

## 📑 Mục Lục
1. [Project 01: Modernize with ECS (Fargate + Blue/Green CI/CD)](#1-project-01-modernize-with-ecs)
2. [Project 02: Centralized VPC Endpoints (Hub-and-Spoke via Transit Gateway)](#2-project-02-centralized-vpc-endpoints)
3. [Project 03: Centralized Egress (Transit Gateway + Central NAT Gateway)](#3-project-03-centralized-egress)
4. [Project 04: Modernize with EKS (End-to-End GitOps, CI/CD, Monitoring)](#4-project-04-modernize-with-eks)
   - [0-baseline: Hạ tầng nền tảng & Database](#41-0-baseline-hạ-tầng-nền-tảng--database)
   - [1-deploy-apps: Triển khai ứng dụng & Ingress](#42-1-deploy-apps-triển-khai-ứng-dụng--ingress)
   - [2-hpa: Tự động co giãn (Horizontal Pod Autoscaler)](#43-2-hpa-tự-động-co-giãn-horizontal-pod-autoscaler)
   - [3-cicd: CodeCommit + CodePipeline + CodeBuild](#44-3-cicd-codecommit--codepipeline--codebuild)
   - [4-gitops-argocd: ArgoCD + Argo Rollouts + Image Updater](#45-4-gitops-argocd-argocd--argo-rollouts--image-updater)
   - [5-monitoring: Prometheus + Grafana + Alertmanager](#46-5-monitoring-prometheus--grafana--alertmanager)
5. [Bảng Tra Cứu Thông Tin Bí Mật & Thông Tin Đăng Nhập (Secrets Cheat Sheet)](#5-bảng-tra-cứu-thông-tin-bí-mật--thông-tin-đăng-nhập-secrets-cheat-sheet)

---

## 1. Project 01: Modernize with ECS
- **Mục tiêu:** Xây dựng hệ thống container serverless trên AWS ECS Fargate, kết hợp Application Load Balancer (ALB), Cloud Map Service Discovery và pipeline CI/CD Blue/Green tự động.
- **Khu vực (Region):** `us-east-1` (N. Virginia)
- **Thư mục mã nguồn:** `01-modernize-with-ecs/`

### 1.1. Các thông số & Tài nguyên đã triển khai
- **ECS Cluster:** `devops-blueprint`
- **Application URL:** [http://devops-blueprint-alb-30108751.us-east-1.elb.amazonaws.com](http://devops-blueprint-alb-30108751.us-east-1.elb.amazonaws.com)
- **ALB ARN:** `arn:aws:elasticloadbalancing:us-east-1:106403001296:loadbalancer/app/devops-blueprint-alb/2776c2b5bb3996ad`
- **ALB Security Group:** `sg-01ed47180239b0cfe`
- **ECS Service Security Group:** `sg-043a54775f91bd980`
- **S3 Artifact Bucket:** `s3-artifact-x3zosod`
- **Cloud Map Namespace ID:** `ns-fkx277qdqdc73fiq` (`devops-blueprint.local`)
- **SNS Topic Thông báo Approval:** `arn:aws:sns:us-east-1:106403001296:devops-blueprint-topic`

### 1.2. Hướng dẫn triển khai & kiểm tra
```bash
cd 01-modernize-with-ecs
terraform init -backend-config=backend.config
terraform apply -auto-approve
```
**Kiểm tra dịch vụ & phân giải DNS nội bộ (Cloud Map):**
```bash
# 1. Kiểm tra Web App qua ALB:
curl -i http://devops-blueprint-alb-30108751.us-east-1.elb.amazonaws.com
# Kỳ vọng: HTTP 200 OK

# 2. Kiểm tra phân giải Service Discovery nội bộ qua Cloud Map (chạy từ bên trong container hoặc VPC):
nslookup backend.devops-blueprint.local
# Kỳ vọng: Trả về Private IP của các ECS backend task đang chạy
```

---

## 2. Project 02: Centralized VPC Endpoints
- **Mục tiêu:** Tập trung toàn bộ Interface VPC Endpoints (SSM, EC2Messages, SSMMessages, S3) vào một Hub VPC duy nhất. Các Spoke VPC kết nối qua Transit Gateway và phân giải DNS qua Route 53 Private Hosted Zone (PHZ), giúp tiết kiệm chi phí VPC Endpoint.
- **Khu vực (Region):** `us-east-1`
- **Thư mục mã nguồn:** `02-centralized-vpce/`

### 2.1. Các thông số hạ tầng
- **Transit Gateway (TGW):** `tgw-091a1343bb9279027`
- **Hub VPC:** Chứa toàn bộ VPC Interface Endpoints cho SSM, KMS, S3.
- **Spoke 1 EC2 Instance:** `spoke1-ec2` (`i-016b84424f65276e6`) - Private Subnet, không Public IP.
- **Spoke 2 EC2 Instance:** `spoke2-ec2` (`i-04883a4aae975e0ac`) - Private Subnet, không Public IP.
- **IAM Role cho EC2:** `ec2-role` (Gắn `AmazonSSMManagedInstanceCore`, `AmazonS3FullAccess`).

### 2.2. Hướng dẫn kiểm tra kết nối & Phân giải DNS (nslookup)
**Bước 1: Kết nối vào Spoke EC2 không cần Internet qua SSM Session Manager:**
```bash
aws ssm start-session --target i-016b84424f65276e6 --region us-east-1   # Spoke 1
aws ssm start-session --target i-04883a4aae975e0ac --region us-east-1   # Spoke 2
```

**Bước 2: Chạy lệnh `nslookup` bên trong Spoke EC2 để kiểm tra nhận 2 IP của VPC Endpoint tập trung:**
```bash
nslookup ssm.us-east-1.amazonaws.com
nslookup s3.us-east-1.amazonaws.com
```
> **Giải thích kết quả:**
> Lệnh `nslookup` sẽ trả về **2 Private IP** (tương ứng với 2 Availability Zones đặt VPC Interface Endpoint trong Hub VPC).
> Điều này xác nhận rằng Route 53 Private Hosted Zone đang hoạt động chính xác, cho phép máy chủ Spoke phân giải và gửi lưu lượng tới Hub VPC qua Transit Gateway một cách riêng tư hoàn toàn mà không cần Internet.

**Bước 3: Lệnh kiểm tra nhanh Private IP của cả 2 Spoke từ máy tính cá nhân:**
```bash
aws ec2 describe-instances --filters "Name=tag:Name,Values=spoke*" --query "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0], PrivateIpAddress]" --output table
```

---

## 3. Project 03: Centralized Egress
- **Mục tiêu:** Chia sẻ một NAT Gateway và Internet Gateway tập trung duy nhất đặt tại Egress VPC cho nhiều Spoke VPC thông qua Transit Gateway route tables.
- **Khu vực (Region):** `us-east-2` (Ohio)
- **Thư mục mã nguồn:** `03-centralized-egress/`

### 3.1. Các thông số hạ tầng
- **Khu vực triển khai:** `us-east-2`
- **Lambda Function 1 (Spoke 1):** `app1` (Gắn ENI vào `spoke1-vpc`)
- **Lambda Function 2 (Spoke 2):** `app2` (Gắn ENI vào `spoke2-vpc`)
- **Cơ chế Egress:** Spoke VPCs gửi default route `0.0.0.0/0` qua Transit Gateway → Egress VPC → NAT Gateway → Internet.

### 3.2. Hướng dẫn kiểm tra kết nối Egress ra Internet
Gọi thử nghiệm 2 hàm Lambda để kiểm tra khả năng request ra ngoài Internet (GitHub API):
```bash
aws lambda invoke --function-name app1 --region us-east-2 response-app1.json
type response-app1.json
# Phản hồi kỳ vọng: {"statusCode": 200, "body": "Success connect to: https://api.github.com"}

aws lambda invoke --function-name app2 --region us-east-2 response-app2.json
type response-app2.json
# Phản hồi kỳ vọng: {"statusCode": 200, "body": "Success connect to: https://api.github.com"}
```

---

## 4. Project 04: Modernize with EKS

Toàn bộ Project 4 được chia thành 6 giai đoạn (stacks) triển khai liên tiếp trên cùng một cụm EKS:

### 4.1. `0-baseline`: Hạ tầng nền tảng & Database
- **Thư mục:** `04-modernize-with-eks/0-baseline/`
- **EKS Cluster:** `devops-blueprint-eks` (Kubernetes v1.33)
- **Worker Node Group:** `devops-blueprint-eks-small` (4 nodes `t3.small` AL2023)
- **Cơ sở dữ liệu (RDS PostgreSQL 17):**
  - **Endpoint / Host:** `devops-blueprint-eks-postgres.ci10yg06m8tj.us-east-1.rds.amazonaws.com`
  - **Port:** `5432`
  - **Database Name:** `appdb`
  - **Master Username:** `dbadmin`
  - **Master Password:** `Y_dd9943n>)o6oN3`
- **AWS Secrets Manager:**
  - **Secret Name:** `test-eks-secrets`
  - **Secret ARN:** `arn:aws:secretsmanager:us-east-1:106403001296:secret:test-eks-secrets-MRHPMv`
- **Add-ons & Controllers:**
  - AWS VPC CNI (Amazon EKS CNI)
  - CoreDNS, kube-proxy, EKS Pod Identity Agent
  - AWS Load Balancer Controller
  - AWS Secrets Store CSI Driver + AWS Provider
  - AWS EBS CSI Driver (StorageClass `gp3`)

### 4.2. `1-deploy-apps`: Triển khai ứng dụng & Ingress
- **Thư mục:** `04-modernize-with-eks/1-deploy-apps/`
- **Ứng dụng:** Python Flask Backend + Nginx Frontend
- **Amazon ECR Repositories:**
  - Backend: `106403001296.dkr.ecr.us-east-1.amazonaws.com/backend`
  - Frontend: `106403001296.dkr.ecr.us-east-1.amazonaws.com/frontend`
- **Public ALB Ingress URL:**
  - Web UI: [http://k8s-frontend-frontend-5438bb57ec-889534872.us-east-1.elb.amazonaws.com](http://k8s-frontend-frontend-5438bb57ec-889534872.us-east-1.elb.amazonaws.com)
  - REST API: [http://k8s-frontend-frontend-5438bb57ec-889534872.us-east-1.elb.amazonaws.com/api/items](http://k8s-frontend-frontend-5438bb57ec-889534872.us-east-1.elb.amazonaws.com/api/items)

### 4.3. `2-hpa`: Tự động co giãn (Horizontal Pod Autoscaler)
- **Thư mục:** `04-modernize-with-eks/2-hpa/`
- **Cấu hình:** HPA giám sát CPU/Memory qua Metrics Server, tự động tăng số lượng Pod khi tải cao (minReplicas: 1, maxReplicas: 10, CPU target: 60%).

### 4.4. `3-cicd`: CodeCommit + CodePipeline + CodeBuild
- **Thư mục:** `04-modernize-with-eks/3-cicd/`
- **AWS CodeCommit Git Repositories:**
  - Backend: `https://git-codecommit.us-east-1.amazonaws.com/v1/repos/devops-blueprint-eks-backend`
  - Frontend: `https://git-codecommit.us-east-1.amazonaws.com/v1/repos/devops-blueprint-eks-frontend`
- **Tài khoản Git HTTPS (CodeCommit):**
  - **Git Username:** `dungnt-at-106403001296`
  - **Git Password:** `1eZumD20jpiaO7D7lGSdwBaURqvAyZioSIMpsNpp7gY8lzKpv5liVySxmhE=`
- **Cơ chế:** Khi commit code vào nhánh `main`, EventBridge tự động kích hoạt AWS CodePipeline → CodeBuild build Docker image và gắn tag commit SHA tự động đẩy lên ECR.

### 4.5. `4-gitops-argocd`: ArgoCD + Argo Rollouts + Image Updater
- **Thư mục:** `04-modernize-with-eks/4-gitops-argocd/`
- **SSH Key CodeCommit:**
  - **SSH Key ID:** `APKARRRQ46PIDQBSW4YZ`
  - **IAM User:** `argocd-codecommit`
  - **Private Key Path:** `~/.ssh/argocd-codecommit`
- **ArgoCD Dashboard:**
  - **Port-forward lệnh:**
    ```powershell
    kubectl port-forward svc/argocd-server -n argocd 8080:80
    ```
  - **URL:** [http://localhost:8080](http://localhost:8080)
  - **Username:** `admin`
  - **Password:** `3Y8jbIvR5k3Tjcgf`
- **Argo Rollouts Dashboard (Blue/Green Deployment Visualizer):**
  - **Port-forward lệnh:**
    ```powershell
    kubectl port-forward svc/argo-rollouts-dashboard -n argocd 3100:3100
    ```
  - **URL:** [http://localhost:3100](http://localhost:3100)
- **ArgoCD Image Updater:**
  - Tự động thăm dò ECR mỗi 2 phút, phát hiện tag build mới và tự động cập nhật spec Rollout.
  - Tích hợp CronJob `ecr-token-refresher` làm mới token đăng nhập ECR định kỳ mỗi 6 giờ.

### 4.6. `5-monitoring`: Prometheus + Grafana + Alertmanager
- **Thư mục:** `04-modernize-with-eks/5-monitoring/`
- **StorageClass:** `gp3` (EBS CSI Driver với chế độ `WaitForFirstConsumer`)
- **Grafana Dashboard:**
  - **Port-forward lệnh:**
    ```powershell
    kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
    ```
  - **URL:** [http://localhost:3000](http://localhost:3000)
  - **Username:** `admin`
  - **Password:** `admin12345`
  - **Dung lượng lưu trữ:** 5Gi EBS gp3 volume
- **Prometheus UI:**
  - **Port-forward lệnh:**
    ```powershell
    kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
    ```
  - **URL:** [http://localhost:9090](http://localhost:9090)
  - **Dung lượng lưu trữ:** 10Gi EBS gp3 volume (retention: 7d)
- **Alertmanager UI:**
  - **Port-forward lệnh:**
    ```powershell
    kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-alertmanager 9093:9093
    ```
  - **URL:** [http://localhost:9093](http://localhost:9093)
  - **Dung lượng lưu trữ:** 5Gi EBS gp3 volume

---

## 5. Bảng Tra Cứu Thông Tin Bí Mật & Thông Tin Đăng Nhập (Secrets Cheat Sheet)

| Dịch vụ / Hệ thống | Thông số / Khóa | Giá trị |
| :--- | :--- | :--- |
| **AWS Account ID** | ID | `106403001296` |
| **Terraform State S3 Bucket** | Bucket Name | `s3-backend-tfstate-2s65p20` |
| **Project 01 (ECS ALB)** | Public URL | `http://devops-blueprint-alb-30108751.us-east-1.elb.amazonaws.com` |
| **Project 02 (SSM Spoke 1)** | Instance ID | `i-016b84424f65276e6` |
| **Project 02 (SSM Spoke 2)** | Instance ID | `i-04883a4aae975e0ac` |
| **Project 03 (Lambda Egress)** | Region / Function | `us-east-2` / `app1`, `app2` |
| **Project 04 (EKS ALB)** | Web App URL | `http://k8s-frontend-frontend-5438bb57ec-889534872.us-east-1.elb.amazonaws.com` |
| **Project 04 (EKS API)** | API URL | `http://k8s-frontend-frontend-5438bb57ec-889534872.us-east-1.elb.amazonaws.com/api/items` |
| **PostgreSQL 17 (RDS)** | Host | `devops-blueprint-eks-postgres.ci10yg06m8tj.us-east-1.rds.amazonaws.com` |
| **PostgreSQL 17 (RDS)** | User / Pass / DB | `dbadmin` / `Y_dd9943n>)o6oN3` / `appdb` |
| **CodeCommit Git HTTPS** | Username | `dungnt-at-106403001296` |
| **CodeCommit Git HTTPS** | Password | `1eZumD20jpiaO7D7lGSdwBaURqvAyZioSIMpsNpp7gY8lzKpv5liVySxmhE=` |
| **CodeCommit SSH** | SSH Key ID | `APKARRRQ46PIDQBSW4YZ` |
| **CodeCommit SSH** | Private Key | `~/.ssh/argocd-codecommit` |
| **ArgoCD Dashboard** | User / Password | `admin` / `3Y8jbIvR5k3Tjcgf` |
| **Grafana Dashboard** | User / Password | `admin` / `admin12345` |

---

## 6. Lệnh Vận Hành & Khắc Phục Nhanh (Cheat Sheet Lệnh)

### Truy cập nhanh tất cả Dashboard:
```powershell
# 1. ArgoCD UI (http://localhost:8080)
kubectl port-forward svc/argocd-server -n argocd 8080:80

# 2. Argo Rollouts UI (http://localhost:3100)
kubectl port-forward svc/argo-rollouts-dashboard -n argocd 3100:3100

# 3. Grafana (http://localhost:3000)
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# 4. Prometheus (http://localhost:9090)
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
```

### Kiểm tra sức khỏe toàn diện EKS:
```powershell
# Kiểm tra nodes
kubectl get nodes -o wide

# Kiểm tra pods theo từng namespace
kubectl get pods -n backend
kubectl get pods -n frontend
kubectl get pods -n argocd
kubectl get pods -n monitoring

# Kiểm tra Blue/Green Rollouts
kubectl get rollouts -A

# Kiểm tra ArgoCD Applications
kubectl get applications -n argocd
```
