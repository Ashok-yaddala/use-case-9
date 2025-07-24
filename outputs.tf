output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "eks_cluster_name" {
  description = "EKS Cluster name"
  value       = aws_eks_cluster.eks.name
}

output "eks_cluster_endpoint" {
  description = "EKS Cluster endpoint"
  value       = aws_eks_cluster.eks.endpoint
}

output "eks_cluster_security_group" {
  description = "Security group associated with the EKS cluster"
  value       = aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id
}

output "alb_security_group_id" {
  description = "Security Group ID for the ALB"
  value       = aws_security_group.alb_sg.id
}