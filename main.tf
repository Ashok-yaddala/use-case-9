provider "aws" {
 region = var.region
}
# VPC
resource "aws_vpc" "main" {
 cidr_block           = var.vpc_cidr
 enable_dns_support   = true
 enable_dns_hostnames = true
 tags = {
   Name = "${var.environment}-vpc"
 }
}
# Public Subnets
resource "aws_subnet" "public" {
 count                   = length(var.public_subnet_cidrs)
 vpc_id                  = aws_vpc.main.id
 cidr_block              = var.public_subnet_cidrs[count.index]
 availability_zone       = var.azs[count.index]
 map_public_ip_on_launch = true
 tags = {
   Name = "${var.environment}-public-subnet-${count.index}"
     "kubernetes.io/role/elb" = "1"
    "kubernetes.io/cluster/${var.environment}-eks" = "shared"
 }
}
# Internet Gateway
resource "aws_internet_gateway" "igw" {
 vpc_id = aws_vpc.main.id
 tags = {
   Name = "${var.environment}-igw"
 }
}
# Public Route Table
resource "aws_route_table" "public" {
 vpc_id = aws_vpc.main.id
 route {
   cidr_block = "0.0.0.0/0"
   gateway_id = aws_internet_gateway.igw.id
 }
 tags = {
   Name = "${var.environment}-public-rt"
 }
}
resource "aws_route_table_association" "public" {
 count          = length(aws_subnet.public[*].id)
 subnet_id      = aws_subnet.public[count.index].id
 route_table_id = aws_route_table.public.id
}
# Security Group for ALB
resource "aws_security_group" "alb_sg" {
 name        = "${var.environment}-alb-sg"
 description = "Allow HTTP and HTTPS"
 vpc_id      = aws_vpc.main.id
 ingress {
   from_port   = 80
   to_port     = 80
   protocol    = "tcp"
   cidr_blocks = ["0.0.0.0/0"]
 }
 ingress {
   from_port   = 443
   to_port     = 443
   protocol    = "tcp"
   cidr_blocks = ["0.0.0.0/0"]
 }
 egress {
   from_port   = 0
   to_port     = 0
   protocol    = "-1"
   cidr_blocks = ["0.0.0.0/0"]
 }
 tags = {
   Name = "${var.environment}-alb-sg"
 }
}
# IAM Role for EKS Cluster
resource "aws_iam_role" "eks_role" {
 name = "eksClusterRole"
 assume_role_policy = jsonencode({
   Version = "2012-10-17",
   Statement = [{
     Effect = "Allow",
     Principal = {
       Service = "eks.amazonaws.com"
     },
     Action = "sts:AssumeRole"
   }]
 })
}
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
 role       = aws_iam_role.eks_role.name
 policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}
# IAM Role for EKS Node Group
resource "aws_iam_role" "eks_node_role" {
 name = "eksNodeGroupRole"
 assume_role_policy = jsonencode({
   Version = "2012-10-17",
   Statement = [{
     Effect = "Allow",
     Principal = {
       Service = "ec2.amazonaws.com"
     },
     Action = "sts:AssumeRole"
   }]
 })
}
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
 role       = aws_iam_role.eks_node_role.name
 policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}
resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
 role       = aws_iam_role.eks_node_role.name
 policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
resource "aws_iam_role_policy_attachment" "ecr_read_only" {
 role       = aws_iam_role.eks_node_role.name
 policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
# EKS Cluster
resource "aws_eks_cluster" "eks" {
 name     = "${var.environment}-eks"
 role_arn = aws_iam_role.eks_role.arn
 vpc_config {
   subnet_ids = aws_subnet.public[*].id
 }
 depends_on = [aws_iam_role.eks_role]
}
# EKS Node Group
resource "aws_eks_node_group" "node_group" {
 cluster_name    = aws_eks_cluster.eks.name
 node_group_name = "${var.environment}-node-group"
 node_role_arn   = aws_iam_role.eks_node_role.arn
 subnet_ids      = aws_subnet.public[*].id
 scaling_config {
   desired_size = 2
   max_size     = 3
   min_size     = 1
 }
 instance_types = ["t3.medium"]
 depends_on = [aws_eks_cluster.eks]
}

# ---------------------------
# ALB Controller IRSA Module
# ---------------------------

# Variables you need to define in root module:
# - var.environment
# - var.region

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config" # or use dynamic setup via data.aws_eks_cluster + aws eks update-kubeconfig
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

# Get EKS cluster data
data "aws_eks_cluster" "eks" {
  name = var.eks_cluster_name
}

data "aws_iam_openid_connect_provider" "oidc" {
  url = replace(data.aws_eks_cluster.eks.identity[0].oidc[0].issuer, "https://", "")
}

# IAM Role for ALB Controller
resource "aws_iam_role" "alb_controller_irsa" {
  name = "${var.environment}-alb-controller-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.oidc.arn
      },
      Action = "sts:AssumeRoleWithWebIdentity",
      Condition = {
        StringEquals = {
          "${replace(data.aws_eks_cluster.eks.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller_policy" {
  role       = aws_iam_role.alb_controller_irsa.name
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
}

# Kubernetes service account
resource "kubernetes_service_account" "alb_controller_sa" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller_irsa.arn
    }
  }
  depends_on = [aws_iam_role.alb_controller_irsa]
}

# Helm chart deployment
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.1"

  set {
    name  = "clusterName"
    value = data.aws_eks_cluster.eks.name
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.alb_controller_sa.metadata[0].name
  }

  set {
    name  = "image.repository"
    value = "602401143452.dkr.ecr.${var.region}.amazonaws.com/amazon/aws-load-balancer-controller"
  }

  depends_on = [kubernetes_service_account.alb_controller_sa]
}
